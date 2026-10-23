import Foundation

/// The switches the settings form offers, read where they act rather than where
/// they are shown. Every key has its default here, so a fresh install and an
/// upgrade behave the same until the switch is touched. Foundation only, so the
/// Linux checks can exercise them.
enum AppPrefs {
    private static var defaults: UserDefaults { .standard }

    /// App-wide appearance: "system", "light" or "dark".
    static var appearance: String { defaults.string(forKey: "app-appearance") ?? "system" }

    /// The audiobook skip buttons and the lock screen's, in seconds.
    static var skipBack: Double { positive("audio-skip-back", fallback: 15) }
    static var skipForward: Double { positive("audio-skip-fwd", fallback: 30) }

    /// Whether presence beats name the screen ("bookmaster", "reader"…). Off
    /// still says online, just not where.
    static var sharePlace: Bool { enabled("bm-share-place") }

    /// Whether opening a book may ask to jump to BookMaster's place. Off never
    /// asks and never jumps — this device keeps its own place.
    static var resumeAsk: Bool { enabled("bm-resume-ask") }

    /// Whether BookMaster gets this device's cover art with the books.
    static var sendCovers: Bool { enabled("bm-covers") }

    /// The waiting-suggestions count on the BookMaster tab.
    static var showBadge: Bool { enabled("bm-badge") }

    /// Whether this phone keeps its own reading time (the Stats page, "time
    /// left" estimates). BookMaster's own numbers are unaffected.
    static var statsTracking: Bool { enabled("stats-tracking") }

    /// Minutes of reading or listening a day the Reading tab's ring counts towards.
    static var dailyGoalMinutes: Int {
        get { defaults.object(forKey: "daily-goal-min") as? Int ?? 20 }
        set { defaults.set(newValue, forKey: "daily-goal-min") }
    }

    /// Whether a notification that arrives while Pageturner is open is told as a banner (default on).
    static var bannersOn: Bool { enabled("bm-banners") }

    /// Whether Pageturner keeps itself awake in the background, so it can tell the reader at once
    /// (`BackgroundKeepAlive`). Off unless the reader asks: it costs battery.
    static var stayConnected: Bool {
        get { defaults.bool(forKey: "bm-stay-connected") }
        set { defaults.set(newValue, forKey: "bm-stay-connected") }
    }

    /// When the library was last backed up (seconds since 1970), 0 for never.
    static var lastBackupAt: Double {
        get { defaults.double(forKey: "backup-last") }
        set { defaults.set(newValue, forKey: "backup-last") }
    }

    /// Until when the "back up your library" reminder is quiet.
    static var backupSnoozeUntil: Double {
        get { defaults.double(forKey: "backup-snooze") }
        set { defaults.set(newValue, forKey: "backup-snooze") }
    }

    /// Whether to remind about a backup: a library of some size that has never been saved, or has grown
    /// since — at most once a week once dismissed.
    static func backupDue(books: [Date], now: Date = Date()) -> Bool {
        guard books.count >= 3, now.timeIntervalSince1970 >= backupSnoozeUntil else { return false }
        let last = lastBackupAt
        if last == 0 { return true }
        let added = books.filter { $0.timeIntervalSince1970 > last }.count
        return added >= 3 || (added >= 1 && now.timeIntervalSince1970 - last > 30 * 86_400)
    }

    /// Audiobook sound: even out loud and quiet speech, and speed through gaps.
    static var audioVoiceBoost: Bool { defaults.object(forKey: "audio-voice-boost") as? Bool ?? false }
    static var audioTrimSilence: Bool { defaults.object(forKey: "audio-trim-silence") as? Bool ?? false }

    /// Whether a new highlight is also sent to BookMaster as a quote. Off until asked for: quotes are shared.
    static var quotesAutoSend: Bool { defaults.object(forKey: "bm-quotes-auto") as? Bool ?? false }

    /// Whether read-aloud passes over a line that is only a page number.
    static var speechSkipsPageNumbers: Bool { enabled("speech-skip-page-numbers") }

    /// Whether finishing a book frees its files without asking: a Drive copy goes back to
    /// the Drive, any other finished book leaves the library. Off until asked for.
    static var autoClearFinished: Bool { defaults.object(forKey: "auto-clear-finished") as? Bool ?? false }

    private static func enabled(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    private static func positive(_ key: String, fallback: Double) -> Double {
        let v = defaults.double(forKey: key)
        return v > 0 ? v : fallback
    }
}
