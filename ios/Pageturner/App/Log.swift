import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// The app's diary. Every line goes to os_log (Console/sysdiagnose on a Mac)
/// and to a rolling file in `Documents/Logs` — visible in the Files app, and
/// shareable from Settings → Diagnostics. A signal and exception trap writes
/// the fault and a backtrace to `crash.log`, then re-raises so iOS still keeps
/// its own .ips report.
///
/// A `.running` marker names clean exits: it exists whenever the app is in
/// front and is removed on `.background`. Present at launch means the last
/// run never reached the background — a crash or a force-close in front.
enum Log {
    /// True when the previous run ended in front — crash or force-close.
    private(set) static var lastRunEndedUncleanly = false

    /// Where the files live. `Documents/` is Files-visible (UIFileSharingEnabled).
    static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }
    static var currentURL: URL { dir.appendingPathComponent("pageturner.log") }
    static var previousURL: URL { dir.appendingPathComponent("pageturner.prev.log") }
    static var crashURL: URL { dir.appendingPathComponent("crash.log") }
    private static var markerURL: URL { dir.appendingPathComponent(".running") }

    private static let queue = DispatchQueue(label: "pageturner.log")
    private static let fm = FileManager.default
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// The last line written and when — a repeated failure (offline page turns)
    /// earns one log line, not one per retry. The timestamp is left out: the
    /// same failure a second later still counts as the same event.
    private static var lastBody = ""
    private static var lastLineAt = Date.distantPast

    private static var maxBytes: UInt64 { 256 * 1024 }
    private static var crashMaxBytes: UInt64 { 128 * 1024 }

    /// Call once at launch. Reads last run's fate, sets the running marker,
    /// and arms the crash trap. Safe to call again.
    static func install() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        lastRunEndedUncleanly = fm.fileExists(atPath: markerURL.path)
        // the marker is made when a scene comes to the front (markForeground): a
        // background launch for app refresh has no scene and never reaches .background
        if lastRunEndedUncleanly {
            event("lifecycle", "previous run ended without a background transition — crash or force-close")
        }
        trapFaults()
        event("lifecycle", "launched \(version)")
    }

    /// The app is in front: a crash from here counts.
    static func markForeground() {
        queue.async { _ = fm.createFile(atPath: markerURL.path, contents: Data()) }
    }

    /// The app left the screen: whatever happens next is a clean end.
    static func markBackground() {
        queue.sync { try? fm.removeItem(at: markerURL) }
    }

    /// A normal log line.
    static func event(_ category: String, _ message: String) {
        append(message, category: category, crashFile: false)
    }

    /// A failure line — same file, flagged.
    static func error(_ category: String, _ message: String) {
        append("ERROR \(message)", category: category, crashFile: false)
    }

    /// The last `lines` lines of the current log, newest last.
    static func tail(lines: Int = 300) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: currentURL),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(lines).joined(separator: "\n")
        }
    }

    /// One file with everything worth sending: this run's log, the previous
    /// one, and any crash record. Written to the temp dir for the share sheet.
    static func shareURL() -> URL {
        let out = fm.temporaryDirectory.appendingPathComponent("pageturner-diagnostics.txt")
        var report = "Pageturner diagnostics — \(formatter.string(from: Date()))\n"
        report += "version \(version)\n"
        report += lastRunEndedUncleanly
            ? "previous run: ended uncleanly (crash or force-close)\n"
            : "previous run: clean\n"
        for (label, url) in [("crash.log", crashURL), ("pageturner.log", currentURL), ("pageturner.prev.log", previousURL)] {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else { continue }
            report += "\n===== \(label) =====\n\(text)\n"
        }
        try? report.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func append(_ message: String, category: String, crashFile: Bool) {
        let body = "\(category)  \(message)"
        let line = "\(formatter.string(from: Date()))  \(body)\n"
        // dedupe a hammered failure: the same line inside five seconds is one event
        queue.sync {
            if !crashFile, body == lastBody, Date().timeIntervalSince(lastLineAt) < 5 { return }
            lastBody = body; lastLineAt = Date()
            let url = crashFile ? crashURL : currentURL
            if !crashFile, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ UInt64($0) >= maxBytes }) == true {
                try? fm.removeItem(at: previousURL)
                try? fm.moveItem(at: url, to: previousURL)
            }
            if crashFile, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ UInt64($0) >= crashMaxBytes }) == true {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        #if canImport(OSLog)
        if !crashFile { Logger(subsystem: "io.github.possiblypengu.pageturner", category: category).info("\(message)") }
        #endif
    }

    // MARK: - The crash trap

    /// Signal and ObjC-exception handlers. Each writes what it knows into
    /// crash.log — signal name, fault, backtrace — then restores the default
    /// and re-raises so the system crash report is still written.
    private static func trapFaults() {
        NSSetUncaughtExceptionHandler { exception in
            Log.appendFault(
                "exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                    + exception.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { sig in
                Log.appendFault("signal \(sig)\n" + Thread.callStackSymbols.joined(separator: "\n"))
                signal(sig, SIG_DFL)
                _ = raise(sig)
            }
        }
    }

    /// The fault path writes straight to the file — no queue, no locks: if the
    /// crash happened mid-append, waiting on the queue would deadlock and iOS
    /// would never get to write its own report.
    private static func appendFault(_ message: String) {
        let line = "\(formatter.string(from: Date()))  crash  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: crashURL) {
            defer { try? handle.close() }
            _ = handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: crashURL)
        }
    }
}
