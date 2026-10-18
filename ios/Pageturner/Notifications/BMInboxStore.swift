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

    var unreadCount: Int { BMInbox.unreadCount(items) }

    private var key: String? {
        BookMaster.shared.user.map { "bm-inbox-\($0.username)" }
    }

    /// Load the saved history for the linked reader, once for each account.
    func loadIfNeeded() {
        let current = key
        guard current != loadedFor else { return }
        loadedFor = current
        guard let current,
              let data = UserDefaults.standard.data(forKey: current),
              let held = try? JSONDecoder().decode([BMInboxItem].self, from: data)
        else {
            items = []
            return
        }
        items = held
    }

    /// What BookMaster says is waiting, folded into the history.
    func absorb(nudges: [BMNudge], notices: [BMNotice]) {
        loadIfNeeded()
        guard key != nil else { return }
        let waiting = BMInbox.items(nudges: nudges, notices: notices, now: Date().timeIntervalSince1970)
        items = BMInbox.merge(items, with: waiting)
        save()
    }

    func markRead(ids: Set<String>) {
        guard items.contains(where: { ids.contains($0.id) && !$0.read }) else { return }
        items = BMInbox.markingRead(items, ids: ids)
        changed()
    }

    /// The chat was opened or read: its messages are read here too.
    func markChatRead() {
        markRead(ids: Set(items.filter { $0.id.hasPrefix("notice:" + BMChat.noticePrefix) }.map(\.id)))
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        items = BMInbox.markingRead(items)
        changed()
    }

    func remove(id: String) {
        items = BMInbox.removing(items, id: id)
        changed()
    }

    func clear() {
        items = []
        changed()
    }

    /// Unlinking: the history belongs to the account that went away.
    func reset() {
        if let key { UserDefaults.standard.removeObject(forKey: key) }
        items = []
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
    }
}
