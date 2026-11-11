import Foundation

public enum SSE {
    /// Returns the payload of an SSE `data:` line, or nil for comments, blanks and other fields.
    public static func dataPayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var s = line.dropFirst(5)
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }
}
