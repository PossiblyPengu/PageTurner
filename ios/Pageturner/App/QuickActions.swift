import UIKit

/// The Home Screen quick actions — a long press on the app icon: pick up the book you are in, open one of the others
/// you have going, or add books. They are dynamic items the app sets itself (no extension, so a sideloaded build has
/// them too), refreshed whenever the app goes to the background, which is when the Home Screen can show them.
@MainActor
enum QuickActions {
    private static let prefix = "io.github.possiblypengu.pageturner."
    private static let continueType = prefix + "continue"
    private static let openType = prefix + "open"
    private static let importType = prefix + "import"
    private static let bookKey = "book"

    /// Set the menu from the library as it is now.
    static func update(_ library: LibraryStore) {
        var items: [UIApplicationShortcutItem] = []
        let current = library.continueBook
        if let current {
            items.append(UIApplicationShortcutItem(
                type: continueType,
                localizedTitle: current.isAudio ? "Continue Listening" : "Continue Reading",
                localizedSubtitle: current.title,
                icon: UIApplicationShortcutIcon(systemImageName: current.isAudio ? "headphones" : "book.fill"),
                userInfo: nil))
        }
        // the others begun and not finished, last opened first
        let others = library.books
            .filter { $0.id != current?.id && $0.lastOpenedAt != nil && ($0.progression ?? 0) < 0.995 }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(2)
        for book in others {
            items.append(UIApplicationShortcutItem(
                type: openType,
                localizedTitle: book.title,
                localizedSubtitle: book.author.isEmpty ? nil : book.author,
                icon: UIApplicationShortcutIcon(systemImageName: book.isAudio ? "headphones" : "book.closed"),
                userInfo: [bookKey: book.id.uuidString as NSString]))
        }
        items.append(UIApplicationShortcutItem(
            type: importType, localizedTitle: "Add Books", localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "plus"), userInfo: nil))
        UIApplication.shared.shortcutItems = items
    }

    /// Hand a chosen action to the app, the way Siri's requests come in. False for an item this build doesn't know.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case continueType:
            IntentRouter.shared.request = .continueReading
        case openType:
            guard let raw = item.userInfo?[bookKey] as? String, let id = UUID(uuidString: raw) else { return false }
            IntentRouter.shared.request = .open(id)
        case importType:
            IntentRouter.shared.request = .importBooks
        default:
            return false
        }
        return true
    }
}

/// Where iOS hands over a quick action chosen while the app was already running (a cold launch brings it through
/// `PageturnerAppDelegate`'s scene configuration instead).
@MainActor
final class PageturnerSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickActions.handle(shortcutItem))
    }
}
