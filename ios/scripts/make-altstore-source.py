#!/usr/bin/env python3
"""Write an AltStore / SideStore source (altstore.json) for a built Pageturner.ipa.

usage: make-altstore-source.py <Pageturner.ipa> <owner/repo> <download-url> <out.json> [variant]
                               [--alias-url URL] [--notes FILE] [--previous FILE] [--news-url URL]
                               [--source-url URL]

`variant` distinguishes parallel channels ("" for nightly, "stable" for tagged releases) so a
source added for each doesn't share one identifier inside SideStore.

`download-url` is the immutable URL of *this* build's IPA (its release tag) — it's what the new
`versions` entry keeps. `--alias-url` is the rolling alias (ios-latest / ios-stable) the app-level
fields point at, so SideStore's quick fields always fetch the newest build. `--previous` merges the
published source's `versions`/`news` forward (newest first, capped) so the source grows a real
history instead of a single row. Entries from before this existed point at a rolling alias — they
would install today's IPA under an old version's name, so they're dropped. `--notes` is the "what's
new" text for this version and its news item. `--news-url` is where a tap on the news item goes.
`--source-url` is the feed's own canonical address (SideStore uses it to re-fetch faster).

The version, build number, minimum iOS and bundle id are read from the IPA itself, so the source can never
disagree with the file it points at — and the `privacy` map is every NS*UsageDescription key in its
Info.plist, because AltStore checks the list against the download and refuses a mismatch.
SideStore reads the app-level fields, AltStore the `versions` list; both are written.
"""
import json
import plistlib
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

args, flags = [], {}
i = 1
while i < len(sys.argv):
    if sys.argv[i].startswith("--"):
        if i + 1 < len(sys.argv):
            flags[sys.argv[i]] = sys.argv[i + 1]
        i += 2
    else:
        args.append(sys.argv[i])
        i += 1

ipa, repo, download_url, out = args[0:4]
variant = args[4] if len(args) > 4 else ""
alias_url = flags.get("--alias-url", download_url)
previous = flags.get("--previous")
news_url = flags.get("--news-url", f"https://github.com/{repo}/releases")
source_url = flags.get("--source-url")
notes_file = flags.get("--notes")

SITE = "https://pageturner.pages.dev"
SCREENSHOTS = ["ios/library.png", "ios/detail.png", "ios/reader.png"]

with zipfile.ZipFile(ipa) as z:
    damaged = z.testzip()
    if damaged:
        raise ValueError(f"Damaged IPA entry: {damaged}")
    name = next(n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2)
    info = plistlib.loads(z.read(name))
version = info["CFBundleShortVersionString"]
build = str(info["CFBundleVersion"])
bundle = info["CFBundleIdentifier"]
minos = info.get("MinimumOSVersion", "17.0")
# AltStore checks this map against the installed IPA and refuses a mismatch — take the real keys.
privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

size = Path(ipa).stat().st_size
date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
raw = f"https://raw.githubusercontent.com/{repo}/main"
description = (
    "A reader and audiobook player for your own book files — EPUB, PDF, comics and audiobooks — with neural and "
    "device read-aloud voices and word, line and sentence highlighting. BookMaster tracks your reading."
)
notes = f"Build {build}. See the repository for what changed."
if notes_file:
    text = Path(notes_file).read_text().strip()
    if text:
        notes = text[:1200]
first_line = next((l for l in notes.splitlines() if l.strip() and not l.startswith("#")), "")
caption = (first_line or f"{version} · build {build}")[:140]

entry = {
    "version": version,
    "buildVersion": build,
    "date": date,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": size,
    "minOSVersion": minos,
}
versions = [entry]
news = [{
    "title": f"Pageturner {version}" + ("" if variant == "stable" else f" build {build}"),
    "identifier": f"{variant or 'nightly'}-{build}",
    "caption": caption,
    "date": date,
    "notify": variant == "stable",
    "url": news_url,
    "appID": bundle,
}]
if previous:
    try:
        old = json.loads(Path(previous).read_text())
        seen = {(version, build)}
        for v in old.get("apps", [{}])[0].get("versions", []):
            key = (v.get("version"), str(v.get("buildVersion")))
            # legacy entries point at the rolling alias — under an old name they would install today's IPA
            rolling = "/ios-latest/" in v.get("downloadURL", "") or "/ios-stable/" in v.get("downloadURL", "")
            if key not in seen and not rolling:
                seen.add(key)
                versions.append(v)
            if len(versions) >= 15:
                break
        old_ids = {n["identifier"] for n in news}
        for n in old.get("news", []):
            if n.get("identifier") not in old_ids:
                old_ids.add(n["identifier"])
                news.append(n)
            if len(news) >= 10:
                break
    except Exception as e:
        print(f"warning: could not merge previous source ({e}) — starting the history fresh", file=sys.stderr)

app = {
    "name": "Pageturner",
    "bundleIdentifier": bundle,
    "developerName": repo.split("/")[0],
    "subtitle": "Read and listen to your own books",
    "localizedDescription": description,
    "iconURL": f"{raw}/ios/Pageturner/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    "tintColor": "A0532A",
    "category": "entertainment",
    "screenshots": [f"{SITE}/{s}" for s in SCREENSHOTS],
    # SideStore reads these…
    "version": version,
    "versionDate": date,
    "versionDescription": notes,
    "downloadURL": alias_url,
    "size": size,
    # …AltStore reads this
    "versions": versions,
    "appPermissions": {"entitlements": [], "privacy": privacy},
}
source = {
    "name": "Pageturner" + (f" ({variant})" if variant else ""),
    "identifier": f"{bundle}.source" + (f".{variant}" if variant else ""),
    "subtitle": "Updates for Pageturner",
    "description": "Pageturner builds, published from GitHub Actions.",
    "iconURL": f"{raw}/ios/Pageturner/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    "tintColor": "A0532A",
    "website": f"https://github.com/{repo}",
    "apps": [app],
    "news": news,
}
if source_url:
    source["sourceURL"] = source_url   # SideStore: re-fetch the feed from its canonical address
Path(out).write_text(json.dumps(source, indent=2) + "\n")
print(f"{bundle} {version} ({build}), {size} bytes, {len(versions)} version(s), privacy {sorted(privacy)} -> {out}")
