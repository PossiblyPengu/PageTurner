import Foundation

/// What the suite's feed says about the chat, apart from any screen: whether a message waits in the shared
/// room. The chats themselves are BookMaster's page (the shared room,
/// with Quest Log's own beside it), shown in `BMWebChatScreen`. Pure, so it is checked off-device.
enum BMChat {
    /// The feed carries one notice with this prefix while anything is unread.
    static let noticePrefix = "bookmaster:chat:"

    /// The notice that says a message is waiting, if one is.
    static func unreadNotice(_ notices: [BMNotice]) -> BMNotice? {
        notices.first { $0.id.hasPrefix(noticePrefix) }
    }

    /// The same, unless it is the one already opened: a newer message carries a new notice id, so its
    /// dot comes back on its own.
    static func unread(_ notices: [BMNotice], seen: String?) -> BMNotice? {
        guard let notice = unreadNotice(notices), notice.id != seen else { return nil }
        return notice
    }
}
