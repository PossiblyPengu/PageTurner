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
    }

    var request: Request?

    private init() {}
}
