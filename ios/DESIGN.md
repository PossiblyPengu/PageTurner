# Pageturner — Liquid Glass design plan

Target: the iOS 26 design language (Liquid Glass), with plain-material fallbacks
down to the iOS 17 deployment target. Built with Xcode 26, so system controls
(navigation bars, toolbars, tab bars, sheets, menus, alerts) pick up the glass
look on their own. Custom glass is added only where the system doesn't supply
it: floating reader chrome, the mini player, the library's hero card.

## Rules

1. **Let the system do it.** Prefer `NavigationStack` + `.toolbar`, `TabView`,
   `.sheet`, `Menu`, `List`/`Form` over custom bars. Don't put `.background`
   or `.toolbarBackground` on system bars — that fights the glass.
2. **Glass is for controls floating above content**, never for content itself
   and never stacked on other glass. Group neighbouring glass in one
   `GlassEffectContainer` so it blends and morphs together.
3. **One helper, no `#available` at call sites.** `Design/Glass.swift` holds the
   modifiers (`.pageturnerGlass(in:)`, `GlassButtonStyle`, `GlassGroup`), which
   use `glassEffect` on iOS 26 and `.ultraThinMaterial` before it.
4. **Content goes edge to edge** and scrolls under the bars; use
   `.scrollEdgeEffectStyle` rather than hard backgrounds.
5. **Colour comes from the cover.** The accent is BookMaster's terracotta
   (`#cd844f` dark / `#a0532a` light); Now Playing and the book detail tint
   from the cover's dominant colour.
6. Dynamic Type, VoiceOver labels and Reduce Transparency must keep working:
   no fixed-height text, every icon-only button has an `accessibilityLabel`.

## Structure

```
TabView                       (iOS 26: minimises on scroll, mini player docks above it)
├─ Reading      the book you are in (Continue card, time left) and the others you have begun — one tap back in
├─ Library      NavigationStack: shelf chips · filter (All / Books / Audiobooks) · status · cover grid
├─ BookMaster   tracking: this phone's reading time always; linked: streak, goals, achievements, shelf, partner, suggestions — badge = suggestions waiting
└─ Search       role: .search — library search, books and audiobooks
tabViewBottomAccessory:  mini player (audiobook or read-aloud) → tap opens Now Playing sheet;
  before iOS 26 the same strip rides as a floating glass capsule in a bottom safe-area inset instead
Settings:  gear in the Library toolbar → sheet (BookMaster, read-aloud voice, speed and highlights, watched folder, backup)
```

## Screens

| Screen | Liquid Glass treatment |
|---|---|
| Library | Grid under a glass nav bar; hero "Continue" card; progress ring on covers |
| Book detail | Large cover, tinted backdrop (`backgroundExtensionEffect`), glass action buttons (Read / Listen) |
| Reader | Content full bleed. Top: back button, title capsule, grouped actions (contents, search, bookmark) as glass. Bottom: floating glass bar — text settings, read aloud, position scrubber. Tap toggles both. |
| Now Playing | Cover-tinted backdrop, large art, glass transport cluster in one container, speed/sleep as glass menus |
| Mini player | `tabViewBottomAccessory`: art, title, play/pause, skip |
| Sheets | System detents; toolbar buttons use system glass; `Form` for settings |

## Phases (each one ends with a green macOS build) — all done

A ✅ B ✅ C ✅ D ✅ E ✅ F ✅ (see git history on `claude/native-overhaul`).

Since then: the reader's footer carries a draggable position scrubber, the reader's chrome follows the page's
light/dark theme (`preferredColorScheme`), and a **Back** chip floats above the footer after a jump.

Not done: cover-tinted backdrops for the reader. A device pass is still owed — the CI simulator run
(`.github/workflows/ios-sim.yml`) photographs every screen from a Debug build, which is the nearest thing to
looking at it, but it is not a device.

- **A** `Design/Glass.swift` helpers; SDK probe confirms the API names.
- **B** App shell: `TabView`, Settings sheet, playback hoisted out of the full-screen
  view so audio survives leaving the player (needed for the mini player).
- **C** Library and book detail.
- **D** Reader chrome.
- **E** Now Playing and mini player.
- **F** Sheets, empty and error states, accessibility pass.

Nothing here can be seen from the Linux machine this is written on — there is
no simulator. Visual checks happen on a device from the CI-built IPA.
