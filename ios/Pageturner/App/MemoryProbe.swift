import Darwin
import UIKit

/// How much memory the app is using, written to the log now and then during read-aloud — so a crash after hours of
/// listening shows in Settings → Diagnostics whether memory was climbing (iOS ending the app for it) or not.
@MainActor
enum MemoryProbe {
    private static var lastLogged = Date.distantPast

    /// The app's footprint in MB, as iOS counts it against the app's limit.
    nonisolated static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// A line every few minutes at most.
    static func logIfDue(_ context: @autoclosure () -> String, every interval: TimeInterval = 300) {
        guard Date().timeIntervalSince(lastLogged) >= interval else { return }
        log(context())
    }

    static func log(_ context: String) {
        lastLogged = Date()
        guard let mb = footprintMB() else { return }
        let place = UIApplication.shared.applicationState == .background ? "background" : "front"
        Log.event("memory", "\(mb) MB in \(place) — \(context)")
    }
}
