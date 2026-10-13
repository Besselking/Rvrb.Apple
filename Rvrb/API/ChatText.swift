import Foundation

/// Turns RVRB chat payloads (HTML sanitised by the server: links, images, formatting) into attributed text plus the
/// images to show under it. Tables arrive as objects and are shown as a placeholder.
enum ChatText {
    enum Image: Hashable {
        case url(URL)
        case data(Data)
    }

    struct Body {
        var text: AttributedString
        var plain: String
        var images: [Image]

        static let empty = Body(text: "", plain: "", images: [])
    }

    static func parse(_ payload: JSON?) -> Body {
        guard let html = payload?.string else {
            return payload?.object != nil ? Body(text: "[table]", plain: "[table]", images: []) : .empty
        }

        if html.hasPrefix("data:image") {
            return Body(text: "", plain: "", images: dataImage(html).map { [$0] } ?? [])
        }

        var images: [Image] = []
        for match in imageTag.matches(html) {
            guard let src = match.group(1, in: html) else { continue }
            if src.hasPrefix("data:image") {
                if let image = dataImage(src) { images.append(image) }
            } else if let url = URL(string: decodeEntities(src)), url.scheme?.hasPrefix("http") == true {
                images.append(.url(url))
            }
        }

        var text = imageTag.replace(html, with: "")
        text = lineBreak.replace(text, with: "\n")

        // Links become placeholders (private-use characters) so tag stripping and entity decoding leave them alone.
        var links: [(text: String, url: URL?)] = []
        var withPlaceholders = ""
        var cursor = text.startIndex

        for match in anchor.matches(text) {
            guard let range = Range(match.range, in: text) else { continue }
            withPlaceholders += text[cursor..<range.lowerBound]
            let href = match.group(1, in: text).map(decodeEntities)
            let label = decodeEntities(tag.replace(match.group(2, in: text) ?? "", with: ""))
            links.append((label.isEmpty ? href ?? "" : label, href.flatMap(URL.init(string:))))
            withPlaceholders += "\u{E000}\(links.count - 1)\u{E001}"
            cursor = range.upperBound
        }
        withPlaceholders += text[cursor...]

        text = decodeEntities(tag.replace(withPlaceholders, with: ""))
        text = blankLines.replace(text, with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Rebuild with the links in place, detecting bare URLs in the rest.
        var result = AttributedString()
        var plain = ""
        var rest = Substring(text)

        while let open = rest.firstIndex(of: "\u{E000}"), let close = rest[open...].firstIndex(of: "\u{E001}"),
              let index = Int(rest[rest.index(after: open)..<close]), links.indices.contains(index) {
            result += linkified(String(rest[..<open]))
            plain += rest[..<open]

            var link = AttributedString(links[index].text)
            link.link = links[index].url
            result += link
            plain += links[index].text
            rest = rest[rest.index(after: close)...]
        }

        result += linkified(String(rest))
        plain += rest

        return Body(text: result, plain: plain, images: images)
    }

    /// Plain text with any bare URLs made into links.
    private static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector, text.contains(".") else { return result }

        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    private static func dataImage(_ uri: String) -> Image? {
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters)
        else { return nil }
        return .data(data)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        var cursor = text.startIndex

        for match in entity.matches(text) {
            guard let range = Range(match.range, in: text), let name = match.group(1, in: text) else { continue }
            result += text[cursor..<range.lowerBound]

            let decoded: String? = if name.hasPrefix("#x") || name.hasPrefix("#X") {
                UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                namedEntities[name]
            }

            result += decoded ?? String(text[range])
            cursor = range.upperBound
        }

        return result + text[cursor...]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®",
        "trade": "™", "middot": "·", "bull": "•", "times": "×", "eacute": "é", "euro": "€",
    ]

    private static let imageTag = regex(#"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["'][^>]*>|<img\b[^>]*>"#)
    private static let lineBreak = regex(#"<br\s*/?>|</p>|</div>|</li>|</h[1-6]>"#)
    private static let anchor = regex(#"<a\b[^>]*?\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#)
    private static let tag = regex("<[^>]+>")
    private static let blankLines = regex(#"\n[ \t]*\n+"#)
    private static let entity = regex("&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
}

private extension NSRegularExpression {
    func matches(_ text: String) -> [NSTextCheckingResult] {
        matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func replace(_ text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges, let range = Range(range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
