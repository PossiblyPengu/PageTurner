import Foundation

/// Which strip is docked above the tab bar. There is one slot and two things that can fill it: the audiobook
/// in the player, and a book being read aloud whose reader is not on screen. Starting either pauses the other
/// (`AudioFocus`), so when both are loaded the strip follows whichever last took the stage — the one that
/// holds the lock-screen buttons — rather than the one that happens to be playing this instant.
enum NowPlayingBar: Equatable {
    case audiobook
    case narration

    /// `audiobook`: a player is loaded and its own full screen is not what is showing.
    /// `narration`: a book is being read aloud with its reader left. `holder`: `AudioFocus`'s id of the one
    /// that took the stage last.
    static func choose(audiobook: Bool, narration: Bool, holder: String?) -> NowPlayingBar? {
        switch (audiobook, narration) {
        case (false, false): return nil
        case (true, false): return .audiobook
        case (false, true): return .narration
        case (true, true): return holder == "readaloud" ? .narration : .audiobook
        }
    }

    /// The line under a book's title: the chapter, else the author, else nothing.
    static func subtitle(chapter: String?, author: String) -> String? {
        let chapter = chapter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chapter.isEmpty { return chapter }
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return author.isEmpty ? nil : author
    }
}
