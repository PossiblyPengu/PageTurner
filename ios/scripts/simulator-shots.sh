#!/bin/bash
# Run the Debug build in the iOS Simulator and photograph every screen.
#   simulator-shots.sh <udid> <path to Pageturner.app> <output dir>
# Each screen is a launch of the app with -PTDebugScreen (see Debug/DebugScenario.swift,
# compiled in Debug builds only). Also the first time the app is executed anywhere, so
# it reports whether it stayed alive and collects crash reports and the app's log.
set -u
UDID=$1; APP=$2; OUT=$3
BUNDLE=io.github.possiblypengu.pageturner
mkdir -p "$OUT/logs"
FAILED=0

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl ui "$UDID" appearance light 2>/dev/null || true
xcrun simctl install "$UDID" "$APP" || { echo "::error::install failed"; exit 1; }

alive() {
  # launchctl lists the app as "<pid> <status> UIKitApplication:<bundle>[…]" while it runs
  local pid
  pid=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep "UIKitApplication:$BUNDLE" | awk '{print $1}' | head -1)
  [[ "$pid" =~ ^[0-9]+$ ]]
}

# shot <name> <seconds to wait> [launch args…]
shot() {
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  local started; started=$(date +%s)
  xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null 2>&1 || { echo "::warning::launch failed for $name"; FAILED=1; }
  sleep "$wait"
  if alive; then
    xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1 || echo "::warning::no screenshot for $name"
    echo "ok     $name"
  else
    echo "::error::the app is not running after launching $name"
    FAILED=1
    xcrun simctl io "$UDID" screenshot "$OUT/$name-DEAD.png" >/dev/null 2>&1 || true
  fi
  xcrun simctl spawn "$UDID" log show --style compact --last "$(( $(date +%s) - started + 5 ))s" \
    --predicate 'process == "Pageturner"' 2>/dev/null | tail -n 150 > "$OUT/logs/$name.txt" || true
}

# probe <name> <seconds to wait> [launch args…]: an experiment — logs are kept, but the app dying
# (or finding nothing) is reported, never failed on
probe() {
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  local started; started=$(date +%s)
  xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null 2>&1 || echo "::warning::launch failed for $name"
  sleep "$wait"
  alive && echo "ok     $name (still running)" || echo "::warning::the app is not running after the $name probe"
  xcrun simctl spawn "$UDID" log show --style compact --last "$(( $(date +%s) - started + 5 ))s" \
    --predicate 'process == "Pageturner"' 2>/dev/null | tail -n 400 > "$OUT/logs/$name.txt" || true
}

# first launch: an empty library
shot 01-empty 6

# seeded library (the first launch with -PTDebugSeed fills it; later launches reuse it)
shot 02-library 26 -PTDebugSeed 1 -PTDebugScreen library
shot 03-detail 6 -PTDebugScreen detail
shot 04-edit 6 -PTDebugScreen edit
shot 05-shelves 6 -PTDebugScreen shelves
shot 06-stats 6 -PTDebugScreen stats
shot 07-together 6 -PTDebugScreen together
shot 72-reading-now 8 -PTDebugScreen reading
shot 70-bookmaster 8 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen together
shot 71-bookmaster-shelf 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen shelf
shot 73-bookmaster-progress 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmprogress
shot 74-bookmaster-together 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmtogether
shot 75-bookmaster-quotes 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmquotes
shot 76-bookmaster-discover 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmdiscover
shot 77-bookmaster-find 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmsearch
shot 78-bookmaster-wrapped 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmwrapped
shot 79-bookmaster-book 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen bmbook
shot 08-search 6 -PTDebugScreen search
shot 09-settings 6 -PTDebugScreen settings
# the settings list as a linked reader sees it (the BookMaster suite rows), and the pages behind it
shot 09a-settings-linked 8 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen settings
shot 09b-settings-bookmaster 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen settings -PTDebugSettingsPush bookmaster
shot 09c-settings-notifications 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen settings -PTDebugSettingsPush notifications
shot 09d-settings-chat 10 -PTDebugSeed 1 -PTDebugLinked 1 -PTDebugScreen settings -PTDebugSettingsPush chat
shot 09e-settings-reading 10 -PTDebugScreen settings -PTDebugSettingsPush reading
shot 09f-settings-library 10 -PTDebugScreen settings -PTDebugSettingsPush library
shot 09g-settings-backup 10 -PTDebugScreen settings -PTDebugSettingsPush backup
shot 10-player 8 -PTDebugScreen player
shot 10b-player-chapters 12 -PTDebugScreen player -PTDebugPlayerSheet chapters
shot 11-reader 14 -PTDebugScreen reader -PTDebugKeepChrome 1
shot 12-reader-contents 14 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet contents
shot 13-reader-settings 14 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet settings
shot 14-reader-search 14 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet search
# no flag: the controls step aside on their own a few seconds after the book opens
shot 80-page-flip 20 -PTDebugScreen reader -PTDebugTurn flip
shot 81-page-curl 20 -PTDebugScreen reader -PTDebugTurn curl
shot 15-reader-autohide 14 -PTDebugScreen reader
shot 16-reader-jump 18 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet jump
shot 17-reader-footnote 14 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet footnote
shot 18-reader-highlight 14 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet highlight
shot 19-resume-prompt 8 -PTDebugScreen resume
shot 19b-library-select 10 -PTDebugScreen library -PTDebugLibraryMode select
# BookMaster's sign-in sheet: the real site, and then the redirect home intercepted — a data: page
# sends the web view to the return address with a made-up code, so the app should close the sheet,
# try to spend the code and report that BookMaster refused it
shot 50-link-sheet 20 -PTDebugScreen link
shot 51-link-intercept 18 -PTDebugScreen link -PTDebugLinkStart "data:text/html,%3Cscript%3Elocation.replace('https://pageturner.pages.dev/?bm-link=0123456789abcdef0123456789abcdef')%3C/script%3E"
# read-aloud voices: the voice list pushed from Settings → Read Aloud, and the reader's voice sheet
shot 52-voices 12 -PTDebugScreen settings -PTDebugSettingsPush voices
shot 53-reader-voices 16 -PTDebugScreen reader -PTDebugKeepChrome 1 -PTDebugReaderSheet voices
# the other two readers: a PDF (and Readium's own search through it) and a CBZ comic
shot 40-pdf 14 -PTDebugScreen pdf -PTDebugKeepChrome 1
shot 41-pdf-search 20 -PTDebugScreen pdf -PTDebugKeepChrome 1 -PTDebugReaderSheet pdfsearch
shot 42-cbz 14 -PTDebugScreen cbz -PTDebugKeepChrome 1

# dark
xcrun simctl ui "$UDID" appearance dark 2>/dev/null || true
shot 20-dark-library 8 -PTDebugScreen library
shot 21-dark-stats 6 -PTDebugScreen stats
shot 22-dark-player 8 -PTDebugScreen player
shot 23-dark-reader 14 -PTDebugScreen reader -PTDebugKeepChrome 1
shot 24-dark-settings 6 -PTDebugScreen settings
shot 25-dark-voices 12 -PTDebugScreen settings -PTDebugSettingsPush voices
xcrun simctl ui "$UDID" appearance light 2>/dev/null || true

# large text
xcrun simctl ui "$UDID" content_size accessibility-extra-large 2>/dev/null || true
shot 30-large-library 8 -PTDebugScreen library
shot 31-large-stats 6 -PTDebugScreen stats
shot 32-large-settings 6 -PTDebugScreen settings
shot 33-large-player 8 -PTDebugScreen player
shot 34-large-voices 12 -PTDebugScreen settings -PTDebugSettingsPush voices
xcrun simctl ui "$UDID" content_size large 2>/dev/null || true

# neural voices: download one inside the simulator, make a sentence with it on sherpa-onnx (Piper on
# ONNX Runtime) and check there was speech — then the Neural tab, with that voice saved
shot 55-neural-probe 120 -PTDebugNeuralProbe en_US-lessac-low
xcrun simctl spawn "$UDID" log show --style compact --last 15m \
  --predicate 'process == "Pageturner" AND eventMessage CONTAINS "PTNeuralProbe"' > "$OUT/neural-probe.txt" 2>/dev/null || true
cat "$OUT/neural-probe.txt"
grep -q "PTNeuralProbe ok" "$OUT/neural-probe.txt" || { echo "::error::the neural voice probe did not report ok"; FAILED=1; }
shot 56-neural-list 12 -PTDebugScreen settings -PTDebugSettingsPush voices -PTDebugVoiceSource neural

# read-aloud on the page: what each highlight option looks like while the voice speaks — with the
# voice iOS ships with, and with the neural voice that was just downloaded (its word positions are
# worked out from the sound). The log lists the words the voice reported.
RA="-PTDebugScreen reader -PTDebugReaderSheet readaloud -PTDebugKeepChrome 1"
shot 60-readaloud-all 20 $RA -PTDebugHighlights sentence,line,word
xcrun simctl spawn "$UDID" log show --style compact --last 2m \
  --predicate 'process == "Pageturner" AND eventMessage CONTAINS "PTReadAloud"' > "$OUT/readaloud-device.txt" 2>/dev/null || true
shot 61-readaloud-word 20 $RA -PTDebugHighlights word
shot 62-readaloud-line 20 $RA -PTDebugHighlights line
shot 63-readaloud-sentence 20 $RA -PTDebugHighlights sentence
shot 64-readaloud-neural 30 $RA -PTDebugVoice neural -PTDebugHighlights sentence,line,word
xcrun simctl spawn "$UDID" log show --style compact --last 2m \
  --predicate 'process == "Pageturner" AND eventMessage CONTAINS "PTReadAloud"' > "$OUT/readaloud-neural.txt" 2>/dev/null || true
shot 65-readaloud-neural-word 30 $RA -PTDebugVoice neural -PTDebugHighlights word
shot 66-readaloud-autohide 20 -PTDebugScreen reader -PTDebugReaderSheet readaloud -PTDebugHighlights sentence,line,word
# the scrolling layout's follow: the spoken line should sit mid-screen, not at the chapter's end
shot 67-readaloud-scroll 20 $RA -PTDebugReaderScroll 1 -PTDebugHighlights sentence,line,word

# crash reports from the host (the simulator writes them there)
mkdir -p "$OUT/crashes"
find ~/Library/Logs/DiagnosticReports -name 'Pageturner*' -newer "$APP" -exec cp {} "$OUT/crashes/" \; 2>/dev/null || true
if ls "$OUT/crashes"/* >/dev/null 2>&1; then echo "::error::crash reports found"; FAILED=1; fi

# experiments that can take the app down in a simulator with no sound hardware: their crash
# reports are kept apart and never fail the run
mkdir -p "$OUT/probe-crashes"
MARK=$(mktemp)
# what AVSpeechSynthesizer does at each speaking rate (the scale in SpeechRateMap), and playing a
# neural voice through AVAudioEngine
probe 58-speech-probe 100 -PTDebugSpeechProbe 1
xcrun simctl spawn "$UDID" log show --style compact --last 10m \
  --predicate 'process == "Pageturner" AND eventMessage CONTAINS "PTSpeechProbe"' > "$OUT/speech-probe.txt" 2>/dev/null || true
probe 59-neural-play 60 -PTDebugNeuralProbe en_US-lessac-low -PTDebugNeuralPlay 1
find ~/Library/Logs/DiagnosticReports -name 'Pageturner*' -newer "$MARK" -exec cp {} "$OUT/probe-crashes/" \; 2>/dev/null || true
if ls "$OUT/probe-crashes"/* >/dev/null 2>&1; then echo "::warning::a probe crashed the app (see probe-crashes)"; fi

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
exit $FAILED
