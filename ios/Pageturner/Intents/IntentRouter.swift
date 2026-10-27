import Foundation
import Observation

/// Where Siri, Shortcuts and Spotlight hand a request over to the app. They can
/// arrive before the first screen exists (a cold launch from Siri), so the
/// request waits here until the shell picks it up.
@Observable
@MainActor
final class IntentRouter {
    static let shared = IntentRouter()

    enum Request: Equatable {
        case open(UUID)
        case continueReading
        /// Mark a book finished (BookMaster is told), or start it over.
        case finish(UUID)
        case restart(UUID)
        /// A notification's tap (`pageturner://open?…`): the chat, or one of the suite's web apps.
        case openSuite(BMDeepLink.Target)
        /// The Home Screen's "Add Books": the Files picker.
        case importBooks
        /// A book downloaded from its own page is in: open it, unless another is in the reader.
        case openDownloaded(UUID)
        /// From a PDF to its text version (made first if need be), or back: at the page (0-based) or the chapter
        /// and how far into it that the reader was on.
        case switchVersion(from: UUID, page: Int?, chapter: Int?, progression: Double?)
    }

    var request: Request?

    private init() {}
}
