import UIKit

/// RTF (Word, TextEdit and Pages all save it) read with iOS's own reader into the HTML `TextBook` makes an EPUB
/// of. RTF has no headings, so a short paragraph set larger than the text, or all in bold, is taken for one — and
/// chapters are cut there. Bold and italic runs are kept. (iOS's reader gives no title or author — those are the
/// Mac's — so the name of the file stands in until the details are looked up.)
enum RTFBook {
    static func html(from data: Data) throws -> String {
        let text = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let whole = text.string as NSString
        let all = NSRange(location: 0, length: whole.length)
        let body = bodySize(of: text)

        var html = ""
        whole.enumerateSubstrings(in: all, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let plain = whole.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }
            var runs = ""
            var biggest: CGFloat = 0
            var allBold = true
            text.enumerateAttribute(.font, in: range) { value, run, _ in
                let piece = TextBook.esc(whole.substring(with: run))
                let font = value as? UIFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                if !whole.substring(with: run).trimmingCharacters(in: .whitespaces).isEmpty {
                    biggest = max(biggest, font?.pointSize ?? 0)
                    if !traits.contains(.traitBold) { allBold = false }
                }
                var marked = piece
                if traits.contains(.traitItalic) { marked = "<em>\(marked)</em>" }
                if traits.contains(.traitBold) { marked = "<strong>\(marked)</strong>" }
                runs += marked
            }
            let short = plain.count <= 80 && !".,;".contains(plain.last ?? " ")
            if short, body > 0, biggest >= body * 1.3 {
                html += "<h1>\(TextBook.esc(plain))</h1>\n"
            } else if short, allBold, plain.count <= 60 {
                html += "<h2>\(TextBook.esc(plain))</h2>\n"
            } else {
                html += "<p>\(runs)</p>\n"
            }
        }
        return "<html><body>\n\(html)</body></html>"
    }

    /// The size most of the text is set in, by length.
    private static func bodySize(of text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, run, _ in
            guard let size = (value as? UIFont)?.pointSize else { return }
            counts[size, default: 0] += run.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }
}
