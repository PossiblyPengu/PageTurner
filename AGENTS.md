# AGENTS.md

## iOS app (`ios/`)

`ios/` contains **Pageturner**, a native SwiftUI reader and audiobook player built on the
Readium Swift toolkit (pinned to 3.11.0), linked to BookMaster. It replaces the PWA in `docs/`
(which stays deployed until the IPA has been tried on a device). See `README.md` for the feature
list and `ios/DESIGN.md` for the Liquid Glass design rules.

### Building and checking

- There is no Mac on this machine — builds run on GitHub Actions macOS runners.
  `.github/workflows/ios.yml` installs XcodeGen, generates the project from `ios/project.yml`,
  builds Release unsigned (`CODE_SIGNING_ALLOWED=NO`) and uploads `Pageturner.ipa` (artifact
  `Pageturner-ipa`). Install it with AltStore/SideStore/Sideloadly. The Xcode project is generated,
  not committed: `cd ios && xcodegen`.
- **Releasing:** Actions → *iOS release* → *Run workflow* on `main` (`.github/workflows/ios-release.yml`). Leave the
  version blank to release the one in `package.json`, or give a new one (`2.14.0`): the workflow runs
  `node scripts/version.js 2.14.0`, commits "Release 2.14.0" to `main`, asks for CI on that commit (a push made with the
  workflow's own token starts nothing, and the site deploys when CI is green), builds it, makes the `v2.14.0` tag on the
  built commit, publishes the GitHub "Latest" release with the commit subjects since the last release as notes, and
  updates `ios-stable`. Pushing a `v*` tag by hand still works (it must equal `package.json`'s version). From this
  machine the git proxy refuses tag pushes, so the workflow is the way: it can be started by API as well.
- Push, then read the run's result before pushing again — the workflow cancels an in-progress run
  on the same branch, so back-to-back pushes never report. Compiler errors are in the job log
  (`grep "error: "`); the job summary also lists diagnostics.
- `.github/workflows/ios-sim.yml` (two parallel halves, `screens` and `voices`, artifacts `simulator-screens-<half>`) is the nearest thing to looking at the app: a **Debug** build in the
  iOS Simulator, launched once per screen (`ios/scripts/simulator-shots.sh`) and photographed; the
  `simulator-screens` artifact holds PNGs, the app's log and any crash report. The launch arguments
  (`-PTDebugScreen`, `-PTDebugSeed`, `-PTDebugReaderSheet` (incl. `readaloud` with `-PTDebugHighlights sentence,line,word` and `-PTDebugVoice neural`), `-PTDebugReaderScroll` (scroll-mode layout for `reader`), `-PTDebugSettingsPush`, `-PTDebugVoiceSource`,
  `-PTDebugNeuralProbe <voice key>`, `-PTDebugSpeechProbe`) are read by `Debug/DebugScenario.swift`,
  which is `#if DEBUG` only — none of it is in the IPA. Download with
  `gh api repos/<owner>/<repo>/actions/artifacts/<id>/zip`.
- `ios/Checks/bookmaster/` compiles the app's **real** pure-logic sources (BookMaster client and
  models, the `Book` model, text→EPUB converter, chapters, audiobook grouping, resume offer, notification plan, jump
  history, highlight export, reading stats, voice lists, neural voice conversion, word timings, the playhead clock and the page-curl geometry) on Linux with a Swift 6 toolchain and runs them: against a
  live local BookMaster (`run.sh`, needs a BookMaster checkout, `wrangler`, `python3`) or alone
  (`run.sh data`, ~430 checks, no servers). Anything that can be written without UIKit/Readium should
  be, so it can be checked there; `assemble.sh` lists the files it copies. `run.sh` stops if the target fails to
  build (it used to run the previous binary and report green).
- When touching Readium calls, verify signatures against the toolkit source — the 3.x API changed a lot
  between releases. The `Archive Readium sources` CI step uploads the resolved checkout as the
  `readium-src` artifact.
- Deployment target is iOS 17. Stores that predate it (`LibraryStore`, `ReaderModel`, `AudioPlayer`,
  `ReadingLog`) are `ObservableObject`; newer code (`BookMaster`, `FolderWatcher`, `Notifier`,
  `AppRouter`, `PlaybackCoordinator`, `IntentRouter`) uses `@Observable`.

### Gotchas that have cost a build

- A long chain of view modifiers (sheets, alerts, onChange…) can exceed the type checker
  ("unable to type-check this expression in reasonable time"). Split it into helper functions that each
  take and return `some View` — see `RootView` (`screens`/`bookSheets`/`alerts`/`routing`) and `ReaderView`.
- `[String].union` doesn't exist: build a `Set([...])` first.
- `AnyURL ==` is deprecated: use `isEquivalentTo`. `ReadiumShared.PDFDocument` is a protocol that clashes
  with PDFKit's class — write `PDFKit.PDFDocument`. `Link` and `Color` clash with SwiftUI's: write
  `ReadiumShared.Link`; keep Readium's `Color` in files that don't import SwiftUI.
- `tabViewBottomAccessory(isEnabled:)` is iOS 26.1; the plain `tabViewBottomAccessory` is 26.0.
- `.backgroundTask` is a *Scene* modifier, not a View one.
- Locking the screen is `.inactive`, not necessarily `.background` — with the keep-awake idle timer or
  live read-aloud the app can be suspended without `.background` ever firing. Anything that must reach
  disk on lock (the reader's position) is saved on `.inactive` too (`ReaderView`); session-end bookkeeping
  still waits for `.background`.
- Logging: `App/Log.swift` writes a rolling `pageturner.log`/`pageturner.prev.log` plus `crash.log`
  (signal/exception trap with a backtrace, then re-raise so the .ips still exists) into
  `Documents/Logs` — visible in the Files app — and mirrors to `os.Logger`. A `.running` marker tells
  the next launch whether the previous run ended cleanly; Settings → Diagnostics shows the flag and
  shares a combined report (`Log.shareURL()`). The same deduped queue backs `Log.event`/`Log.error`;
  `ios/Checks` stubs it.
- Catalogue dates are seconds since 1970 on disk but `JSONDecoder`'s default reads 2001-based, which
  moved dates forward 31 years per save. Anything with a `Date` inside `Book` decodes it through
  `StoredDate.read` (see the `Book`, `Bookmark` and `Highlight` decoders).
- Foundation `Process` can hang on Linux; `pkill -f <pattern>` can match its own command line.
- A `Set` literal with a repeated element traps at launch ("Duplicate elements of type … were found in a Set").
- ReadAloud observes `AVAudioSession.interruptionNotification` itself: the TTS engine reports a cancelled
  utterance as finished (`SystemTTSEngine` resumes `speak` on `didCancel`, just as Readium's `AVTTSEngine`
  did), so without it a phone call walks the synthesizer through sentences silently and the failure counter
  drops the chosen voice.
- Word ranges from a TTS engine index the text it was given; if that differs from `locator.text.highlight`,
  the spoken-word locator is garbage and the page follows it to the wrong place (fuzzy text anchoring finds
  *something*).
- Fuzz pure helpers with random Unicode and odd numbers before trusting them (a speech-range finder crashed on a
  sample rate of 0): 200k random strings through `SpokenWords.tokens/schedule` take seconds on Linux.
- Decoration templates (HTML + CSS for Readium highlights) can be tried without a device: Readium's compiled
  `readium-reflowable.js` (Sources/Navigator/EPUB/Assets/Static/scripts in the toolkit) runs in headless Chromium
  with a stub `window.webkit.messageHandlers`; call `readium.registerDecorationTemplates({...})` and
  `readium.getDecorations(group).add({id, locator, style, element})` the way `DecorationChange` does, then
  `chrome --headless --screenshot` (or `--dump-dom` to read results back). That is how the word locators and the
  line band were checked. **Load Readium CSS too** (`Assets/Static/readium-css/ReadiumCSS-{before,default,after}.css`,
  with `--USER__backgroundColor` / `--USER__textColor` set on `<html>`'s `style`, as the navigator does): its
  `:root[style*="--USER__backgroundColor"] * { background-color: transparent !important }` blanks any decoration
  whose background comes from a stylesheet, which a bare page does not show. Only a declaration in the element's own
  `style` (with `!important`) survives — the line band's whole look is inline for that reason.

### UI structure (Liquid Glass; see `ios/DESIGN.md`)

- `Design/Glass.swift` is the only place that touches `glassEffect` / `GlassEffectContainer` and the
  `.glass` button styles — call its `ptGlass`, `PTGlassGroup`, `ptButtonStyle` helpers, never
  `#available(iOS 26, *)` at a call site. Glass is for controls floating over content, not content.
- `App/RootView.swift` is the tab shell (iOS 26.1+: glass `TabView` with `tabViewBottomAccessory`;
  older: plain tabs with the mini player as an inset). `App/AppRouter.swift` decides what presents over
  the tabs (reader, book sheets, settings, the "continue from BookMaster?" prompt).
- Audiobooks play through `Audio/PlaybackCoordinator.swift`; `NowPlayingView` and `MiniPlayer` observe
  it. Chapters (`Audio/AudioChapter.swift`) are an m4b's embedded markers or one per file.
  The sleep timers are one bell rung once at the deadline (`Audio/SleepTiming.swift` is the pure
  arithmetic, Linux-checked): whatever can move it — a seek, the rate, a resume — re-arms it, and
  chapter-end fires exactly on the boundary (a paused player keeps the bell set for `play()` to
  re-aim). A player paused ten minutes gives the audio session back, but only when
  `AudioFocus.soleOwner` says the session is really its own.
- Read-aloud outlives the reader (`Reader/ReadAloudHost.swift`, `Audio/NarrationMiniPlayer.swift`, `Audio/NowPlayingBar.swift`): leaving the
  reader (a tab switch, the Back button) used to stop the voice. Now `ReaderView.onDisappear` hands the `ReaderModel` to `ReadAloudHost`
  while narration is under way (`leave`), so the navigator, the publication and the voice stay alive, and the now-playing strip — the same
  bottom-accessory slot as `MiniPlayer`, with the book, chapter, previous/play/next sentence, and Stop + sleep timer on a long press — is
  shown for `host.held`. Tapping it (`AppRouter.openNarration`) opens the book again and the same reader is taken back (`take(for:)`). While
  the reader is away `ReadAloud.onScreen` is false: nothing is followed, painted or measured per word; each new sentence is reported
  (`onNarrated` → `ReaderModel.narrated(to:)`) so the saved place, the BookMaster progress and the sitting move with the voice, the navigator's
  own (stale) location is ignored and never saved (`narrationAhead`), and when the reader is back (`show`) the page catches up to the
  sentence being said. One voice: showing a reader for another book stops what is held; deleting a book stops its narration. Which strip
  shows when an audiobook is loaded too is `NowPlayingBar.choose` (pure, Linux-checked): whichever last took the stage, i.e.
  `AudioFocus.holder` (now `@Observable`; it mirrors `RemoteControls.activeOwner`). The simulator run (`-PTDebugReaderSheet readaloudaway`)
  starts the voice, leaves the reader and fails if no `PTNarrated` line follows; `68-readaloud-strip` is the photograph.
- Battery: presence beats run every 90s in front (120s under Low Power Mode) with one retry on a
  miss — BookMaster holds presence for two minutes. `App/LowPower.swift` names the mode: it slows
  the neural voice's playhead ticker, throttles the curl's animated finishes to 15fps, and drops the
  marks that move per spoken word (the sentence mark stays). Grid covers come from
  `LibraryStore.coverThumbnail(for:maxPixels:)` — ImageIO-decoded at cell size and NSCache'd —
  never `cover(for:)` in a list.
- The reader (`Reader/`): `ReaderModel` owns the Readium navigator; `JumpHistory` drives the Back chip;
  page turns are `PageTurnStyle`: Readium's slide, a hinge `flip`, a `fade`, and `curl` — a finger-tracked
  peel. `PageCurl` is the pure geometry (fold line, cylinder roll, warped mesh — Linux-checked);
  `PageCurlOverlay` warps a photographed page with `SKWarpGeometryGrid` over the live navigator, which
  is silently moved underneath so the reveal is real content. The leaf is **two sprites** (`PageCurl.layers`): one warped
  sheet folds back over itself, and the GPU draws overlapping cells in grid order, so the back and the front showed
  through each other in stripes on a diagonal pull — split at the roll's crest each layer runs one way only, and the
  back (washed with the page's colour) is drawn whole over the front. `SKWarpGeometryGrid` positions are
  **normalized (0…1), row-major from the bottom-left** — the page math is point space, rows top-first,
  so the overlay flips both. While a curl runs, `ReaderModel.curling` holds position saves, jump
  history and BookMaster sync; a commit replays the landed location, a cancel restores `curlBefore`. The leaf is always the page being
  left, peeled from the edge the finger caught (a backward turn too: the page peels away to the right over the one before it), and the
  page beneath is the navigator moved silently to where the turn lands. A web view says it has moved before it has painted: the leaf
  stays flat until a small photograph of the navigator (`fingerprint`) differs from the cover's (`waitForNewPage`) — lifted earlier it
  peeled off a copy of itself — a flick that ends first waits for that (`armTask`), and a cancel keeps the cover until the original page is
  painted again. `-PTDebugTurn curl [-PTDebugTurnBack YES]` poses a tap-turn; the log's `PTCurlReveal` lines say how long the paint took.
  highlights live on the `Book` (colour, note, chapter, progression) and are painted as decorations;
  `HighlightExport` writes them as Markdown. PDFs are searched by Readium itself (its PDF parser
  registers a content search service).

### BookMaster link (`ios/Pageturner/BookMaster/`)

- `BookMasterClient` mirrors `docs/js/bookmaster.js`: pushes to
  `https://pageturner.pages.dev/api/bookmaster/<route>`; the Pages Function holds `PAGETURNER_SECRET`.
  Route names must be in that function's `ROUTES` set. Since BookMaster migration 0024,
  redeem also mints a per-device key (`BMUser.deviceKey`, sent as `x-pt-key` on every call);
  once `PAGETURNER_REQUIRE_KEY = "1"` lands on BookMaster a missing or stale key answers
  `404 "Unknown reader"` — the dead-link path already walks the reader through relinking.
- Payloads follow BookMaster's `functions/_lib/routes/pageturner.ts`: ids are strings, `at` on a session
  is milliseconds (a number), percents are 0–100. BookMaster is never a lookup *source*: catalogue and
  metadata search go to Open Library + Apple Books through `Library/CatalogueSearch.swift` (a port of
  BookMaster's `src/lib/search.ts` over `BookMatching`/`BookRanking`, pure and Linux-checked) plus Google
  Books in `MetadataLookup`, and a hit that is already shelved is pinned by matching it against
  `BookMaster.shelfRows` (`BMShelf.match`) — the same ladder the bridge ran, but on the local copy.
  `shelve` is still the only write for a found book.
- Offline: progress is coalesced by book identity (BookMaster / Open Library / ISBN, then title and author).
  Sessions and quotes always queue, oldest first, a 4xx is dropped. Presence beats are never queued.
  Only a push reply or a shelf pull may change a book's `bm*`
  fields (`LibraryStore.updateBookMaster` / `applyShelf`); `update()` always keeps the stored ones.
- Linking: `BookMasterLinkSheet` (a `WKWebView`, non-persistent data store) opens
  bookmaster.pages.dev/link/pageturner?from=https://pageturner.pages.dev; BookMaster signs the user in and
  sends the browser to `pageturner.pages.dev/?bm-link=<code>`, which the sheet's navigation delegate cancels,
  reading the code off the URL (`BMLinkURL.code(fromReturn:)` — only that host, https, a plausible code).
  Nothing of the web site is involved, so it works whether or not the PWA is deployed. (`pageturner://link?code=`
  and `docs/js/native-link.js` are the older route and still work; the app handles both.) Why not
  `ASWebAuthenticationSession`: its callback came from a page that was never deployed, so linking never completed.
- BookMaster lives in three tabs, not one: **Books** (`BookMasterBooksView` — shelf grid, filters,
  sort, bulk ops, up-next reorder via `setUpNext`, TBR pick, pushed destinations incl. `BMSeriesView`),
  **Together** (`BookMasterTogetherView`) and **Stats** (`BookMasterStatsView` — overview+stats,
  goals via `BMGoalSheet`, heatmap, achievements, profile/export/`BMImportSheet`). Each carries its own
  `NavigationStack` and reports `place = "bookmaster"` while on screen. Shared chrome is `BMShared.swift`
  (`bmCard`, `BMLinkPrompt`, `BMCover`, `BMMetric`, `BMFormat`). Detail additions: `BMPace` (the web's
  PaceWidget math, pure), `BMLogSheet` + `BMReadingTimer` (manual logging, persisted stopwatch),
  `BMEditSheet` (catalogue edit), `BMScanView` (barcode → `CatalogueSearch`). `GoodreadsCSV` parses an
  export on-device (scalars not Characters — a CRLF is one grapheme but two terminators); only the rows
  travel to `/pageturner/import`. New bridge writes go through `sendJSON` (username merged server-side).
- Chat (`BMChat.swift` is pure and Linux-checked; `BMChatView.swift` is the screen): the suite's one shared room, in BookMaster's
  database, through the `chat` (GET reads, POST sends), `chat-read` and `chat-remove` bridge routes — a message sent here is tagged
  `pageturner` by the server, whatever the body says. Reached from the floating chat button (below) and a card on the Together tab — no button in any header; the unread dot is the
  feed's `bookmaster:chat:<id>` notice (`BMChat.unreadNotice`), gone once the room is opened. It polls every 5s while on screen and reports
  how far you have read. Rules learned in review: a poll that began before a send or take-back finished carries the room as it was and is
  dropped (`edits`); one refresh at a time; reading is reported only while the screen is in front (`visible`); the length limit counts UTF-16
  units like the server; a full page that reaches back to nothing held replaces it instead of leaving a hole. Quest Log's own private chat is end-to-end encrypted, and is the chat screen's second tab
  ("🔒 Quest Log", `BMChatTab`) — a native screen like the shared room's (`BMQuestLogRoomView`), not a framed web page. The cipher is the one in
  Quest Log's chat.js / utils.js and BookMaster's secretChat.ts, line for line: PBKDF2-SHA256 (100,000 rounds) over the passphrase makes two
  keys — the chat key (salt `quest-log-chat-salt-v1`) → AES-GCM-256, a fresh 12-byte IV, ciphertext+tag in base64, and the **sign-in token**
  (salt `quest-log-auth-v1`, 32 bytes as hex) that is the bearer and all Quest Log / BookMaster's forward is ever shown (`BMQuestLogCrypto`,
  CryptoKit + CommonCrypto), so a message written in any of the three opens in the others and the server's `APP_AUTH_TOKEN` accepts the
  token — never change it in one place only (Quest Log's tests/auth-token.test.mjs holds the same known answers as `selfTest`). `BMQuestLog` is the pure part (Linux-checked): the stored entry, opening and
  unwrapping (`{"text":…}`), ids Quest Log accepts, the layout (it reuses `BMChat.rows`). `BMQuestLogChat` is the connection: it talks to
  `/quest-log/api/chat` on BookMaster's address with the sign-in token as the bearer (what Quest Log's own pages send), opens and seals on this
  iPhone, polls every 5 s while the room is in front, and keeps what it sent in view until the list shows it. **Pageturner holds the two
  keys, never the passphrase**: it is used once to make them and neither sent nor stored; the keys live in memory, and in the Keychain (this
  device only, when unlocked) as JSON unless "Keep it unlocked on this iPhone" is turned off on the lock screen (an earlier build's stored
  passphrase is read once and replaced). Locking the room, unlinking BookMaster (`RootView` → `reset()`) or signing out of the web apps
  erases them. A 429 is "too many wrong passphrases" (10 in 15 minutes per caller). Nothing it opens
  goes to BookMaster, the inbox, a notification or the log (Quest Log's notices only ever say that something is new). The part (giver or
  adventurer) is BookMaster's `questLogRole` on the chat answer, else the reader's choice, kept per account. A wrong passphrase is a 401 (and a
  remembered one that stops working locks the room with a note); a 403 is "that role belongs to another device". The cipher is verified by the
  simulator run (`-PTDebugScreen qlvector` opens two messages made by Node with the web's recipe; the app dying fails the run), and the room
  is photographed (`09i-questlog-chat`). Its blue-square dot (`Notifier.questLogUnread`) clears when the room is opened.
  The chat is also one tap from anywhere but the reader: `BMChatButtonLayer` (`BMChatButtonView.swift`) is a draggable round button laid
  over the whole shell in `RootView`, opening the chat as a full-screen page (`router.showChat`, `.fullScreenCover`) — a sheet read as a pop-up. When it shows and where it rests are pure
  (`BMChatButton`, Linux-checked); it steps aside over the reader (`router.readerOpen`) and over any screen marked `.hidesChatButton()`
  (the chat, the in-app browser); Settings → Chat & web apps turns it off. Its dot and the Together tab's share one state
  (`Notifier.chatUnread` / `noteChatOpened`), refreshed by the app's 30 s look. Gestures and accessibility go on the small
  face *before* `.position`, or they stand over the whole screen.
- Settings (`Settings/SettingsView.swift`) is a short list of topics, each its own page (`SettingsDestination`), not one long form: the
  BookMaster suite (BookMaster account & what is sent, Notifications — banners, the list, notifying when closed, staying connected — and Chat &
  web apps; unlinked, only the BookMaster row shows), Reading & listening (Reading, Read Aloud, Audiobooks, Appearance), Your library
  (Library & import, Backup) and Support (Diagnostics, version). A new setting goes on the page for its topic; a new topic is a case in
  the enum, a row in the list and a view in `SettingsPages.swift` (or beside the feature). The simulator run screenshots the pages
  (`-PTDebugSettingsPush <page>`). The Together tab reads top to bottom as: what is waiting (suggestions, notices), the ways into the
  suite (chat, the other apps), then the two of you.
- Whose dot it is: a notice or count about Quest Log is blue and square, every other round in the accent — `BMDotTone` / `BMSuite.dotTone`
  (pure, Linux-checked) and `BMDot` (the view), used for the notices card, the apps card's tiles and the floating chat button's dot.
  BookMaster, Kindred and Quest Log draw the same rule; change all four together.
- Deploys are not automatic for BookMaster/Kindred/Quest Log: a push to main runs CI only, and the code reaches production with
  `npm run deploy` in that repo (migrations first, `npm run db:migrate:remote`). Pageturner's own Pages deploy (the bridge function) runs
  from CI with `--branch=main`; without that the deploy lands as a *preview* and the bridge in production silently stays old — the app then
  answers "Unknown bridge route" for anything newer than the last real deploy.
- Web apps in the app (`BMWebApps.swift` is pure and Linux-checked; `BMWebBrowser.swift` is the WebKit layer): BookMaster, Kindred and Quest Log
  open inside Pageturner from the Together tab (an "Other apps" card, and any notice in "From the other apps" opens its page). All three live on
  `bookmaster.pages.dev` (BookMaster at the root, `/kindred/`, `/quest-log/`), so one persistent `WKWebsiteDataStore.default()` signs in once for
  all; Settings → Chat & web apps clears it. One `WKWebView` per app is kept alive (`BMWebPages`, shed on a memory warning). `BMWebPolicy.decide` is the
  only rule for where a page may go: our host is shown, a link into another of the three switches the browser to that app, every other site, `mailto:`
  and `tel:` go to iOS, and `pageturner://`, `file:`, `javascript:` and plain `http` are refused. The web view needs the app to supply what Safari does:
  JS alert/confirm/prompt panels (without them `confirm()` silently answers no), `target=_blank` links, and `WKDownload` for files a page saves
  (BookMaster's CSV/JSON export is a blob download) — handed to the share sheet. The sign-in is the web's own (BookMaster's password); nothing links
  the bridge's device key to a web session, on purpose. Things this layer has to get right (each was a real bug in review): Quest Log's notice
  paths already say `/quest-log` while Kindred's are relative to `/kindred` (`BMWebApp.noticePrefix`); BookMaster's `/link/*` pages only hand the
  reader on, so after a cross-app switch the source page is sent back to its front door (`isHandoff`) or it stays on "Linking…"; `window.open`
  of `about:blank`/`blob:` must be refused (`newWindow`) or it blanks the page; the pages are held by `BMWebPages` and the host view follows the
  page (`BMWebHost.updateUIView`), because a page shed for memory or reset by sign-out is replaced while a view may still be showing it.
- Notifications are **local** (`Notifications/`): a sideloaded app has no push entitlement, so iOS's
  background refresh (best effort, its schedule) asks BookMaster for new suggestions and posts them.
- Notifications are Pageturner's own — no push service, no third-party app (a free-Apple-ID sideload has no push entitlement, and relaying
  through ntfy.sh or Bark was tried and dropped: ntfy.sh limits Cloudflare's shared address, and a notification made by another app wears
  *its* icon, which iOS will not let a payload replace). What there is: `Notifier` asks BookMaster what is waiting (`together`) every 30 s
  while the app is open (`PageturnerApp`), and tells what is new — a **banner** (`BMBannerHost` over the shell, not over the reader, not
  for a message arriving while the chat is open) when the app is active, a **local notification** when it is not (and the reader allowed
  it). Everything told is kept in the **inbox** (`BMInbox` pure and Linux-checked, `BMInboxStore` saves it per account, `BMInboxView` is
  the list: the Together tab's bell and Settings → Notifications); `AppRouter.open(_ item:)` is where an item leads (the chat, the Together
  tab, or a page of a web app), used by banner and list alike; a tapped local notification carries its item's id (`tappedItemID`). The Together tab badge and the app icon count the inbox's unread. An item cleared while BookMaster still lists it is held back (`dismissed`, saved with the history), or the next look would bring it back unread.
  Behind the app, iOS wakes Pageturner for a background refresh when it likes; **Stay connected** (`BackgroundKeepAlive`, off by default,
  `BMKeepAlive` holds the rules) loops a silent sound so the app is kept running and looks every 30 s (90 s in Low Power Mode). It mixes
  with other sound, leaves a book's audio session alone (the category is only set when it is not already `.playback`), and stops when the
  app is in front. Unverified on a device: how long iOS keeps it alive. `pageturner://open` (`BMDeepLink`) still opens the chat or a web
  page. BookMaster no longer has an ntfy or Bark channel (its tables are left, unused).
- Siri/Shortcuts (`Intents/`) and Spotlight (`Library/SpotlightIndexer.swift`) hand requests to the shell
  through `IntentRouter`, which holds them until the first screen exists.
- Read-aloud voices (`Reader/` and `Neural/`): `SpeechVoices.swift` is Foundation-only (list, group, search, "best
  voice for a language", the speed scale) and checked on Linux. `SpeechText.swift` (Linux-checked) is what every
  sentence passes through before a voice: printed-line hyphens, ligatures, footnote markers, `etc.`/`e.g.`,
  en-dash ranges and roman chapter numerals, plus `shouldJoin`, which glues back sentences the tokenizer cut at a
  title ("Dr.") or before a lower-case continuation. Device voices go through `SystemTTSEngine` (ours, not
  Readium's `AVTTSEngine`, whose utterance text can't be changed): it speaks `SpeechText.spoken(text)` and maps
  each reported range back onto the page's text with `SpeechText.originalRange`; `NeuralTTSEngine` does the
  same. The tokenizer never rewrites a segment's text — Readium slices `locator.text.highlight` with the
  ranges the engine reports, so the two must be one string. Device voices: `SystemVoices.swift`; the shared list
  and the Settings/Reading-sheet rows: `VoiceListView.swift`; **always use `SpeechPreview.shared`** — an
  `AVSpeechSynthesizer` freed while iOS is still calling back into it crashes inside TextToSpeech.
  `VoiceListView` pauses every `AudioFocus` owner on appear so a sample never overlaps narration, and
  `ReadAloud.heldForFocus` keeps a claimed pause from being undone: Readium's `pause`/`stop` cancel the
  play task, but a task parked *between* sentences still runs `play` and reports `.playing` — the flag
  squashes that ghost and `CompositeTTSEngine` refuses `speak` on an already-cancelled task, so the
  engine never says the sentence.
  Neural voices (Piper on sherpa-onnx, the official SwiftPM package `k2-fsa/sherpa-onnx`):
  `NeuralVoiceCatalog.swift` (the bundled `NeuralVoices.json`, made by `scripts/make-neural-catalog.py`, pinned to a
  commit of rhasspy/piper-voices so URLs and MD5s stay true), `NeuralVoiceFormat.swift` (turns a Piper download
  into what sherpa loads: `tokens.txt`, and the voice's facts appended to the `.onnx` as protobuf `metadata_props`
  — byte-identical to sherpa's own conversion, verified by loading it with sherpa-onnx and transcribing the speech),
  `NeuralVoiceStore.swift` (download, MD5 check, install into Application Support, delete), `NeuralSynth.swift`
  (loads a model, makes a sentence on one serial queue), `NeuralPlayer.swift` (AVAudioEngine + time-stretch, so speed
  is exact and changes mid-sentence), `NeuralTTSEngine.swift` (Readium `TTSEngine`, and a composite that routes a voice
  to the right engine; it also makes the *next* sentence while one is said — `Reader/SentenceLookahead.swift` walks the
  book's content the way Readium's synthesizer does to find it — so Readium's state stays equal to what is audible). espeak-ng's phoneme data (`ios/Resources/espeak-ng-data`, GPL-3) is bundled; sherpa exits the
  process on a model it can't load, so only files this code wrote itself are ever handed to it.
- Read-aloud highlights (`Reader/ReadAloud.swift`): three independent options, `ReaderSettings.highlights`
  (`ReadAloudHighlights`, stored tolerantly — `ReaderSettings.init(from:)` must list every new key): sentence (Readium's
  `.highlight`, group `tts`), line (`tts-line`: a custom `HTMLDecorationTemplate`, `width: .page`, drawn in `currentColor` so it
  suits every theme, with its look inline in the element's `style` — see the Readium CSS note above) and word (`tts-word`). Both templates are registered in `ReaderModel` (`ReadAloudStyle.swift`). The word
  comes from Readium's state for device voices and from `NeuralTTSEngine` for neural ones, which has no word callbacks:
  `SpokenWords` (pure, Linux-checked) estimates each word's start from its length plus a pause per comma / full stop, spread over
  the audio's speech part, and `NeuralPlayer` reports how far the audio has played (~30×/s). The constants were fitted against
  ~190 sentences by three Piper voices with an ASR's word timestamps as the reference (about 105 ms mean error; the web app's
  proportional-by-character estimate scores 136 ms). The ASR lags the sound by ~0.33 s — measured with isolated words.
  Scroll-mode follow centres on the painted mark — in Readium's decorator DOM a group's `> div` is a *static* wrapper
  parked at the end of the document (centring on it throws the page to the chapter's last screen); only the positioned
  mark children carry `data-writing-mode`, which is what the script selects.
- Page curl (`Reader/PageCurl*.swift`, `ReaderContainerViewController`): the container's pan must beat Readium's paging
  scroll views, which are deeper in the hierarchy and win by default — `shouldBeRequiredToFailBy` makes them wait for
  it. The leaf's edge is the page's own edge at the finger's height; the finger's travel moves it, wherever on the
  page the drag began. It stands aside while text is selected.
- Audiobook sound (`Audio/VoiceDSP.swift`, `VoiceTap.swift`): voice boost and trimmed silence are an
  `MTAudioProcessingTap` on the playing item. `VoiceDSP` is pure (Linux-checked); trimming works by the player running
  faster than the chosen speed while the tap reports quiet, never by cutting audio.
- Bionic reading (`Reader/BionicReading.swift`): a user script in each chapter's web view
  (`navigator(_:setupUserScripts:)`), reversible, checked in headless Chromium. OpenDyslexic is Readium's own bundled font.
- Online catalogues (`Library/OPDSFeed.swift` parses, Linux-checked; `OPDSBrowser.swift` browses and downloads through the
  normal importer; passwords in the Keychain). Plain http is allowed only on the local network (Info.plist).
- `OpenAt` (`Library/HighlightsHub.swift`) carries a one-shot "open at this place" from the hub to the reader.
- Scheduled backup (`Library/AutoBackup.swift`, planning in `AutoBackupPlan.swift`, Linux-checked): the same zip as the manual
  export, named by day into a Files folder kept as a bookmark, oldest copies pruned. Made on opening the app when due, and by a
  `BGProcessingTask` (needs `processing` + the identifier in Info.plist; handler registered in `PageturnerApp.init`) — iOS picks
  the time, so the foreground run is the reliable one. It checks free space first: a backup is every book file.
- **Google Drive** (`Drive/`): browse and add books, watch a Drive folder, and back up to Drive. `DriveCore` is the pure part
  (Linux-checked: Drive v3 decoding, queries, sign-in URLs, sync plan, backup pruning, error wording); `GoogleAuth` is OAuth for an
  installed app — `ASWebAuthenticationSession` + PKCE with Pageturner's own **iOS-type client ID, built in**
  (`GoogleDrive.defaultClientID`; no client secret exists and the ID is public), so a reader only ever sees "Sign in with Google", redirect
  scheme = the client ID reversed (`com.googleusercontent.apps.…:/oauth2redirect`, no Info.plist entry needed), the refresh token in the
  Keychain (this device only). Scopes: `drive.readonly` (browse/download what is picked; a restricted scope, so the app is "unverified"
  and a project in *Testing* mode expires the sign-in after a week — Publish it) and `drive.file` (write only what the app made). The
  `drive.file` scope can write only to folders the app created, so backups go to a "Pageturner Backups" folder it makes and remembers
  by id (`DriveClient.backupFolder`), never one found by name. `DriveClient`: 401 renews the token once, 429/5xx retry with backoff,
  uploads are chunked resumable (8 MiB pieces, offset asked for after a failure, 308 not followed).
  **Books are never downloaded by adding them.** Ticking books or folders in the browser (a circle on a folder row ticks everything under it,
  to 8 levels and 1000 books) and `DriveSync` (a watched folder: a folder id, each file's id+checksum remembered, a file touched in the last
  30 s waits, at most every 10 minutes on opening) put **entries in the library**: `Book.drive` (`GoogleDrive.Source`: the Drive files in play
  order, each with id/name/size/md5, and the first title guess) with the local file names planned up front (`<id>.<ext>`, `<id>-<n>.<ext>`).
  `DriveBooks.plan` (pure, Linux-checked) groups the files the way the Files importer does (sibling "CD n" folders merge, file-name stems keep
  two books in one folder apart, `AudioGrouping.folderTitle`) and skips what the library holds (`LibraryStore.driveFileIDs`); a zip or a
  text file cannot be an entry before it is opened, so the browser still downloads those at once and the watcher leaves them (and says so).
  A Drive book without its files is `LibraryStore.inCloud` (not `missing`): its cover wears a cloud badge, a tap opens its page
  (`AppRouter.open` → `detail`) with **Download**, and the context menu and select bar have it too. `DriveDownloads` does the work with a
  **background `URLSession`** (iOS runs it: it goes on with the app closed, waits for connectivity, and is reconnected at launch —
  `PageturnerApp.init` + `PageturnerAppDelegate.handleEventsForBackgroundURLSession`): one task per part (taskDescription
  `book|index|name|size|file` outlives the app), the finished file is moved into the Books folder inside the delegate call and size-checked,
  a failed part is asked for again 3 times (fresh token on 401, resume data when iOS kept some), then the book shows why and "Try Again"
  asks only for what is missing. When the last part is in, `LibraryStore.driveDownloadFinished` reads the file (Readium / audio tags) for
  title, author, cover, blurb — onto what the reader has not changed (`Source.guessedTitle`) — and a local notification says so when the app
  is not in front. Settings → Google Drive has "Download over mobile data". "Remove Download" frees the files and keeps the book and its
  place. **Listen Now** plays a Drive audiobook without downloading it: `AudioPlayer` streams each part not on the phone with an
  `AVURLAssetHTTPHeaderFieldsKey` bearer (refreshed every 45 min; a refused stream is re-asked once or twice from where it was). A book
  already on the phone whose files are the very same size as a Drive file is linked to it (`LibraryStore.existing(for:)`), not duplicated.
  The watcher's automatic look first asks the Drive's change feed (`changes.list`, one entry) and lists nothing when nothing changed.
  A backup holds Drive books without their files and restores them as waiting entries. `AutoBackup` has a destination
  ("backup-auto-dest": folder | drive; Drive needs the network, so the background task asks for it); `DriveBackupsView` restores one. The
  library's + is a menu (Files / Google Drive). The simulator run photographs the cloud badges (02), a book's page not started (03a) and part
  way down (03b).
- Page-turn sound (`Reader/PageTurnSound.swift`, `Resources/Sounds/pageturn.wav`, synthesised noise): a *system* sound so it
  follows the ringer switch and never touches the audio session an audiobook is using.
- Trends (`ReadingTrends` in `Library/ReadingStats.swift`, Linux-checked): weekly totals and the finish-date forecast, which
  spreads what a book gained over the days since its first sitting in the last three weeks (days off count against the pace).
- Saved words (`SavedWord` in the Book model region, `Library/SavedWordsView.swift`): "Save Word" in the selection menu keeps
  the word and a line of context on the book; the list opens iOS's dictionary. `Highlight.quoted` stops "Send new highlights
  as quotes" (off by default) from posting one twice.
- Not built, on purpose: a Home Screen widget (app extension + App Group, which free-Apple-ID signing
  doesn't reliably provide) and CarPlay (entitlement).
