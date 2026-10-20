# Pageturner

An e-reader and audiobook player for iOS, linked to [BookMaster](https://bookmaster.pages.dev).
Everything runs on the device — books, covers, positions and the library live in the app.

## The iOS app

A native SwiftUI app (iOS 17+) built on the [Readium](https://readium.org) toolkit. It lives in `ios/`.

- **Reading:** EPUB, PDF and CBZ comics, plus plain text, Markdown and HTML (converted to EPUB on import).
  Five page themes in the web reader's palettes (Paper, Sepia, Gray, Night, Black — the chrome follows the page), fonts, sizes, spacing and margins;
  in-book search; a draggable position scrubber; footnotes and endnotes open in a sheet instead of throwing you to the end of the chapter,
  and any jump — contents, search hit, link, scrubber — leaves a **Back** chip; a **Page turn** choice — page curl, slide, book flip or fade (a swipe follows your finger; Reduce Motion gets a fade); bookmarks; highlights in five colours with notes (tap one to edit it),
  exported as Markdown; select text → Look Up / Translate / Share like any iOS reader
- **Listening:** multi-file audiobooks (M4B/M4A/MP3/FLAC/OGG/OPUS/WAV) with chapters (an m4b's embedded markers, or a file each), a chapter list,
  previous/next chapter, time left in the chapter, speed, sleep timer and lock-screen controls. Read-aloud and an audiobook never talk over each other
- **Read aloud keeps going when you leave the book:** go to the library or another tab and the voice carries on, with a now-playing strip above the tab bar (the audiobook's place) — previous/play/next sentence, tap to open the book at the sentence being said, hold for the sleep timer or Stop. Your place and BookMaster progress follow the voice.
- **Read aloud, in your choice of voice:** Settings → Read Aloud (and the voice button on the read-aloud bar) — every voice installed on the iPhone by language with a sample button
  on each (Automatic picks the best Enhanced/Premium voice for the book's language; add them in Settings → Accessibility → Spoken Content), or **neural voices** —
  Piper's, the same ones as the web app, 170 of them in 50 languages. A neural voice downloads once (20–140 MB, most about 63), is checked, and lives on the iPhone, so it works offline and with the
  screen locked; **Saved Voices** lists and deletes them. Speed 0.75–3× (0.5× too for neural voices), changeable while it speaks. **Highlight as it reads** — three switches, any mix: the
  **sentence**, the **line** (a soft band across the page at the line the voice is on) and the **word**. Device voices report each word; for a neural voice the word is worked out from
  how far the audio has played, and the next sentence is made while the current one is said so they follow without a gap. Voices are labelled Siri / Enhanced / Premium (iOS decides which of Siri's
  voices apps may use; whatever it offers is listed), and the neural ones cover the rest
- **Reading tab:** the book you are in — cover, how far along, time left at your pace — one tap back to where you stopped, and the others you have begun.
- **Library:** All / Books / Audiobooks, a status filter, **shelves** (named collections), an **Up next** shelf from BookMaster, search, sort, a **select mode** for
  bulk shelves / find details / remove, covers (designed jackets when there's no art), book details with description, year and ISBN, metadata lookup
  (BookMaster, Google Books and Open Library), mark as finished / start over; import from Files, a **zip of books**, or "Open in Pageturner";
  **Watch a Folder…** in Settings auto-imports whatever lands in a Files folder; **Google Drive** (Settings → Google Drive: one tap to sign in) browses My Drive and Shared with me and adds files or whole folders to the library *without downloading them* — each book shows a cloud badge and downloads on its own, in the background and resumably, when you tap Download — watches a Drive folder the same way, and backs the library up to a Drive folder of its own
- **Liquid Glass:** built for iOS 26 — a tab bar that shrinks as you scroll, a mini player docked above it, floating glass controls in the reader and the player.
  Earlier versions (iOS 17+) get plain materials.
- **BookMaster:** link once and your progress and finished sessions go to BookMaster as you read or listen (with a switch to pause that without unlinking);
  see the other reader, accept their suggestions, comment on a book, send a passage as a quote, and see your streaks and goals. When BookMaster has you further on
  than this phone, opening the book asks whether to jump there. Everything the other apps tell you — a suggestion, a chat message, news from Kindred or Quest Log — comes as a **banner** while Pageturner is open and is kept in a **notification list** (the bell on the Together tab); with it closed, Pageturner posts its own notification (with its own icon), and **Stay connected** (off by default) keeps it running quietly in the background so that happens within about a minute. Books are matched by ISBN / Open Library id as well as title.
  Pushes made offline are queued and replayed in order.
- **BookMaster tab (tracking):** time read and listened, streaks and a two-week chart from the phone itself — no account needed; when BookMaster is linked its streaks, goals, achievements, your shelf, the other reader and suggestions are on the same screen
- **Siri, Shortcuts and Spotlight:** "Continue reading in Pageturner", "Open *Dune* in Pageturner"; every book is a Spotlight result (switch it off in Settings)
- **Backup:** export the whole library to one zip and restore it here — also restores a backup made by the old web app

Not in the app, on purpose: a Home Screen widget (it needs an app extension and an App Group, which free-Apple-ID sideloading doesn't reliably provision),
CarPlay (needs an Apple entitlement), real push notifications (same), MOBI/AZW3/FB2/CBR, and the web app's Kokoro "HQ" voice (too large to keep resident).

### Install (sideload)

The app isn't on the App Store. Releases on GitHub carry an unsigned `Pageturner.ipa`:

- **Stable:** the [latest release](https://github.com/PossiblyPengu/PageTurner/releases/latest) — cut from the *iOS release* workflow (Actions → Run workflow; it makes the `v*` tag) or a pushed `v*` tag.
- **Nightly:** the [ios-latest build](https://github.com/PossiblyPengu/PageTurner/releases/tag/ios-latest) — every green build on `main`.

Install it with [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or [Sideloadly](https://sideloadly.io), signing with your Apple ID. A free Apple ID signs for 7 days — keep AltStore or SideStore running to refresh it automatically.

To link BookMaster, tap the gear in the library → **Link BookMaster** (or the button on the BookMaster tab).

### Update without reinstalling by hand

Add a source once in AltStore or SideStore (Sources → +) and new builds show up as updates:

- Stable: `https://github.com/PossiblyPengu/PageTurner/releases/download/ios-stable/altstore.json`
- Nightly: `https://github.com/PossiblyPengu/PageTurner/releases/download/ios-latest/altstore.json`

Every green build on `main` publishes the nightly source (the **Publish iOS build** workflow does the same by hand for any run you pick); every `v*` tag refreshes the stable one. Every build has a higher build number than the one before, which is what makes the app offer it as an update. A tag must equal `version` in `package.json` — `npm run version 2.8.0`, commit, tag `v2.8.0`, push both.

### Build

There is no Xcode project in the repo; it is generated from `ios/project.yml`:

```bash
brew install xcodegen && cd ios && xcodegen   # then open Pageturner.xcodeproj
```

On a Mac without signing set up, the CI workflow (`.github/workflows/ios.yml`) is the reference build.

### How BookMaster is reached

The app never holds BookMaster's bridge secret. Its calls go to a Pages Function at
`https://pageturner.pages.dev/api/bookmaster/*` (`functions/api/bookmaster/[path].js`),
which adds the secret and forwards to BookMaster. Linking opens BookMaster's own sign-in page
(`/link/pageturner`) in a sheet inside the app; when BookMaster sends the browser home to
`https://pageturner.pages.dev/?bm-link=<code>` the app catches that address before it loads, closes the
sheet and trades the code for a link — so the web site doesn't have to be deployed for it to work.


## The web app (being retired)

An offline-capable, installable e-reader and audiobook player PWA. Everything runs locally in the browser — no server required.

## Features

- **Reading:** EPUB, MOBI/AZW3, FB2/FBZ, CBZ and CBR comics, PDF, TXT/Markdown/HTML
- **Audiobooks:** M4B/M4A/MP3/FLAC/OGG/OPUS/WAV — multi-file books with per-file or embedded chapters, speed control, sleep timer with a live countdown, time left in the chapter, a Now Playing screen tinted from the cover, resume position, lock-screen controls with a scrubbable position
- **One voice at a time:** read-aloud and the audiobook player yield to each other rather than both playing
- **Text-to-speech:** read-aloud with device voices (Web Speech API) or on-device neural voices (Piper + ONNX Runtime WASM — no audio leaves the device)
- **In-book search:** full-text search with live results and highlighted matches, across EPUB-family books, PDFs and plain text
- **Bookmarks & highlights:** select text to highlight, copy or share it; bookmark any page; both listed alongside the table of contents
- **Footnotes in place:** note references open in a popover instead of throwing you into the endnotes, and any jump — note, cross-reference or search hit — leaves a Back chip
- **Metadata:** automatic lookup via Google Books + Open Library, candidate picker when the match is ambiguous, manual editing
- **Library:** local-first — books, covers, and reading progress persist in IndexedDB; search, sort, and a Books/Audiobooks filter; Continue-reading card resumes in one tap; select mode for bulk delete and bulk metadata lookup
- **Covers for everything:** books without art get a designed cover (title and author on a book-cloth colour chosen from the title), legible from thumbnail to full screen
- **Book page:** progress and when you last opened it, the description, a primary action worded for where you are (Read / Continue reading / Read again), and a nudge when details are missing
- **Backup:** export the whole library (books, covers, positions) to one zip and restore it here or on another device
- **Installable:** iOS-style design, Add to Home Screen on iOS, generated iOS launch images, standalone display, offline via service worker
- **OS integration:** share-target import, and file handlers — double-click a book to open it in the installed app
- **Progress:** mark a book finished or start it over from the library's detail sheet
- **Keyboard:** arrows/space turn pages, `F` or `/` searches, `T` opens contents, `B` bookmarks, `+`/`−` sets text size, `Esc` steps back out

## Install on iOS

Open the deployed site in **Safari** → Share → **Add to Home Screen**.

> The app is fully self-hosted (vendored parser/TTS engines) and works offline.
> Neural TTS voices download once (~60 MB per voice) and are cached for offline use.

## Native iOS app

See **The iOS app** above. The web app stays deployed until the IPA has been tried on a device.

## Usage

Serve the `docs/` directory over HTTP(S) — it is a plain static site:

```bash
npx serve docs
```

## Development

```bash
npm install          # install dev dependencies
npm test             # run unit tests (vitest)
npm run lint         # run ESLint
npm run smoke        # end-to-end headless-Chrome smoke test (imports a real EPUB into IndexedDB and opens the reader)
npm run vendor       # rebuild docs/vendor/ from node_modules
npm run icons        # regenerate PWA/touch icons + iOS launch images from icon.svg
npm run version      # rewrite the version into every file that carries it
```

### Releasing

`package.json` holds the version people see and a `build` number; everything
else is generated from them by `scripts/version.js`:

| Written to | What it sets |
| --- | --- |
| `docs/js/version.js` | `VERSION` / `BUILD`, shown in Settings → About |
| `docs/sw.js` | the `pageturner-cache-v*` / `pageturner-runtime-v*` names |
| `docs/index.html` | the Settings → Version row |
| `ios/project.yml` | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| `package-lock.json` | the root package's own version (nothing else in the lockfile) |

```bash
npm run version:bump     # build only — ships the same version to installed apps
node scripts/version.js 2.5.0   # new version, build bumped with it
npm run version:check    # CI fails if any of them drifted apart
```

Bumping the build is what makes a deploy reach an already-installed PWA: the
service worker keys its caches on that number, so a new build replaces the
cached app shell instead of serving last week's copy.

## Architecture

No build step — the app is vanilla ES modules served statically. All heavy
dependencies are vendored into `docs/vendor/` so the app works offline and
under a strict CSP (no inline scripts, no CDN).

```text
docs/
├── index.html            # app shell (library / reader / player / settings + sheets)
├── manifest.json         # PWA manifest (standalone, maskable icons)
├── sw.js                 # service worker: app shell + runtime cache for lazy vendor assets
├── css/main.css          # the whole stylesheet (themes, sheets, reader chrome)
├── js/
│   ├── app.js            # boot, tabs, theme, mini-player
│   ├── db.js             # IndexedDB (books, file blobs, settings, progress)
│   ├── detect.js         # format detection (magic bytes + extension)
│   ├── importer.js       # import pipeline: parse, persist, auto-metadata
│   ├── library.js        # library grid, detail sheet, metadata picker/edit UI
│   ├── reader.js         # foliate-js host: EPUB/MOBI/AZW3/FB2/CBZ(+CBR), themes, progress
│   ├── reader-text.js    # TXT/MD/HTML renderer
│   ├── reader-pdf.js     # PDF.js renderer
│   ├── cbr.js            # CBR (RAR) → CBZ repack via unrar WASM + fflate
│   ├── tts.js            # read-aloud controller: scheduling, pause/resume, skip
│   ├── tts-engines.js    # speech backends: Web Speech, Piper, Kokoro + settings
│   ├── tts-voices.js     # voice picker, previews, sleep timer
│   ├── tts-foliate.js    # read-aloud block/highlight adapter for foliate-view
│   ├── player.js         # audiobook player: chapters, speed, sleep timer, MediaSession
│   ├── book-parser.js    # filename/ID3 book+chapter inference for audio imports
│   ├── metadata.js       # Google Books / Open Library lookup + candidate matching
│   ├── backup.js         # whole-library zip export / restore
│   ├── zip.js            # stored-entry ZIP/ZIP64 writer + random-access reader over Blobs
│   ├── audio-focus.js    # read-aloud and the audiobook player never play at once
│   ├── util.js           # DOM helpers, toasts, bottom sheets, search helpers
│   ├── version.js        # generated — VERSION / BUILD
│   └── sw-register.js    # SW registration, update prompt, offline indicator
└── vendor/               # vendored engines (rebuilt by npm run vendor)
    ├── foliate/          # foliate-js reader engine
    ├── pdfjs/            # PDF.js
    ├── piper/            # piper-tts-web + phonemize WASM/data
    ├── kokoro/           # kokoro-js (HQ voice, WebGPU) + ORT JSEP build
    ├── ort/              # onnxruntime-web (non-threaded WASM)
    ├── unrar.*           # RAR extraction (CBR support)
    ├── fflate.mjs        # zip writer
    └── music-metadata.mjs # audio tag/chapter parser (ESM bundle)
```

## Notes & limitations

- **CBR** files are unpacked in-browser (RAR WASM) and repacked as CBZ; very large archives are memory-bound.
- **MOBI/AZW3** support is via foliate-js; DRM-locked files cannot be opened.
- **Piper TTS** requires `wasm-unsafe-eval` (already in the CSP) and downloads voice models from Hugging Face on first use per voice.
- **KFX** (Kindle) files are DRM-locked containers and are rejected on import with an explanation rather than a generic failure.
- **A native iOS app** lives in `ios/` (SwiftUI on the Readium toolkit, built as an unsigned IPA by `.github/workflows/ios.yml`); see `AGENTS.md`. The PWA remains the supported install route.
- **iCloud Drive**: there is no iCloud web API for PWAs, but the iOS file and folder pickers already browse iCloud Drive natively — Import → Files/Folder, then choose iCloud Drive under Locations. On desktop, an iCloud for Windows/macOS synced folder works through Folder import the same way.
- **Google Drive**: Import → Google Drive opens a folder browser (My Drive + Shared with me), multi-select, and downloads straight into the import pipeline. It needs an OAuth client ID — Google won't issue tokens without one. Setup: Google Cloud Console → new project → enable *Google Drive API* → Credentials → *OAuth client ID* (Web application) → add `https://pageturner.pages.dev` to Authorized JavaScript origins → paste the ID into `GOOGLE_CLIENT_ID` in `docs/js/gdrive.js`. It's a public identifier, not a secret. Scope is `drive.readonly`; tokens live only in memory.
- **iOS launch images** are generated per device size (iOS only uses an exactly matching `apple-touch-startup-image`), portrait only. `npm run icons` writes both the PNGs and the `<link>` tags between the `launch-images` markers in `index.html`.
- **Backups** are plain zips of stored entries (books and audio are already compressed), with ZIP64 for libraries or files over 4 GiB. `docs/js/zip.js` assembles the archive by reference from IndexedDB's Blobs, so exporting never copies the library into memory, and restores through the central directory with `Blob.slice()`. Archives open in any unzip tool; backups from earlier versions (deflated) still restore.
- **Neural voices stay on the device.** Choosing a voice downloads it once (about 60 MB) with its engine files; Settings → Saved voices lists what's kept, with sizes, and removes voices. Voices are stored in the Cache API — upstream piper-tts-web used OPFS `createWritable()`, which Safari lacks, so on iPhone and iPad nothing was ever saved and the voice re-downloaded every session (patched in `scripts/patch-piper.js`, so it survives `npm run vendor`). The service worker now retires only its own versioned caches, keeps engine binaries in `pageturner-engines` across updates, and re-checks them with a conditional request when a new version activates.
- **Read-aloud memory on iOS.** The Piper phonemizer is an Emscripten program whose `callMain()` pushes its arguments (the sentence included) onto the WebAssembly stack and never pops them. It's meant to run once, so reusing one instance per session ran `main()` off the end of the stack after ~100 sentences, and iOS closed the page ("A problem repeatedly occurred"). `scripts/patch-piper.js` restores the stack pointer after each call, drops an instance that fails anyway, and adds `TtsSession.release()` so a voice that's switched away from or previewed gives its ONNX memory back (it used to stay resident, ~60–110 MB a voice). `tests/piper-patch.test.js` runs 400 sentences through one phonemizer. The Kokoro HQ voice isn't offered on iPhone and iPad even where WebGPU exists: its ~330 MB fp32 model is more than iOS lets a page hold.
- **Automatic metadata** only applies a match whose core title is identical (and whose author agrees, when both are known). A title that merely contains yours — "The Salt Road" vs "The Salt Roads" — is left for the manual picker rather than silently giving the book someone else's cover.
- **Light theme contrast:** the amber accent is used as a fill; text and icons on light surfaces use a deeper amber (`--accent-ink`, ≥4.6:1).
- **Storage** is the browser's. Settings → About warns when the quota is nearly full or persistent storage wasn't granted; an exported backup is the only copy that survives the browser clearing site data.
- The manifest has no `screenshots`, so Android/desktop install prompts show the plain variant.
- **Rotation** re-renders PDF pages (their canvases are sized when drawn) and restores the reading fraction in the text renderer, whose scroll offset is absolute. EPUBs reflow through foliate's own `ResizeObserver`.
