import Foundation

/// Turns RVRB chat payloads (HTML sanitised by the server: links, images, formatting) into attributed text plus the
/// images to show under it. Tables arrive as objects and are shown as a placeholder.
enum ChatText {
    enum Image: Hashable {
        case url(URL)
        case data(Data)
    }

    /// How the web app draws an image, from its classes: `circular` (Semantic UI's round image) and `spin` (RVRB's
    /// one turn a second, which the A&E channel's /spin command uses on album art).
    struct ImageStyle: Hashable {
        var circular = false
        var spins = false
    }

    struct Body {
        var text: AttributedString
        var plain: String
        var images: [Image]
        /// Styles of the images that have any.
        var styles: [Image: ImageStyle] = [:]

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
        var styles: [Image: ImageStyle] = [:]
        for match in imageTag.matches(html) {
            guard let src = match.group(1, in: html) else { continue }
            let image: Image? = if src.hasPrefix("data:image") {
                dataImage(src)
            } else if let url = URL(string: decodeEntities(src)), url.scheme?.hasPrefix("http") == true {
                .url(url)
            } else {
                nil
            }
            guard let image else { continue }
            images.append(image)

            if let tag = Range(match.range, in: html).map({ String(html[$0]) }),
               let classes = classAttribute.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))?.group(1, in: tag) {
                let names = Set(classes.split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
                let style = ImageStyle(circular: names.contains("circular"), spins: names.contains("spin"))
                if style != ImageStyle() { styles[image] = style }
            }
        }

        // An image is shown as the image: a link to it (or its bare address) would only repeat it.
        let imageAddresses = Set(images.compactMap { if case .url(let url) = $0 { url.absoluteString } else { nil } })
        func isImageLink(_ address: String) -> Bool {
            guard !images.isEmpty else { return false }
            if imageAddresses.contains(address) { return true }
            let ext = URL(string: address)?.pathExtension.lowercased() ?? ""
            return ["gif", "png", "jpg", "jpeg", "webp"].contains(ext)
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
            let label = decodeEntities(tag.replace(match.group(2, in: text) ?? "", with: "")).trimmingCharacters(in: .whitespaces)
            cursor = range.upperBound

            // A link to the image that's shown, labelled with its own address: leave it out.
            if let href, isImageLink(href), label.isEmpty || label == href || label.hasPrefix("http") {
                continue
            }

            links.append((label.isEmpty ? href ?? "" : label, href.flatMap(URL.init(string:))))
            withPlaceholders += "\u{E000}\(links.count - 1)\u{E001}"
        }
        withPlaceholders += text[cursor...]

        text = decodeEntities(tag.replace(withPlaceholders, with: ""))
        for address in imageAddresses {
            text = text.replacingOccurrences(of: address, with: "")
        }
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

        return Body(text: result, plain: plain, images: images, styles: styles)
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
    private static let classAttribute = regex(#"\bclass\s*=\s*["']([^"']*)["']"#)
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
