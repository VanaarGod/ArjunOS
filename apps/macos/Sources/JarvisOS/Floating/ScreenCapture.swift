import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import JarvisCore

/// Captures the window that is behind ArjunOS: the frontmost on-screen window that does not belong to this app.
/// Only that one window is captured (ScreenCaptureKit "desktop independent window" filter), so ArjunOS's own pet,
/// mini chat and main window can never end up in the picture, and neither can other windows or the desktop.
enum ScreenCapture {
    struct Shot {
        var name: String            // shown on the attachment chip, e.g. "Screen · Safari – Apple"
        var jpegBase64: String
        var bytes: Int
        var appName: String
    }

    enum Failure: LocalizedError {
        case noWindow, blocked, failed(String)
        var errorDescription: String? {
            switch self {
            case .noWindow: "There is no window behind \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ArjunOS") to look at. Open the app you want help with, then try again."
            case .blocked: "macOS blocked the screen capture. Allow ArjunOS in System Settings → Privacy & Security → Screen Recording, then restart the app."
            case .failed(let m): "The screen capture failed (\(m))."
            }
        }
    }

    struct WindowInfo { var id: CGWindowID; var app: String; var title: String }

    /// The window list is ordered front to back, so the first normal window of another app is the one directly behind us.
    static func windowBehindUs() -> WindowInfo? {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,                                   // normal app windows, not the menu bar, Dock or overlays
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 120, rect.height >= 80 else { continue }
            return WindowInfo(id: CGWindowID(id), app: (w[kCGWindowOwnerName as String] as? String) ?? "Another app", title: (w[kCGWindowName as String] as? String) ?? "")
        }
        return nil
    }

    static func captureWindowBehindUs(maxDimension: CGFloat = 1568) async throws -> Shot {
        guard let info = windowBehindUs() else { throw Failure.noWindow }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw Failure.blocked }
        guard let window = content.windows.first(where: { $0.windowID == info.id }) else { throw Failure.noWindow }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect, scale = CGFloat(filter.pointPixelScale)
        let natural = CGSize(width: max(rect.width * scale, 1), height: max(rect.height * scale, 1))
        let shrink = min(1, maxDimension / max(natural.width, natural.height))              // vision models gain nothing from more pixels
        let config = SCStreamConfiguration()
        config.width = Int((natural.width * shrink).rounded()); config.height = Int((natural.height * shrink).rounded())
        config.showsCursor = false
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw Failure.failed(error.localizedDescription) }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.failed("could not encode the image") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.failed("could not encode the image") }

        let title = info.title.isEmpty ? "" : " – \(String(info.title.prefix(40)))"
        return Shot(name: "Screen · \(info.app)\(title)", jpegBase64: (out as Data).base64EncodedString(), bytes: out.length, appName: info.app)
    }
}
