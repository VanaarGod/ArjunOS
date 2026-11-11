import Foundation
import AppKit
import WebKit
import Vision
import PDFKit
import JarvisCore

struct PageReadResult {
    var payload: PagePayload
    var thin: Bool            // little or no DOM text: the page is mostly images/canvas/video
    var usedOCR: Bool
}

/// Reads the live page in a tab. DOM text and structured data first (exact, cheap); a screenshot read with Vision OCR only when
/// the DOM says too little (images, canvas, video, text drawn as pictures) or the user asked for it. Never throws: whatever goes
/// wrong becomes an honest `status` the assistant can explain, so it never has to guess.
@MainActor
enum PageReader {
    private struct Stats: Decodable {
        var textLength: Int?; var canvases: Int?; var images: Int?; var videos: Int?; var isPdf: Bool?; var truncated: Bool?; var signIn: Bool?
    }
    private struct Envelope: Decodable { var payload: PagePayload; var stats: Stats? }

    static func read(_ tab: BrowserTab, forceOCR: Bool, allowOCR: Bool = true) async -> PageReadResult {
        let stamp = ISO8601DateFormatter().string(from: Date())
        func base(_ status: String, _ detail: String? = nil) -> PagePayload {
            var p = PagePayload(url: tab.url?.absoluteString ?? "", title: tab.title, status: status, statusDetail: detail)
            p.tabID = tab.id.uuidString; p.capturedAt = stamp
            return p
        }

        // 1. nothing to read yet
        guard tab.url != nil, tab.webView.url != nil || tab.failure != nil else { return PageReadResult(payload: base("blank"), thin: false, usedOCR: false) }
        if let f = tab.failure { return PageReadResult(payload: base("error", "\(f.title). \(f.message)"), thin: false, usedOCR: false) }

        // 2. let it finish loading, then let a dynamic page settle
        let deadline = Date().addingTimeInterval(6)
        while tab.isLoading && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        var quiet = 0
        while Date().timeIntervalSince(tab.lastMutationAt) < 0.35 && quiet < 6 { quiet += 1; try? await Task.sleep(nanoseconds: 100_000_000) }
        if let f = tab.failure { return PageReadResult(payload: base("error", "\(f.title). \(f.message)"), thin: false, usedOCR: false) }

        // 3. read the DOM
        guard let json = await evaluate(PageScripts.extract, in: tab.webView, timeout: 4),
              let env = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)) else {
            if let u = tab.url, u.pathExtension.lowercased() == "pdf", let text = await pdfText(from: u) { return pdfResult(base("ready"), text) }
            return PageReadResult(payload: base("restricted", "The page didn't let its content be read (or took too long to respond)."), thin: false, usedOCR: false)
        }
        var p = env.payload
        let stats = env.stats ?? Stats()
        p.tabID = tab.id.uuidString; p.capturedAt = stamp
        if p.url.isEmpty { p.url = tab.url?.absoluteString ?? "" }
        if p.title.isEmpty { p.title = tab.title }

        // 4. PDFs are drawn by PDFKit, so there is no DOM text: fetch the file and read it
        if stats.isPdf == true || tab.url?.pathExtension.lowercased() == "pdf" {
            if let u = tab.url, let text = await pdfText(from: u) { return pdfResult(p, text) }
            p.status = "restricted"; p.statusDetail = "This PDF couldn't be downloaded for reading (it may need a sign-in)."
            return PageReadResult(payload: p, thin: true, usedOCR: false)
        }

        // 5. screenshot + OCR for content that is not in the DOM (never for sign-in pages)
        let length = stats.textLength ?? p.text.count
        let thin = length < 600 || ((stats.canvases ?? 0) > 0 && length < 3000)
        var usedOCR = false
        if allowOCR, p.status == "ready" || p.status == "loading", forceOCR || thin, stats.signIn != true,
           let text = await ocrViewport(tab.webView), !text.isEmpty {
            p.ocrText = String(text.prefix(20_000)); p.source = p.text.isEmpty ? "ocr" : "dom+ocr"; usedOCR = true
        }
        return PageReadResult(payload: p, thin: thin, usedOCR: usedOCR)
    }

    private static func pdfResult(_ base: PagePayload, _ text: String) -> PageReadResult {
        var p = base; p.text = text; p.source = "pdf"; p.status = "ready"; p.statusDetail = nil
        return PageReadResult(payload: p, thin: false, usedOCR: false)
    }

    // MARK: JavaScript with a time limit
    private static func evaluate(_ js: String, in wv: WKWebView, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                do { return try await wv.evaluateJavaScript(js) as? String } catch { return nil }
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: PDF
    private static func pdfText(from url: URL) async -> String? {
        guard ["http", "https"].contains((url.scheme ?? "").lowercased()) else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true, data.count < 25_000_000 else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let doc = PDFDocument(data: data) else { return nil }
            var out = ""
            for i in 0..<min(doc.pageCount, 80) {
                if let t = doc.page(at: i)?.string { out += t + "\n\n" }
                if out.count > 250_000 { break }
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(250_000))
        }.value
    }

    // MARK: screenshot + OCR
    private static func ocrViewport(_ wv: WKWebView) async -> String? {
        guard wv.window != nil, wv.bounds.width > 10, wv.bounds.height > 10 else { return nil }        // a web view that is not on screen cannot be captured
        let cfg = WKSnapshotConfiguration()
        cfg.rect = wv.bounds
        cfg.snapshotWidth = NSNumber(value: Double(min(1800, wv.bounds.width * 2)))
        guard let image = try? await wv.takeSnapshot(configuration: cfg),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await Task.detached(priority: .userInitiated) { recognize(cg) }.value
    }

    /// Vision OCR, returned in reading order: lines top to bottom, words left to right.
    nonisolated static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        let items: [(box: CGRect, text: String)] = (request.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence > 0.3 else { return nil }
            return (obs.boundingBox, c.string)
        }
        guard !items.isEmpty else { return nil }
        let byTop = items.sorted { $0.box.midY > $1.box.midY }                      // Vision's origin is bottom-left, so larger y = higher on screen
        var lines: [[(box: CGRect, text: String)]] = []
        for item in byTop {
            if let anchor = lines.last?.first, abs(anchor.box.midY - item.box.midY) < 0.012 { lines[lines.count - 1].append(item) }
            else { lines.append([item]) }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }
}
