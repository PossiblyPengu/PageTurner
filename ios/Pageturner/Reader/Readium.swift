import Foundation
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer

/// Shared Readium components for opening publications.
final class Readium {
    static let shared = Readium()

    private let httpClient = DefaultHTTPClient()
    private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    private lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        )
    )

    enum OpenError: LocalizedError {
        case notAFile
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notAFile: return "That isn't a file on this device."
            case let .unreadable(detail):
                // a truncated or fake book file reaches Readium as a ZIPFoundation ArchiveError
                if detail.contains("ArchiveError") {
                    return "The file is incomplete or damaged — download it again and re-import it."
                }
                return "The file couldn't be read. (\(detail))"
            case let .unsupported(detail): return "This format isn't supported yet. (\(detail))"
            }
        }
    }

    func open(url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else { throw OpenError.notAFile }
        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case let .success(a): asset = a
        case let .failure(error): throw OpenError.unreadable(String(describing: error))
        }
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case let .success(publication): return publication
        case let .failure(error): throw OpenError.unsupported(String(describing: error))
        }
    }
}
