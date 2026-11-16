import Foundation

/// Whose dot it is, before it is read. Everything waiting in Quest Log is blue and square — its own
/// accent, and a shape a colour-blind reader can tell too; everything else is round and in the app's
/// accent. BookMaster, Kindred and Quest Log keep the same rule (`suiteTone` there).
enum BMDotTone: Equatable {
    case regular, questLog
}

enum BMSuite {
    /// The look of a dot about this app (a notice's `app`).
    static func dotTone(forApp app: String) -> BMDotTone { app == "quest-log" ? .questLog : .regular }

    /// A count of notices wears Quest Log's look only when nothing else is waiting.
    static func dotTone(forNotices notices: [BMNotice]) -> BMDotTone {
        !notices.isEmpty && notices.allSatisfy { dotTone(forApp: $0.app) == .questLog } ? .questLog : .regular
    }
}
