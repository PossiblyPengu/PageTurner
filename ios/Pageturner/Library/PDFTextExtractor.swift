import PDFKit
import UIKit

/// Every printed line of a PDF, page by page, as `PDFText` lays out again: where each line sits on its page and the
/// size it is set in. PDFKit's own reading order is kept (a two-column page reads column by column).
enum PDFTextExtractor {
    static func lines(in url: URL, progress: (@Sendable (Double) -> Void)? = nil) -> [PDFText.Line]? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        var out: [PDFText.Line] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            guard let all = page.selection(for: box) else { continue }
            for line in all.selectionsByLine() {
                guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let r = line.bounds(for: page)
                var size = Double(r.height)
                if let styled = line.attributedString, styled.length > 0,
                   let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                    size = Double(font.pointSize)
                }
                out.append(PDFText.Line(
                    text: text, page: index,
                    x: Double(r.minX - box.minX), y: Double(box.maxY - r.maxY),
                    width: Double(r.width), height: Double(r.height), size: size))
            }
            progress?(Double(index + 1) / Double(document.pageCount))
        }
        return out
    }
}
