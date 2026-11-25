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
- AltStore/SideStore feeds: `ios/scripts/make-altstore-source.py` writes `altstore.json` (versions history,
  news, `appPermissions.privacy` = the IPA's own `NS*UsageDescription` keys — AltStore refuses a mismatch).
  `ios.yml` rolls it onto the `ios-latest` release each green build (`ios/scripts/publish-release.sh`);
  `ios-release.yml` rolls `ios-stable` per tag. `docs/_redirects` exposes both as
  `pageturner.pages.dev/altstore[-nightly].json`; source screenshots live in `docs/ios/`.
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
- The page anchors a locator's text *inside* the element its `cssSelector` names (`rangeFromLocator` in Readium's
  `utils.js`, hypothesis' `matchQuote`: up to half the quote may be wrong, and the best of the candidates wins). With no
  selector the search is the whole chapter, so a sentence the DOM spells slightly differently was "found" screens away and
  the narration follow went there for a second on every such sentence. Never drop `cssSelector` from a locator: Readium's
  iterator writes ids with a leading digit unescaped (`#1abc`, which `querySelector` rejects), and
  `Locator.anchorable` repairs that (`Reader/CSSSelectorRepair.swift`, Linux-checked) instead.
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
  the reader is away `ReadAloud.onScreen` is false: nothing is followed, painted or measured per word. Whether it is away or not, each new
  sentence is reported (`onNarrated` → `ReaderModel.narrated(to:)`) so the saved place, the BookMaster progress and the sitting move with the
  voice: the page only follows it, so while `narrationAhead` holds, a place the navigator reports *behind* the narrated one — a page still
  catching up, or a webview reloaded to where it was when the phone locked — is ignored and never saved (`NarrationLead`, Linux-checked); a
  jump the reader asked for (`navigate`, Back) gives the page the lead back, and when the voice ends the page is taken to where it stopped.
  When the reader is back (`show`) the page catches up to the sentence being said. One voice: showing a reader for another book stops what is held; deleting a book stops its narration. Which strip
  shows when an audiobook is loaded too is `NowPlayingBar.choose` (pure, Linux-checked): whichever last took the stage, i.e.
  `AudioFocus.holder` (now `@Observable`; it mirrors `RemoteControls.activeOwner`). The simulator run (`-PTDebugReaderSheet readaloudaway`)
  starts the voice, leaves the reader and fails if no `PTNarrated` line follows; `68-readaloud-strip` is the photograph.
- One voice, always known to a reader (`ReadAloud.current`, `ReadAloud.stray`): a voice's play loop holds itself alive (its task retains the
  synthesizer), so a reader that is torn down mid-sentence leaves it speaking with nobody's controls showing it — and Play, offered afresh, started a second
  beside it (the double play after unlocking). `begin` now stops whatever `current` voice there is first (also cutting the shared `NeuralPlayer` and the
  shared `AVSpeechSynthesizer` at once, `SystemTTSEngine.silence`), and a reader that finds a voice with no reader (`ReaderModel.adoptStray`, at
  `readerShown` and when it has opened) stops it and starts its own from the sentence it was on. `ReadAloud.owner`/`bookID` are set by the reader that
  starts it. The log's "reader in front" line (every `.active`) says what the reader and the app each think the voice is doing — read it first when the
  controls and the sound disagree. A reader coming back to the front does not move the page at once: `ReadAloud.afterSettling` waits 450 ms for the web
  views to wake, then paints the marks afresh and moves the page once, without the slide (`followQuietly`), and `ReaderModel.refreshAwakeSoon` asks for
  a repaint again as they come up. The neural voice times each sentence's words whenever words are wanted and only says them while the page is watched
  (`NeuralTTSEngine.watched`), so a sentence that was half said when the phone was unlocked has its word mark at the next tick, not after the sentence.
- Marks and page turns keep up with the voice (`ReadAloud.syncMarks` / `lookAtPage`): the page runs what it is sent in order, so a mark per word
  that takes longer to anchor than a word takes to say piles up, the highlight trails the voice by more and more, and the `go` that turns the page
  waits behind it. Now one update is in flight: paint, wait ~45 ms (Readium draws on the next animation frame), then ask the page for the first mark
  (`markScript`: "on", "off" the page's width, or "none") — the answer comes after everything sent before it, so how long it takes is how far behind
  the page is — and words said meanwhile are skipped (the next mark is the word then being said). A mark found off the page turns it at once (at most
  one such turn per 0.7 s; three turns in a row that did not bring it in view switch the shortcut off and the old throttled `go` a second takes over,
  which also runs whenever there is no mark to find, in sentence-only highlighting's case always). The log says, at the end of a session and when the
  page is left, how many marks were sent and skipped, the page's slowest answer and the main thread's longest hold-up (`logSession`; slow ones are
  logged as they happen) — read it first when the highlighting or the page turning lags.
- The word and its line are drawn by the page itself (`Reader/SpokenMarkScript.swift`, the `offsets` half Linux-checked): the sentence is found once
  (its characters, spaces left out, inside the element its `cssSelector` names), a word is then two UTF-16 counts into it, and one call moves two boxes
  that are already there and answers "on"/"off" the page — no 45 ms wait, no second ask, about a tenth of what a Readium decoration per word costs in a
  long chapter. The boxes sit in a container that looks like Readium's (`data-group="tts-word"`, children with `data-writing-mode`, the band first) and
  are taken out of the document when hidden, so `markScript` and `keepSpokenInView` find either kind. `ReadAloud.markInPage` answers nil — and the marks
  are Readium's decorations as before — when the voice is in another chapter than the page, the sentence is not found, the writing is vertical, or it is
  Low Power Mode; four sentences refused in a row (fixed layout) and it is not tried again. The sentence mark is always Readium's. The script was run in
  headless Chromium beside Readium's own `readium-reflowable.js` and Readium CSS: same rectangles as its decorations for the same words.
- The neural voice's words: `SpokenWords.Timeline` (when each word starts, and where it is in the page's text; Linux-checked) is made with the sound, in
  the make-ahead task and off the main thread (`NeuralTTSEngine.timeline`). `NeuralPlayer`'s `progress` answers how long until the next word starts and
  the ticker wakes then, not at the next 66 ms. Sentences made ahead run at `.utility` on `NeuralSynth`'s queue; `hurry()` (an empty urgent block behind
  them — a serial queue lends its priority) is called when one is waited for, or when the sentence being said has under 2.5 s (or six tenths of itself, if more) left.
- A page that will not turn (`ReadAloud.pageIsStuck` → `ReaderModel.reloadPages`): Readium's navigator is a state machine (`EPUBNavigatorViewController.State`):
  `go(to:)` takes it to `.jumping` and back only when `PaginationView.goToIndex` returns, and while it is `.jumping` or `.moving` every other `go` answers
  false at once. A move that never finishes — the target spread never loads, a web view stops answering `evaluateJavaScript` — so refuses every later turn
  for good: the voice reads on pages nobody sees, for minutes, then something lays the pages out again (a rotation, a killed web process) and the page
  comes up half painted. (`fadeToView` also leaves the whole pagination view at alpha 0 while it waits: a blank page.) Only `.load` leaves a stuck state,
  and the public way to send it is a layout preference changing: `reloadPages` flips `fit` (`EPUBPreferences.fit` is for fixed-layout books only, so nothing
  the reader sees changes but the pages being made again, place kept; `pagePreferences` keeps the flip so the next setting change does not flip it back).
  Triggered by six turns in a row refused or unanswered, or the voice's mark off the page for ten seconds, at most once in 45 s, with the page then taken to
  the voice without the slide. Turns are made without the slide after any failure, too: a long smooth scroll to catch up left the web view half painted.
  The log says `the page is not following the voice (…)` and `laying the pages out again`.
- Battery while it reads aloud: `ReadAloud.spoken` is a plain subject, not `@Published` (it changes per word and no SwiftUI view shows it — published,
  the controls were laid out again per word); the place is written at most every 20 s while the voice moves it (`ReaderModel.scheduleSaveForVoice`; a
  pause or leaving writes at once) instead of the whole catalogue per sentence; and the neural player's ticker runs at 120 ms, not per word, while
  nobody is watching (`follow` answers nil when `watched` is false).
  "Dim the screen while it reads" (on by default) really dims now: it used to set `UIScreen.wantsSoftwareDimming`, which only lets the screen
  go below its lowest step and dims nothing, so with "Keep screen awake" (also on by default) a book read aloud held the screen at full
  brightness for as long as the voice went on. Fifteen seconds hands-off (`NarrationDim.delay`; `ReaderView.wantsDim`: controls hidden, no
  sheet) turns it down to about a third (`NarrationDim`, Linux-checked; `ScreenDimmer` moves `UIScreen.brightness`); a tap gives the light
  back at once, unless the brightness was moved meanwhile (theirs stands). An app's brightness outlives it on the home screen, so it is
  given back at `.inactive` and on leaving the reader. Also cut: the stall watch runs only while the voice goes and its page is watched (it
  woke the app five times a second behind the lock); the lock screen's playback state is written when it changes, not per word; the
  neural player passes its time-stretch unit by at 1× and ticks four times a second, not eight, with no word to come; and the device voice
  reports only each sentence's first word while nobody watches (`SystemTTSEngine.watched`; the first still proves the voice works).
- Neural voices' processor time (`NeuralSynth`): a voice is loaded with **one** ONNX Runtime thread unless it has shown it cannot keep up on one
  (`threads(for:)`, remembered per voice in `neural-threads-<key>`). Two were the rule: ORT's second thread spins rather than sleeps between the
  model's many small steps (sherpa-onnx does not expose `allow_spinning`), and a thread the queue does not run is not held to the queue's
  priority — so sentences made ahead at `.utility` still ran on the performance cores. On one thread all of it runs on `NeuralSynth.queue`'s own
  thread at the block's QoS, which `hurry()` lifts. A made-ahead sentence still being made at its turn after one of 3 s or more
  (`NeuralTTSEngine.noteWait`, > 150 ms) twice in ten minutes gives that voice two threads for good (`needsMoreThreads`, reloaded at once; never in
  Low Power Mode). The log says, per voice, how long each load took and on how many threads, and every 100 sentences the seconds of speech made
  against the seconds of processor time it took ("0.30 of real time" = busy a third of the time it speaks) and how many were made ahead.
  A voice listened to at 1.25× or more makes its sentences at that pace (`NeuralPace`, Linux-checked: quarter steps up to 1.75×), not at its own
  pace for the player to squeeze: VITS's cost goes with the sound it makes, so at 1.5× it was making half as much sound again as was heard. VITS
  does not reach the pace it is asked for exactly (each sound's length rounds up to a whole frame, the short gaps stay), so what a pace really
  gives is measured once per voice and pace on the language's sample (`NeuralSynth.calibrate`, stored in `neural-pace-<key>-<pace×100>`; 1 = not
  worth it) and the player stretches by the rest (`NeuralPace.stretch`), keeping the speed exact; until it is measured, sentences are made at the
  voice's own pace as before. Each made sentence carries how much faster it was made (`Made.achieved`), so a speed change mid-listen stays exact.
  The log line `voice … asked for 1.50× speaks 1.38×` is the measurement.
  Read the cost line first when a long listen drains the battery: 50% in two hours with the screen off (an iPhone 15 Pro Max) is ~4 W, far above what
  audio playback costs. "Stay connected" (`BackgroundKeepAlive`) looks every two minutes rather than every half minute while a book of ours
  is playing (`BMKeepAlive.pollInterval(lowPower:bookPlaying:)`): the sound keeps the app running anyway, and a look every 30 s kept the radio
  awake for the whole listen. While a voice reads, the reading place goes to BookMaster when the voice pauses (the lock screen, headphones, a
  call — the playing sink in `ReaderModel.readAloud`, `pushProgress(every: 0)`, sent only if it moved) and when the listening ends (`endSession`
  forces it), with a send every 15 minutes as the net for iOS ending the app mid-listen (`ReaderModel.voiceProgressEvery`,
  `BookMaster.wantsProgress/syncProgress(every:)`; page turns keep 30 s). It moves every sentence, and a push every half minute did the same to the radio.
- Battery: presence beats run every 90s in front (120s under Low Power Mode) with one retry on a
  miss — BookMaster holds presence for two minutes. `App/LowPower.swift` names the mode: it slows
  the neural voice's playhead ticker, throttles the curl's animated finishes to 15fps, and drops the
  marks that move per spoken word (the sentence mark stays). Grid covers come from
  `LibraryStore.coverThumbnail(for:maxPixels:)` — ImageIO-decoded at cell size and NSCache'd —
  never `cover(for:)` in a list.
- Turning a page from code (`ReaderModel.turnPage(forward:)`) goes the way a tap at the edge does — the chosen turn,
  rustle and tap — and is what the volume buttons and the hands-free turner use. The volume buttons
  (`Reader/VolumeButtonPager.swift`, Reading sheet switch, off by default) watch `outputVolume` and put the volume back
  through an off-screen `MPVolumeView` (which also keeps iOS's volume banner away). Only while nothing of ours plays
  (asked at each press); with nothing of ours holding the session it takes an `.ambient` mixing one, so no one's
  music stops, and a paused voice's or audiobook's session category is left alone. `ReaderView.wantsVolumeTurns`
  turns it off with a sheet up, the voice speaking or the app inactive.
- Hands-free turning (More menu ▸ Turn Pages for Me; `ReaderModel.startHandsFree`, pace in `HandsFreePace`,
  Linux-checked): a page stays up for the share of the book a page is (the middle of the recent page steps within a
  chapter) times this reader's minutes per book (`ReadingPace`), 5 s–5 min, 45 s until there is enough to go on. The
  tortoise/hare steps are kept per book (`handsfree-seconds-<id>`) and then win over the measured pace. A page the
  reader turns restarts the page's time (a place reported within 1.5 s of the turner's own turn is its own); a sheet
  or the app away holds it (`ReaderView.holdsHandsFree`); the voice starting stops it. It keeps the screen on.
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
  The reader saves only what it changed (`LibraryStore.saveReading(_:since:)`, a three-way merge against `ReaderModel.stored`,
  lists merged by id) and takes in changes made elsewhere (`libraryChanged`, from `library.$books` after the write lands): a
  reader lives for hours, and writing its whole copy back undid Mark as Finished, Start Over and deleted words. A place moved
  elsewhere wins: narration stops and a book started over goes to its start. A sitting idle for over five minutes ends there
  (`closeIdleSitting`). The sleep cover goes up only on active → inactive, the reader is hidden from the voice at `.inactive`
  (a locked screen may never reach `.background`), and the cover always comes off at `.active`.
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
- Linking: `BookMasterLinkSheet` (a `WKWebView` on the shared default data store, so the sign-in it ends with is also the one BookMaster's tabs use) opens
  bookmaster.pages.dev/link/pageturner?from=https://pageturner.pages.dev; BookMaster signs the user in and
  sends the browser to `pageturner.pages.dev/?bm-link=<code>`, which the sheet's navigation delegate cancels,
  reading the code off the URL (`BMLinkURL.code(fromReturn:)` — only that host, https, a plausible code).
  Nothing of the web site is involved, so it works whether or not the PWA is deployed. (`pageturner://link?code=`
  and `docs/js/native-link.js` are the older route and still work; the app handles both.) Why not
  `ASWebAuthenticationSession`: its callback came from a page that was never deployed, so linking never completed.
- BookMaster's screens are BookMaster's own pages, not a native copy: the **Shelf**, **Together** and **Stats** tabs are web views of
  `/library`, `/together` and `/progress` (`BMWebTab`, pure and Linux-checked; `BMWebTabView` / `BMWebTabContent` in `BMWebTabs.swift`), opened
  with `?in=pageturner` (remembered for the life of the view, `BookMaster/src/lib/embedded.ts`): BookMaster then draws the page alone — no bars,
  bell, banners or chat button, and no heartbeat of its own — and Pageturner draws those around it (tab bar, Settings, the Together bell and the
  "Open an app" menu) and says where you are (`place`, set from the selected tab in `RootView`). One `WKWebView` per tab is kept alive
  (`BMWebPages.tab(_:)`), pull to refresh is the web view's own. The web's own tab bar and header are not drawn there, so the tab's toolbar brings a Back
  button (while the tab has been sent somewhere) and a "BookMaster pages" menu (`BMWebPlace`: Today, Find a Book, Series, Wrapped, Profile, the tab's own page, Reload). Unlinked, a tab shows `BMLinkPrompt` instead. A link out of a tab into Kindred or
  Quest Log opens that app full screen (`router.browser`, `BMWebBrowserScreen`), as do notices and `pageturner://open`. What stays native is what
  needs the device: the link and its sync (`BookMasterClient`: progress, sessions, quotes, covers, shelf pull, shelving a book, comments and
  suggestions on a book's page), the notifications and inbox (`Notifier`, `BMInbox*`), the floating chat button, and the barcode scanner. Do not
  rebuild a BookMaster screen natively: change the web page, and every app shows it. `BMDot` (`BMDot.swift`) is the notification dot.
- Chat: the suite's one shared room and Quest Log's own are BookMaster's chat page (`/embed/chat`, with its two tabs), shown full screen by
  `BMChatScreen` (`BMWebTabs.swift`) — reached from the floating chat button below, and from a chat notice. Quest Log's room inside it is Quest Log's
  own page (`/quest-log/?embed=chat`, framed same-origin), so it asks for its passphrase itself and is the same screen as in Quest Log and
  BookMaster; the app holds no keys and no cipher. Receipts, typing and reactions are those apps' business. `BMChat` (pure, Linux-checked) is what
  is left here: the feed's `bookmaster:chat:<id>` notice that says a message waits (`BMChat.unreadNotice`), which the dot on the button shows and
  opening the chat clears (`Notifier.chatUnread` / `noteChatOpened`, also called while the chat is open so a message that arrives is read as it
  comes). Unlinking, or signing out of the web apps, clears the web sign-ins (`BMWebPages.clearSignIns`), Quest Log's unlocked room among them.
  The chat is also one tap from anywhere but the reader: `BMChatButtonLayer` (`BMChatButtonView.swift`) is a draggable round button laid
  over the whole shell in `RootView`, opening the chat as a full-screen page (`router.showChat`, `.fullScreenCover`) — a sheet read as a pop-up. When it shows and where it rests are pure
  (`BMChatButton`, Linux-checked); it steps aside over the reader (`router.readerOpen`) and over any screen marked `.hidesChatButton()`;
  Settings → Chat & web apps turns it off. Gestures and accessibility go on the small face *before* `.position`, or they stand over the whole screen.
- Settings (`Settings/SettingsView.swift`) is a short list of topics, each its own page (`SettingsDestination`), not one long form: the
  BookMaster suite (BookMaster account & what is sent, Notifications — banners, the list, notifying when closed, staying connected — and Chat &
  web apps; unlinked, only the BookMaster row shows), Reading & listening (Reading, Read Aloud, Audiobooks, Appearance), Your library
  (Library & import, Backup) and Support (Diagnostics, version). A new setting goes on the page for its topic; a new topic is a case in
  the enum, a row in the list and a view in `SettingsPages.swift` (or beside the feature). The simulator run screenshots the pages
  (`-PTDebugSettingsPush <page>`).
- Whose dot it is: a notice or count about Quest Log is blue and square, every other round in the accent — `BMDotTone` / `BMSuite.dotTone`
  (pure, Linux-checked) and `BMDot` (the view), used for the inbox and the floating chat button's dot.
  BookMaster, Kindred and Quest Log draw the same rule; change all four together.
- Deploys are not automatic for BookMaster/Kindred/Quest Log: a push to main runs CI only, and the code reaches production with
  `npm run deploy` in that repo (migrations first, `npm run db:migrate:remote`). Pageturner's own Pages deploy (the bridge function) runs
  from CI with `--branch=main`; without that the deploy lands as a *preview* and the bridge in production silently stays old — the app then
  answers "Unknown bridge route" for anything newer than the last real deploy.
- Web apps in the app (`BMWebApps.swift` is pure and Linux-checked; `BMWebBrowser.swift` is the WebKit layer): BookMaster, Kindred and Quest Log
  open inside Pageturner — BookMaster's pages as the tabs, and each app full screen from the Together tab's "Open an app" menu, a notice or a link
  out of a tab (`router.browser`, one `BMWebBrowserView` with a switch between the three). All three live on
  `bookmaster.pages.dev` (BookMaster at the root, `/kindred/`, `/quest-log/`), so one persistent `WKWebsiteDataStore.default()` signs in once for
  all; Settings → Chat & web apps clears it. One `WKWebView` per app, and per tab, is kept alive (`BMWebPages`, shed on a memory warning). `BMWebPolicy.decide` is the
  only rule for where a page may go: our host is shown, a link into another of the three switches the browser to that app, every other site, `mailto:`
  and `tel:` go to iOS, and `pageturner://`, `file:`, `javascript:` and plain `http` are refused. The web view needs the app to supply what Safari does:
  JS alert/confirm/prompt panels (without them `confirm()` silently answers no), `target=_blank` links, and `WKDownload` for files a page saves
  (BookMaster's CSV/JSON export is a blob download) — handed to the share sheet. The sign-in is the web's own (BookMaster's password) — the link sheet makes it, in the shared store, so the tabs
  need no second one; the bridge's device key itself is never tied to a web session. Kindred and Quest Log keep their own (BookMaster's `/link/*` pages hand a signed-in reader across). Things this layer has to get right (each was a real bug in review): Quest Log's notice
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
  tab, or a page of a web app, `AppRouter.openSuite`), used by banner and list alike; a tapped local notification carries its item's id (`tappedItemID`). The Together tab badge and the app icon count the inbox's unread. An item cleared while BookMaster still lists it is held back (`dismissed`, saved with the history), or the next look would bring it back unread.
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
  same. Words the reader taught the voice (`Reader/Pronunciations.swift`, Linux-checked; kept by
  `PronunciationStore`, edited from the selection menu's "Pronounce" and Settings → Read Aloud → Pronunciations) go in
  last, in `SpeechText.prepared`, which keeps where each went so `WordMap` marks every part of "her-MY-oh-nee" on the
  printed "Hermione"; the cache is keyed on `Pronunciations.generation`, so a word taught is heard from the next
  sentence. Every book's entries apply, and the voice's book's own over them (`ReadAloud.begin` says which book).
  The tokenizer never rewrites a segment's text — Readium slices `locator.text.highlight` with the
  ranges the engine reports, so the two must be one string. Device voices: `SystemVoices.swift`; the shared list
  and the Settings/Reading-sheet rows: `VoiceListView.swift`; **always use `SpeechPreview.shared`** — an
  `AVSpeechSynthesizer` freed while iOS is still calling back into it crashes inside TextToSpeech.
  `VoiceListView` pauses every `AudioFocus` owner on appear so a sample never overlaps narration. The play loop is
  ours (`Reader/SpeechSynthesizer.swift`, Readium's `PublicationSpeechSynthesizer` kept to the main actor — Readium's
  wrote its state on a background executor while read-aloud read it per word, the SIGBUS after long sessions): one
  `while` loop per play task (not a call chain — that held every sentence's frames until a pause), nothing set after a
  cancel (so no "ghost" `.playing` after a pause; read-aloud drops any report that doesn't match the current state),
  and one content-iterator call at a time (`loading`: a skip waits for the call a cancelled task left running and
  takes its paragraph — two calls at once raced the iterator and lost a paragraph). A `.stopped` the synthesizer
  reports by itself (the book's end, unreadable text) ends the session like Stop. Automatic (no voice chosen) speaks a
  sentence with an installed neural voice for its language (`CompositeTTSEngine`, the `.right(language)` case).
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
  page the drag began. It stands aside while text is selected. The page is bound at its spine: the finger's place is held
  to where the paper can go (`PageCurl.constrained`, Linux-checked — both spine corners stay on the flat side of the
  crease; a pull up or down flipped the sheet top over bottom, and one past the spine lifted it), and a committed
  release swings the pull round to straight across as it finishes, so the leaf settles flat beyond the spine.
- Audiobook sound (`Audio/VoiceDSP.swift`, `VoiceTap.swift`): voice boost and trimmed silence are an
  `MTAudioProcessingTap` on the playing item. `VoiceDSP` is pure (Linux-checked); trimming works by the player running
  faster than the chosen speed while the tap reports quiet, never by cutting audio.
- Bionic reading (`Reader/BionicReading.swift`): a user script in each chapter's web view
  (`navigator(_:setupUserScripts:)`), reversible, checked in headless Chromium. OpenDyslexic is Readium's own bundled font.
- Online catalogues (`Library/OPDSFeed.swift` parses, Linux-checked; `OPDSBrowser.swift` browses and downloads through the
  normal importer; passwords in the Keychain). Plain http is allowed only on the local network (Info.plist).
- Author lines (`Library/AuthorNames.swift`, Linux-checked): every place that builds one from several names (EPUB details,
  FB2, OPDS entries) goes through `AuthorNames.joined` — each person once, joined by " & " (a comma reads as "Last,
  First"). A book's details often name one person twice ("John doe" and "John Doe", "Doe, John" and "John Doe"), and the
  line read "John doe & John Doe". The catalogue cleans lines saved before this when it loads (`AuthorNames.cleaned`).
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
- Finishing a book (`App/FinishedBook.swift`): `FinishedBookSheet` asks once per finish (`FinishedAsk`, forgotten by
  `LibraryStore.restart` and an audiobook played again from its end) for a BookMaster rating and what to do with the file —
  Remove Download for a Drive book (it stays, to come down again), Remove Book and File for one whose file is its only copy,
  or Keep It. It comes on leaving a reader in which the book was finished (`ReaderModel.finishedHere`, `ReaderView.onDisappear`),
  when an audiobook plays out (`AudioPlayer.advance`), both through `IntentRouter.Request.bookFinished`, and after Mark as
  Finished (`AppRouter.markFinished`); `AppRouter.offerFinished` waits for a sheet that is up and skips a book with nothing
  to ask. Settings' "Clear files without asking" (`auto-clear-finished`) clears on leaving instead — reading the library's
  record, not the reader's opening copy, which never looked finished.
- Saved words (`SavedWord` in the Book model region, `Library/SavedWordsView.swift`): "Save Word" in the selection menu keeps
  the word and a line of context on the book; the list opens iOS's dictionary. `Highlight.quoted` stops "Send new highlights
  as quotes" (off by default) from posting one twice.
- Not built, on purpose: a Home Screen widget (app extension + App Group, which free-Apple-ID signing
  doesn't reliably provide) and CarPlay (entitlement).
