import Foundation

/// What a copied text turned out to be. Decided once when it's captured (off the main thread),
/// so rows never re-parse while drawing.
enum ClipKind: Equatable {
    case text
    /// Prose-free text that reads better monospaced (tokens, hashes, snippets).
    case code
    /// JSON object or array. `pretty` is nil when the text is already formatted.
    case json(pretty: String?)
    case url(URL)
    /// Unix time in seconds (10 digits) or milliseconds (13 digits), 2001–2100.
    case timestamp(Date)
    /// `payload` is the decoded claims, pretty-printed.
    case jwt(alg: String, expires: Date?, payload: String)
    case base64(decoded: String)
    case image(width: Int, height: Int)

    var isCodeLike: Bool {
        switch self {
        case .code, .json, .base64: return true
        default: return false
        }
    }
}

/// Recognizes the developer-flavoured things people copy. Every check is strict on purpose:
/// a wrong guess costs more (a misleading label) than a missed one (a plain row).
enum ClipDetector {
    static func classify(_ raw: String) -> ClipKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = url(s) { return .url(url) }
        if let date = timestamp(s) { return .timestamp(date) }
        if let jwt = jwt(s) { return jwt }
        if let pretty = json(s) { return .json(pretty: pretty == s ? nil : pretty) }
        if let decoded = base64(s) { return .base64(decoded: decoded) }
        return looksLikeCode(s) ? .code : .text
    }

    // MARK: URL

    static func url(_ s: String) -> URL? {
        guard s.count < 4096, !s.contains(where: \.isWhitespace),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Timestamp

    /// 2001-01-01 … 2100-01-01: wide enough for real timestamps, narrow enough to skip most IDs.
    static let plausible = 978_307_200.0...4_102_444_800.0

    static func timestamp(_ s: String) -> Date? {
        guard s.count == 10 || s.count == 13, s.allSatisfy(\.isASCIIDigit), let n = Double(s) else { return nil }
        let seconds = s.count == 13 ? n / 1000 : n
        return plausible.contains(seconds) ? Date(timeIntervalSince1970: seconds) : nil
    }

    // MARK: JWT

    static func jwt(_ s: String) -> ClipKind? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              parts.allSatisfy({ $0.allSatisfy(\.isBase64URL) }),
              let headerData = base64URLDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let alg = header["alg"] as? String,
              let payloadData = base64URLDecode(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let payloadText = String(data: payloadData, encoding: .utf8) else { return nil }
        let exp = (claims["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return .jwt(alg: alg, expires: exp, payload: prettyJSON(payloadText))
    }

    static func base64URLDecode(_ part: Substring) -> Data? {
        var b = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }

    // MARK: JSON

    /// Pretty-printed JSON if `s` is a JSON object or array, else nil.
    static func json(_ s: String) -> String? {
        guard let first = s.first, first == "{" || first == "[",
              let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data), obj is [Any] || obj is [String: Any]
        else { return nil }
        return prettyJSON(s)
    }

    /// Re-indents valid JSON without parsing it into dictionaries, so keys keep their original
    /// order (JSONSerialization would shuffle them). Two-space indent, like most formatters.
    static func prettyJSON(_ s: String) -> String {
        let chars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var inString = false, escaped = false
        func newline() {
            out.append("\n")
            out.append(contentsOf: String(repeating: "  ", count: depth).unicodeScalars)
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"":
                    inString = true
                    out.append(c)
                case "{", "[":
                    var j = i + 1
                    while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                        out.append(c); out.append(chars[j]); i = j   // keep {} and [] on one line
                    } else {
                        out.append(c); depth += 1; newline()
                    }
                case "}", "]":
                    depth = max(0, depth - 1); newline(); out.append(c)
                case ",":
                    out.append(c); newline()
                case ":":
                    out.append(c); out.append(" ")
                default:
                    if !c.properties.isWhitespace { out.append(c) }
                }
            }
            i += 1
        }
        return String(out)
    }

    // MARK: Base64

    /// Decoded text if `s` is strict, padded Base64 (≥ 16 chars) of printable UTF-8 text.
    static func base64(_ s: String) -> String? {
        guard s.count >= 16, s.count % 4 == 0 else { return nil }
        let body = s.prefix { $0 != "=" }
        let padding = s.dropFirst(body.count)
        guard padding.count <= 2, padding.allSatisfy({ $0 == "=" }), body.allSatisfy(\.isBase64),
              let data = Data(base64Encoded: s), let text = String(data: data, encoding: .utf8),
              !text.isEmpty, text.unicodeScalars.allSatisfy(isPrintable),
              text.contains(where: \.isLetter) else { return nil }
        return text
    }

    private static func isPrintable(_ u: Unicode.Scalar) -> Bool {
        if u == "\n" || u == "\r" || u == "\t" { return true }
        switch u.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return false
        default: return u != "\u{FFFD}"
        }
    }

    // MARK: Code

    /// Long unbroken tokens (hashes, IDs, keys) or symbol-dense text (snippets, commands).
    static func looksLikeCode(_ s: String) -> Bool {
        let head = s.prefix(2000)
        if head.count >= 16, !head.contains(where: \.isWhitespace) { return true }
        let symbols = head.reduce(0) { $0 + ("{}[]();=<>$|&\\".contains($1) ? 1 : 0) }
        if symbols >= 4, Double(symbols) / Double(head.count) > 0.04 { return true }
        let lines = head.split(separator: "\n")
        return lines.count >= 3 && lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count >= 2
    }

    // MARK: Formatting

    /// "Nov 11, 16:46" (year added when it isn't this year), in the person's locale.
    static func shortDate(_ d: Date, now: Date = Date()) -> String {
        let day = DateFormatter(), time = DateFormatter()
        let sameYear = Calendar.current.isDate(d, equalTo: now, toGranularity: .year)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        time.setLocalizedDateFormatFromTemplate("jmm")
        return "\(day.string(from: d)), \(time.string(from: d))"
    }

    /// ISO 8601 in local time with offset, e.g. "2024-11-11T16:46:40+01:00".
    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        if d.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0 {
            f.formatOptions.insert(.withFractionalSeconds)
        }
        return f.string(from: d)
    }

    /// "now", "4m", "2h", "3d".
    static func compactInterval(_ seconds: TimeInterval) -> String {
        let s = Int(abs(seconds))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isBase64: Bool { isASCII && (isLetter || isNumber || self == "+" || self == "/") }
    var isBase64URL: Bool { isASCII && (isLetter || isNumber || self == "-" || self == "_") }
}
