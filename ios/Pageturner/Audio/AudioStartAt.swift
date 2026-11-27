import Foundation

/// A one-shot "start here" for an audiobook about to open: the place its ebook was left at (`Companion`), found in
/// the audiobook once its chapters are known (`AudioPlayer.open`, or `go(to:)` when it is open already).
enum AudioStartAt {
    private static var pending: [UUID: Companion.Place] = [:]
    static func request(_ place: Companion.Place, for book: UUID) { pending[book] = place }
    static func take(for book: UUID) -> Companion.Place? { pending.removeValue(forKey: book) }
    /// A place is waiting: the audiobook is being opened at it, so BookMaster's place is not offered over it.
    static func isPending(for book: UUID) -> Bool { pending[book] != nil }
}
