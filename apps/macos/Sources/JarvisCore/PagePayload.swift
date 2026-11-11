import Foundation

/// What the app read from the active browser tab and sends with a chat message. Field names match the bridge's `PageIn`
/// (a fixture-backed test keeps them in sync). Decoding is lenient because most of it comes from JavaScript running on
/// arbitrary websites: a missing or odd field must never make reading the page fail.
public struct PagePayload: Codable, Sendable, Equatable {
    public struct Price: Codable, Sendable, Equatable {
        public var text: String; public var label: String?
        public init(text: String, label: String? = nil) { self.text = text; self.label = label }
    }
    public struct Spec: Codable, Sendable, Equatable {
        public var name: String; public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public struct Link: Codable, Sendable, Equatable {
        public var text: String; public var href: String
        public init(text: String, href: String) { self.text = text; self.href = href }
    }

    public var url: String
    public var title: String
    public var tabID: String?
    public var status: String                    // ready | loading | error | restricted | blank
    public var statusDetail: String?
    public var lang: String?
    public var canonical: String?
    public var meta: [String: String]
    public var structured: [JSONValue]
    public var prices: [Price]
    public var specs: [Spec]
    public var headings: [String]
    public var tables: [[[String]]]
    public var text: String
    public var visibleText: String
    public var selection: String
    public var ocrText: String
    public var links: [Link]
    public var scroll: [String: Double]?
    public var source: String                    // dom | ocr | dom+ocr | pdf
    public var notes: [String]
    public var capturedAt: String?

    enum CodingKeys: String, CodingKey {
        case url, title, tabID = "tab_id", status, statusDetail = "status_detail", lang, canonical, meta, structured, prices, specs, headings, tables
        case text, visibleText = "visible_text", selection, ocrText = "ocr_text", links, scroll, source, notes, capturedAt = "captured_at"
    }

    public init(url: String = "", title: String = "", status: String = "ready", statusDetail: String? = nil) {
        self.url = url; self.title = title; self.tabID = nil; self.status = status; self.statusDetail = statusDetail
        lang = nil; canonical = nil; meta = [:]; structured = []; prices = []; specs = []; headings = []; tables = []
        text = ""; visibleText = ""; selection = ""; ocrText = ""; links = []; scroll = nil; source = "dom"; notes = []; capturedAt = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? "" }
        func opt(_ k: CodingKeys) -> String? { let v = str(k); return v.isEmpty ? nil : v }
        url = str(.url); title = str(.title); tabID = opt(.tabID); status = opt(.status) ?? "ready"; statusDetail = opt(.statusDetail)
        lang = opt(.lang); canonical = opt(.canonical)
        meta = ((try? c.decodeIfPresent([String: String].self, forKey: .meta)) ?? nil) ?? [:]
        structured = ((try? c.decodeIfPresent([JSONValue].self, forKey: .structured)) ?? nil) ?? []
        prices = ((try? c.decodeIfPresent([Price].self, forKey: .prices)) ?? nil) ?? []
        specs = ((try? c.decodeIfPresent([Spec].self, forKey: .specs)) ?? nil) ?? []
        headings = ((try? c.decodeIfPresent([String].self, forKey: .headings)) ?? nil) ?? []
        tables = ((try? c.decodeIfPresent([[[String]]].self, forKey: .tables)) ?? nil) ?? []
        text = str(.text); visibleText = str(.visibleText); selection = str(.selection); ocrText = str(.ocrText)
        links = ((try? c.decodeIfPresent([Link].self, forKey: .links)) ?? nil) ?? []
        scroll = (try? c.decodeIfPresent([String: Double].self, forKey: .scroll)) ?? nil
        source = opt(.source) ?? "dom"
        notes = ((try? c.decodeIfPresent([String].self, forKey: .notes)) ?? nil) ?? []
        capturedAt = opt(.capturedAt)
    }

    /// Characters of real content (what the chip shows).
    public var contentCount: Int { text.count + ocrText.count }
    public var isBlank: Bool { status == "blank" || url.isEmpty || url.hasPrefix("about:") }
}

/// The bridge's report of how much of the page it used (drives the "Used this page" chip on an answer).
public struct PageUsed: Codable, Sendable, Equatable {
    public var title: String
    public var url: String
    public var host: String
    public var usedChars: Int
    public var totalChars: Int
    public var excerpted: Bool
    public var source: String
    public var status: String
    public var structured: Bool
    public var prices: Int
    public var ocr: Bool
}

public enum BrowserTarget: Equatable, Sendable {
    case url(URL)            // a real address
    case search(URL)         // not an address: search for it
    case blocked(String)     // refused, with the reason to show
}

/// Turns what the user typed into where to go. Pure, so it can be tested. Dangerous schemes are refused, not searched for.
public enum BrowserURL {
    public static func resolve(_ raw: String) -> BrowserTarget {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .blocked("Type a web address, or something to search for.") }
        let lower = s.lowercased()
        for bad in ["javascript:", "file:", "data:", "vbscript:", "blob:", "view-source:", "about:"] where lower.hasPrefix(bad) {
            return .blocked("\(bad) addresses can't be opened in this browser.")
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let u = URL(string: s), let h = u.host, !h.isEmpty { return .url(u) }
            return search(s)
        }
        if let colon = s.firstIndex(of: ":"), s[..<colon].count > 1, s[..<colon].allSatisfy({ $0.isLetter }), s[s.index(after: colon)...].hasPrefix("//") {
            return .blocked("\(s[..<colon]):// addresses aren't supported here. Only web pages (http and https).")
        }
        if !s.contains(" "), looksLikeHost(s) {
            let scheme = isLocal(s) ? "http" : "https"
            if let u = URL(string: "\(scheme)://\(s)"), let h = u.host, !h.isEmpty { return .url(u) }
        }
        return search(s)
    }

    public static func search(_ query: String) -> BrowserTarget {
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return .search(c.url!)
    }

    private static func hostPart(_ s: String) -> String {
        let cut = s.firstIndex(where: { "/?#".contains($0) }) ?? s.endIndex
        return String(s[..<cut])
    }

    static func isLocal(_ s: String) -> Bool {
        let h = hostPart(s).split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        if h == "localhost" || h.hasSuffix(".local") { return true }
        let p = h.split(separator: ".")
        return p.count == 4 && p.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static func looksLikeHost(_ s: String) -> Bool {
        let hp = hostPart(s)
        let parts = hp.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isNumber) { return false }
        let host = parts[0]
        if host.isEmpty { return false }
        if isLocal(s) { return true }
        guard host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        let tld = labels.last!
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
