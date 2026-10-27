import CoreSpotlight
import SwiftUI
import UIKit
import UserNotifications

/// Where iOS hands the app a background session's events — Drive downloads that finished while it was not running.
@MainActor
final class PageturnerAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DriveDownloads.identifier else { completionHandler(); return }
        DriveDownloads.shared.holdBackgroundCompletion(completionHandler)
    }

    /// The scene gets a delegate of its own for the Home Screen quick actions chosen while the app runs; one that
    /// launched the app arrives here.
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickActions.handle(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PageturnerSceneDelegate.self
        return configuration
    }
}

@main
struct PageturnerApp: App {
    @UIApplicationDelegateAdaptor(PageturnerAppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Log.install()
        // downloads iOS finished (or is still running) for books from Google Drive
        DriveDownloads.shared.reconnect()
        // taps on a suggestion notification come back through here
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // iOS wants a background task's handler registered before launch ends
        AutoBackup.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                // "Open in Pageturner" from Files, Mail, the share sheet…
                // and `pageturner://link?code=…`, BookMaster's pair flow coming home.
                .onOpenURL { url in
                    if let target = BMDeepLink.parse(url) {
                        // a `pageturner://open` address: the chat, or a page of one of the web apps
                        IntentRouter.shared.request = .openSuite(target)
                    } else if url.scheme == BookMasterLinker.scheme {
                        // The in-app sheet normally consumes this. A code that
                        // arrives here is only good if this app started a link —
                        // otherwise a web page could link the device to its own account.
                        guard BookMasterLinker.shared.pending,
                              let code = BookMasterLinker.code(from: url)
                        else { return }
                        Task { try? await BookMaster.shared.redeem(code: code) }
                    } else {
                        Task { await library.importFiles([url]) }
                    }
                }
                // a tapped Spotlight result
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let id = UUID(uuidString: raw)
                    {
                        IntentRouter.shared.request = .open(id)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    Log.event("lifecycle", "scene → \(String(describing: phase))")
                    switch phase {
                    case .active:
                        Log.markForeground()
                        BackgroundKeepAlive.shared.update(background: false)
                        library.refreshMissing()
                    case .background:
                        library.flushSaves()
                        Log.markBackground()
                        Task { await BookMaster.shared.beat(leaving: true) }
                        Notifier.shared.scheduleRefresh()
                        BackgroundKeepAlive.shared.update(background: true)
                        QuickActions.update(library)
                        AutoBackup.shared.scheduleBackground()
                    default: break
                    }
                }
                // The heartbeat has its own task so the slow work below never delays
                // it: BookMaster counts you as here for two minutes after a beat, and
                // a missed one gets a single retry so a dropped request never gaps the
                // window. Keyed on "not in the background", so a brief .inactive
                // (Control Center, an alert) does not cancel and restart anything.
                .task(id: scenePhase != .background) {
                    guard scenePhase != .background else { return }
                    await BookMaster.shared.beat()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(LowPower.on ? 120 : 90))
                        guard !Task.isCancelled else { return }
                        if await !BookMaster.shared.beat() {
                            try? await Task.sleep(for: .seconds(8))
                            guard !Task.isCancelled else { return }
                            await BookMaster.shared.beat()
                        }
                    }
                }
                // While the app is open, look for what is new now and then, so a banner says it at once. (Behind the
                // app, `BackgroundKeepAlive` does the looking, when the reader has asked for it.)
                .task(id: scenePhase == .active) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(BMKeepAlive.pollInterval(lowPower: LowPower.on)))
                        guard !Task.isCancelled else { return }
                        await Notifier.shared.refresh(notify: false)
                    }
                }
                // the one-off sync on coming to the front
                .task(id: scenePhase != .background) {
                    guard scenePhase != .background else { return }
                    DriveDownloads.shared.attach(library)
                    await BookMaster.shared.flush()
                    await FolderWatcher.shared.scan(library: library)
                    await DriveSync.shared.scanIfDue(library: library)
                    await BookMaster.shared.pullShelf(into: library)
                    await BookMaster.shared.pushCovers(from: library)
                    await Notifier.shared.refresh(notify: false)
                    SpotlightIndexer.shared.libraryChanged(library)
                    QuickActions.update(library)
                    // last: a backup of a big library takes a while, and nothing above waits on it
                    await AutoBackup.shared.runIfDue(library: library)
                }
        }
        // iOS's own background refresh (a scene modifier): look for new
        // suggestions and announce them
        .backgroundTask(.appRefresh(Notifier.refreshTaskID)) {
            await Notifier.shared.backgroundRefresh()
        }
    }
}
