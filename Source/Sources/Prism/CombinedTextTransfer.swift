import AppKit

enum CombinedTextTransfer {
    /// A single combined representation lets text editors paste every selected
    /// entry, including editors that consume only the first pasteboard item.
    static func payload(from clips: [Clip]) throws -> Payload? {
        guard clips.reduce(0, { $0 + $1.itemCount }) > 1,
              clips.allSatisfy({ clip in
                  !clip.hasFileReferences && (["文本", "富文本", "链接"].contains(clip.kind) ||
                      clip.typeNames.contains(NSPasteboard.PasteboardType.rtfd.rawValue))
              }) else { return nil }
        let payloads = try clips.flatMap { try $0.loadPayloads() }
        guard payloads.count > 1 else { return nil }
        let hasHTML = payloads.contains { $0.data(.html) != nil }
        let hasRichText = payloads.contains { $0.data(.rtf) != nil || $0.data(.rtfd) != nil }
        if !hasHTML && !hasRichText {
            let strings = payloads.map { Clip.extractText([$0]) }
            guard strings.allSatisfy({ !$0.isEmpty }) else { return nil }
            return Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data(strings.joined(separator: "\n").utf8)])
        }
        let combined = NSMutableAttributedString(string: "")
        var htmlFragments: [String] = []
        var hasHTMLOnly = false
        var hasAttachments = false
        for payload in payloads {
            guard try payload.transferFileURLs().isEmpty,
                  !payload.types.keys.contains(where: { Payload.imageType($0) != nil }),
                  payload.data(.pdf) == nil else { return nil }
            let rich: NSAttributedString
            if let bytes = payload.data(.rtfd), let attributed = NSAttributedString(rtfd: bytes, documentAttributes: nil) {
                rich = attributed
                hasAttachments = true
            } else if let bytes = payload.data(.rtf), let attributed = NSAttributedString(rtf: bytes, documentAttributes: nil) {
                rich = attributed
            } else {
                let plain = Clip.extractText([payload])
                guard !plain.isEmpty else { return nil }
                rich = NSAttributedString(string: plain)
                hasHTMLOnly = hasHTMLOnly || payload.data(.html) != nil
            }
            if combined.length > 0 { combined.append(NSAttributedString(string: "\n")) }
            combined.append(rich)
            guard hasHTML else { continue }
            if let html = payload.string(.html) {
                htmlFragments.append(htmlBody(html))
            } else if let bytes = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
                      let html = String(data: bytes, encoding: .utf8) {
                htmlFragments.append(htmlBody(html))
            } else {
                let escaped = rich.string.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                    .replacingOccurrences(of: "\n", with: "<br>")
                htmlFragments.append(escaped)
            }
        }
        let range = NSRange(location: 0, length: combined.length)
        var types = [NSPasteboard.PasteboardType.string.rawValue: Data(combined.string.utf8)]
        if hasAttachments, let bytes = combined.rtfd(from: range, documentAttributes: [:]) {
            types[NSPasteboard.PasteboardType.rtfd.rawValue] = bytes
        }
        if !hasHTMLOnly, let bytes = combined.rtf(from: range, documentAttributes: [:]) {
            types[NSPasteboard.PasteboardType.rtf.rawValue] = bytes
        }
        if hasHTML {
            let body = htmlFragments.map { "<div>\($0)</div>" }.joined(separator: "\n")
            types[NSPasteboard.PasteboardType.html.rawValue] = Data("<html><body>\(body)</body></html>".utf8)
        }
        return Payload(types: types)
    }

    private static func htmlBody(_ html: String) -> String {
        // Retain embedded styles without invoking the WebKit HTML importer.
        let expression = try? NSRegularExpression(pattern: "(?is)<body\\b[^>]*>(.*?)</body\\s*>")
        let string = html as NSString
        if let match = expression?.firstMatch(in: html, range: NSRange(location: 0, length: string.length)) {
            let styleExpression = try? NSRegularExpression(pattern: "(?is)<style\\b[^>]*>.*?</style\\s*>")
            let styles = styleExpression?.matches(in: html, range: NSRange(location: 0, length: string.length))
                .map { string.substring(with: $0.range) }.joined(separator: "\n") ?? ""
            return styles + string.substring(with: match.range(at: 1))
        }
        return html.replacingOccurrences(of: "(?is)<!doctype[^>]*>|</?(?:html|head|body)\\b[^>]*>",
                                        with: "", options: .regularExpression)
    }
}
