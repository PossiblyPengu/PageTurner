#!/bin/sh
# Copy the app's real BookMaster sources into the check's target, with the few
# changes Linux needs. Run again after changing anything under ios/Pageturner/BookMaster.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../Pageturner"
OUT="$HERE/Sources/bmcheck"
cp "$SRC/BookMaster/BookMasterModels.swift" "$OUT/BookMasterModels.swift"
cp "$SRC/BookMaster/BookMasterShelf.swift" "$OUT/BookMasterShelf.swift"
cp "$SRC/BookMaster/BookMasterLinkURL.swift" "$OUT/BookMasterLinkURL.swift"
cp "$SRC/BookMaster/GoodreadsCSV.swift" "$OUT/GoodreadsCSV.swift"
cp "$SRC/BookMaster/BMPace.swift" "$OUT/BMPace.swift"
cp "$SRC/BookMaster/BMSuite.swift" "$OUT/BMSuite.swift"
cp "$SRC/BookMaster/BMChat.swift" "$OUT/BMChat.swift"
cp "$SRC/BookMaster/BMChatButton.swift" "$OUT/BMChatButton.swift"
cp "$SRC/BookMaster/BMWebApps.swift" "$OUT/BMWebApps.swift"
cp "$SRC/BookMaster/BMNtfy.swift" "$OUT/BMNtfy.swift"
cp "$SRC/BookMaster/BMBark.swift" "$OUT/BMBark.swift"
cp "$SRC/BookMaster/BMDeepLink.swift" "$OUT/BMDeepLink.swift"
cp "$SRC/Import/TextBook.swift" "$OUT/TextBook.swift"
cp "$SRC/Import/ZipWriter.swift" "$OUT/ZipWriter.swift"
cp "$SRC/Library/BookText.swift" "$OUT/BookText.swift"
cp "$SRC/Library/BackupFiles.swift" "$OUT/BackupFiles.swift"
cp "$SRC/Library/ResumeOffer.swift" "$OUT/ResumeOffer.swift"
cp "$SRC/Audio/AudioChapter.swift" "$OUT/AudioChapter.swift"
cp "$SRC/Audio/AudioStartup.swift" "$OUT/AudioStartup.swift"
cp "$SRC/Audio/AudioRecovery.swift" "$OUT/AudioRecovery.swift"
cp "$SRC/Audio/PlaybackProgress.swift" "$OUT/PlaybackProgress.swift"
cp "$SRC/Audio/AudioFocus.swift" "$OUT/AudioFocus.swift"
cp "$SRC/Audio/SleepTiming.swift" "$OUT/SleepTiming.swift"
cp "$SRC/Reader/JumpHistory.swift" "$OUT/JumpHistory.swift"
cp "$SRC/Reader/SpeechVoices.swift" "$OUT/SpeechVoices.swift"
cp "$SRC/Reader/SpeechText.swift" "$OUT/SpeechText.swift"
cp "$SRC/Reader/ReadingSpan.swift" "$OUT/ReadingSpan.swift"
cp "$SRC/Reader/SpokenWords.swift" "$OUT/SpokenWords.swift"
cp "$SRC/Reader/ReadingPace.swift" "$OUT/ReadingPace.swift"
cp "$SRC/Reader/PageCurl.swift" "$OUT/PageCurl.swift"
cp "$SRC/Neural/PlayheadClock.swift" "$OUT/PlayheadClock.swift"
cp "$SRC/Reader/ReadAloudHighlights.swift" "$OUT/ReadAloudHighlights.swift"
cp "$SRC/Neural/NeuralVoiceCatalog.swift" "$OUT/NeuralVoiceCatalog.swift"
cp "$SRC/Neural/NeuralVoiceFormat.swift" "$OUT/NeuralVoiceFormat.swift"
cp "$SRC/Library/HighlightExport.swift" "$OUT/HighlightExport.swift"
cp "$SRC/Library/ReadingStats.swift" "$OUT/ReadingStats.swift"
cp "$SRC/Notifications/NotificationPlan.swift" "$OUT/NotificationPlan.swift"
cp "$SRC/Settings/AppPrefs.swift" "$OUT/AppPrefs.swift"
cp "$SRC/Library/AudioGrouping.swift" "$OUT/AudioGrouping.swift"
cp "$SRC/Library/OPDSFeed.swift" "$OUT/OPDSFeed.swift"
cp "$SRC/Library/AutoBackupPlan.swift" "$OUT/AutoBackupPlan.swift"
cp "$SRC/Audio/VoiceDSP.swift" "$OUT/VoiceDSP.swift"
python3 - "$SRC" "$OUT" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(f"{src}/BookMaster/BookMasterClient.swift").read()
# Linux keeps URLSession in FoundationNetworking; the bridge address comes from the environment
s = s.replace("import Foundation\nimport Observation", "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\nimport Observation", 1)
s = s.replace('static let bridge = URL(string: "https://pageturner.pages.dev/api/bookmaster")!',
              'static let bridge = URL(string: ProcessInfo.processInfo.environment["BM_BRIDGE"] ?? "https://pageturner.pages.dev/api/bookmaster")!', 1)
open(f"{out}/BookMasterClient.swift", "w").write(s)
# the real Book / Bookmark / Highlight types, without the app-only imports
t = open(f"{src}/Library/LibraryStore.swift").read()
body = "\n".join(l for l in t[:t.index("/// The library: book files")].split("\n") if not l.startswith("import "))
open(f"{out}/BookModel.swift", "w").write("import Foundation\n" + body)
PY
cat > "$OUT/LibraryStub.swift" <<'SW'
import Foundation
/// Just enough of LibraryStore for the shelf pull: the same applyShelf semantics.
@MainActor final class LibraryStore {
    var books: [Book] = []
    func applyShelf(_ changes: [(UUID, (inout Book) -> Void)]) {
        for (id, change) in changes {
            guard let i = books.firstIndex(where: { $0.id == id }) else { continue }
            var b = books[i]; change(&b); if b != books[i] { books[i] = b }
        }
    }
    /// Where a downloaded jacket would live — a path is all the pull checks.
    func coverURL(for book: Book) -> URL { URL(fileURLWithPath: "/tmp/\(book.id.uuidString).jpg") }
}
/// The real one writes files and needs UIKit; the pull's cover fetch is
/// network IO the checks never run.
enum MetadataLookup {
    static func applyCover(from url: URL, to book: Book, library: LibraryStore) async {}
}
/// The real logger writes Documents/Logs and needs a real home dir; checks
/// only need its calls to compile.
enum Log {
    static func event(_ category: String, _ message: String) {}
    static func error(_ category: String, _ message: String) {}
}
SW
echo "assembled into $OUT"
