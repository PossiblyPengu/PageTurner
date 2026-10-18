import Foundation
import Observation

/// The reader's notifications, kept: what they have been told (`BMInbox` decides how it is folded and
/// ordered), saved on this iPhone per BookMaster account so a restart does not lose it.
@Observable
@MainActor
final class BMInboxStore {
    static let shared = BMInboxStore()

    private(set) var items: [BMInboxItem] = []
    /// The account whose history is loaded, so another account starts fresh.
    private var loadedFor: String?
    /// What the reader cleared or swiped away while BookMaster still lists it as waiting: held back, so the next
    /// look does not bring it back unread. Each is dropped once it leaves the feed.
    private var dismissed: Set<String> = []

    var unreadCount: Int { BMInbox.unreadCount(items) }

    private var key: String? {
        BookMaster.shared.user.map { "bm-inbox-\($0.username)" }
    }

    /// Load the saved history for the linked reader, once for each account.
    func loadIfNeeded() {
        let current = key
        guard current != loadedFor else { return }
        loadedFor = current
        items = []
        dismissed = []
        guard let current else { return }
        if let data = UserDefaults.standard.data(forKey: current),
           let held = try? JSONDecoder().decode([BMInboxItem].self, from: data) {
            items = held
        }
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey(current)) ?? [])
    }

    private static func dismissedKey(_ key: String) -> String { key + "-dismissed" }

    /// What BookMaster says is waiting, folded into the history.
    func absorb(nudges: [BMNudge], notices: [BMNotice]) {
        loadIfNeeded()
        guard key != nil else { return }
        let feed = BMInbox.items(nudges: nudges, notices: notices, now: Date().timeIntervalSince1970)
        dismissed.formIntersection(feed.map(\.id))
        items = BMInbox.merge(items, with: feed.filter { !dismissed.contains($0.id) })
        save()
    }

    func markRead(ids: Set<String>) {
        loadIfNeeded()   // a tap soon after launch comes before the first look has loaded the history
        guard items.contains(where: { ids.contains($0.id) && !$0.read }) else { return }
        items = BMInbox.markingRead(items, ids: ids)
        changed()
    }

    /// The chat was opened or read: its messages are read here too.
    func markChatRead() {
        markRead(ids: Set(items.filter { $0.id.hasPrefix("notice:" + BMChat.noticePrefix) }.map(\.id)))
    }

    func markAllRead() {
        loadIfNeeded()
        guard unreadCount > 0 else { return }
        items = BMInbox.markingRead(items)
        changed()
    }

    func remove(id: String) {
        loadIfNeeded()
        dismissed.insert(id)
        items = BMInbox.removing(items, id: id)
        changed()
    }

    func clear() {
        loadIfNeeded()
        dismissed.formUnion(items.map(\.id))
        items = []
        changed()
    }

    /// Unlinking: the history belongs to the account that went away.
    func reset() {
        // the reader is already gone by now, so no key names the history: sweep every account's
        let defaults = UserDefaults.standard
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix("bm-inbox-") {
            defaults.removeObject(forKey: name)
        }
        items = []
        dismissed = []
        loadedFor = nil
    }

    private func changed() {
        save()
        // the app icon's badge counts what is unread
        Notifier.shared.refreshBadge()
    }

    private func save() {
        guard let key, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey(key))
    }
}
