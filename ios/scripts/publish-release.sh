#!/usr/bin/env bash
set -euo pipefail

OUT=${1:?Pass the directory containing Pageturner.ipa}
SHA=${2:?Pass the build commit}
RUN=${3:?Pass the build run id}
: "${REPO:?Set REPO to owner/repo}"
[[ "$RUN" =~ ^[0-9]+$ ]] || { echo "Invalid build run id" >&2; exit 1; }

TAG="ios-build-$RUN"
URL="https://github.com/$REPO/releases/download/$TAG/Pageturner.ipa"
ALIAS="https://github.com/$REPO/releases/download/ios-latest/Pageturner.ipa"
FEED="https://github.com/$REPO/releases/download/ios-latest/altstore.json"

# the published feed carries the history forward; a missing one just means this is the first
PREV="$OUT/altstore-prev.json"
curl -sfL "$FEED" -o "$PREV" 2>/dev/null || rm -f "$PREV"

NOTES="$OUT/release-notes.md"
{
  echo "Build $RUN · ${SHA:0:7}"
  git log --no-merges --pretty='- %s' -3 "$SHA" 2>/dev/null || true
} > "$NOTES"
cat > "$NOTES.release" <<NOTES
Pageturner from [run $RUN](https://github.com/$REPO/actions/runs/$RUN), commit [${SHA:0:7}](https://github.com/$REPO/commit/$SHA). Unsigned: sideload it, or add the source to AltStore / SideStore for updates.

**Source URL:** https://github.com/$REPO/releases/download/ios-latest/altstore.json

**Build-specific IPA:** $URL
NOTES

python3 "$(dirname "$0")/make-altstore-source.py" "$OUT/Pageturner.ipa" "$REPO" "$URL" "$OUT/altstore.json" \
  --alias-url "$ALIAS" --source-url "$FEED" --notes "$NOTES" \
  --news-url "https://github.com/$REPO/releases/tag/$TAG" \
  $([ -f "$PREV" ] && printf '%s' "--previous $PREV")

# Publish the complete build before touching aliases. Existing source files
# point to build-specific IPAs, so a failed alias replacement cannot break them.
if DRAFT=$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null); then
  if [ "$DRAFT" = true ]; then
    gh release upload "$TAG" "$OUT/Pageturner.ipa" "$OUT/altstore.json" --repo "$REPO" --clobber
  fi
else
  gh release create "$TAG" "$OUT/Pageturner.ipa" "$OUT/altstore.json" --repo "$REPO" \
    --title "Pageturner — build $RUN" --notes-file "$NOTES.release" --prerelease --draft --target "$SHA"
fi
gh release edit "$TAG" --repo "$REPO" --draft=false

if gh release view ios-latest --repo "$REPO" >/dev/null 2>&1; then
  gh release upload ios-latest "$OUT/Pageturner.ipa" --repo "$REPO" --clobber
  gh release upload ios-latest "$OUT/altstore.json" --repo "$REPO" --clobber
  gh release edit ios-latest --repo "$REPO" --title "Pageturner — latest build" --notes-file "$NOTES.release" --prerelease
else
  gh release create ios-latest "$OUT/Pageturner.ipa" "$OUT/altstore.json" --repo "$REPO" \
    --title "Pageturner — latest build" --notes-file "$NOTES.release" --prerelease --target "$SHA"
fi
