import BackgroundTasks
import Observation
import UIKit
import UserNotifications

/// Pageturner's own notifications: what BookMaster says is waiting — a suggestion from the other reader, a chat
/// message, news from Kindred or Quest Log — told as a banner while the app is open, kept in the inbox
/// (`BMInboxStore`), and posted as a *local* notification when it is not.
///
/// A sideloaded app has no push entitlement, so nothing arrives by itself: the app asks BookMaster every
/// half minute while it is open (and in the background too, when the reader has asked it to stay
/// connected — `BackgroundKeepAlive`), and otherwise whenever iOS wakes it for a background refresh
/// (when, is its call, not ours). Anything it hasn't already mentioned is told.
@Observable
@MainActor
final class Notifier {
    static let shared = Notifier()
    static let refreshTaskID = "io.github.possiblypengu.pageturner.refresh"

    /// Suggestions waiting on the reader — the Together tab's badge.
    private(set) var pendingCount = 0
    /// The system's answer to "may I send notifications?" — refreshed on demand.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Set when a notification is tapped; the shell switches to Together and clears it.
    var openTogether = false
    /// The banner on screen, and the ones waiting behind it.
    private(set) var banner: BMInboxItem?
    private var bannerQueue: [BMInboxItem] = []
    /// The notice that says a chat message is waiting, as of the last look at BookMaster.
    private(set) var chatNotice: BMNotice?
    /// The chat notice already opened, so its dot stays out until a newer message.
    private var chatSeenID: String?
    /// Quest Log's notices as of the last look, and the ones already looked at (by opening its room).
    private var questLogNotices: [BMNotice] = []
    private var questLogSeen: Set<String> = []

    /// Quest Log has something new that its room has not been opened for — the blue square on the chat's tab.
    var questLogUnread: Bool { BMChat.questLogUnseen(questLogNotices, seen: questLogSeen) }

    /// Quest Log's room was opened.
    func noteQuestLogOpened() { questLogSeen.formUnion(questLogNotices.map(\.id)) }

    /// A chat message waiting that has not been opened — what the Together tab and the floating button show.
    var chatUnread: BMNotice? { BMChat.unread(chatNotice.map { [$0] } ?? [], seen: chatSeenID) }

    /// The chat was opened, from wherever.
    func noteChatOpened() {
        chatSeenID = chatNotice?.id
        BMInboxStore.shared.markChatRead()
    }

    private let defaults = UserDefaults.standard

    /// Whether the reader wants notifications. Observable, stored in UserDefaults.
    var enabled: Bool {
        get {
            access(keyPath: \.enabled)
            return defaults.bool(forKey: "notify-suggestions")
        }
        set {
            withMutation(keyPath: \.enabled) {
                defaults.set(newValue, forKey: "notify-suggestions")
            }
        }
    }

    /// Switched on but refused (or later turned off) in iOS Settings.
    /// Background App Refresh is how suggestions arrive while the app is closed: with it off they only show on opening.
    var backgroundRefreshOff: Bool { UIApplication.shared.backgroundRefreshStatus != .available }

    var blockedBySystem: Bool { authorization == .denied && (enabled || wasRefused) }
    /// The reader switched it on and iOS said no — `enabled` stays off then, and without this the toggle
    /// would just spring back with no word on why or how to fix it.
    var wasRefused = false

    /// What was already announced, kept per account so another one starts fresh.
    private var seenKey: String? {
        BookMaster.shared.user.map { "notified-ids-\($0.username)" }
    }

    // MARK: Switching on and off

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization != .denied { wasRefused = false }   // allowed in iOS Settings since: nothing left to explain
    }

    /// The Settings toggle. Switching on asks iOS for permission the first time.
    func setEnabled(_ on: Bool) async {
        guard on else {
            enabled = false
            wasRefused = false
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
            await setBadge(0)
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            return
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        enabled = granted
        wasRefused = !granted
        guard granted else { return }
        // what is waiting right now is already known — only new things get announced
        await refresh(notify: false)
        scheduleRefresh()
    }

    // MARK: Looking

    /// Ask BookMaster what is waiting, and tell what is new: as a banner while the app is open, as a
    /// notification when it is not (`notify`: behind the app, where the reader allowed it).
    func refresh(notify: Bool) async {
        guard BookMaster.shared.isLinked,
              let together = try? await BookMaster.shared.fetchTogether()
        else { return }
        let announce = settle(together)
        await refreshAuthorization()
        guard !announce.isEmpty else { return }
        if UIApplication.shared.applicationState == .active {
            if AppPrefs.bannersOn { show(announce) }
        } else if notify, enabled {
            await post(announce)
        }
    }

    // MARK: Banners

    /// Queue banners for what is new — the inbox already holds each, so a banner is just a way of saying so.
    private func show(_ items: [NotificationPlan.Item]) {
        let inbox = BMInboxStore.shared
        // a message arriving while the chat is open is already being read
        let inChat = BookMaster.shared.place == "chat"
        for item in items where !(inChat && item.id.hasPrefix("notice:" + BMChat.noticePrefix)) {
            // a pile at once is one line, which is not in the inbox as such
            let entry = inbox.items.first { $0.id == item.id }
                ?? BMInboxItem(id: item.id, app: "bookmaster", title: item.title, body: item.body, path: nil,
                               at: Date().timeIntervalSince1970, read: false)
            bannerQueue.append(entry)
        }
        if banner == nil { presentNext() }
    }

    private func presentNext() {
        guard !bannerQueue.isEmpty else {
            banner = nil
            return
        }
        let next = bannerQueue.removeFirst()
        banner = next
        UIAccessibility.post(notification: .announcement, argument: "\(next.title). \(next.body)")
    }

    /// The banner has been tapped, swiped away or timed out: the next one, if there is one.
    func dismissBanner() { presentNext() }

    /// The app icon's badge counts what is unread in the inbox.
    func refreshBadge() {
        guard enabled else { return }
        let unread = BMInboxStore.shared.unreadCount
        Task { await setBadge(unread) }
    }

    /// The Together tab loaded or changed — keep the badge and the "already told" set in step.
    func noteSeen(_ together: BMTogether) {
        _ = settle(together)
        // the tab is on screen: banners still in Notification Center say what it already shows
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Update the count and the remembered set; return what is new since last time.
    private func settle(_ together: BMTogether) -> [NotificationPlan.Item] {
        pendingCount = together.nudges.count
        chatNotice = BMChat.unreadNotice(together.notices)
        questLogNotices = BMChat.questLogNotices(together.notices)
        BMInboxStore.shared.absorb(nudges: together.nudges, notices: together.notices)
        guard let key = seenKey else { return [] }
        let known = defaults.stringArray(forKey: key).map { Set($0) }
        let result = NotificationPlan.plan(nudges: together.nudges, notices: together.notices, seen: known)
        defaults.set(Array(result.seen), forKey: key)
        refreshBadge()
        return result.items
    }

    private func post(_ items: [NotificationPlan.Item]) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = "together"
            // no trigger: deliver now
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    private func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    // MARK: Background refresh

    /// Line up the next background check — or drop it when it has no job to do.
    func scheduleRefresh() {
        let scheduler = BGTaskScheduler.shared
        guard enabled, BookMaster.shared.isLinked else {
            scheduler.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? scheduler.submit(request)
    }

    /// What the system's background refresh runs: look, announce, line up the next.
    func backgroundRefresh() async {
        defer { scheduleRefresh() }
        guard enabled, BookMaster.shared.isLinked else { return }
        await refresh(notify: true)
    }

    /// Unlinking: forget the count and the badge.
    func reset() {
        pendingCount = 0
        chatNotice = nil
        chatSeenID = nil
        questLogNotices = []
        questLogSeen = []
        bannerQueue = []
        banner = nil
        BMInboxStore.shared.reset()
        wasRefused = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        // banners already on the lock screen belong to the account that just went away
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        Task { await setBadge(0) }
    }
}

/// Receives notification taps. A notification that arrives while the app is in
/// front stays quiet — the Together tab already shows what it would say.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { Notifier.shared.openTogether = true }
    }
}
