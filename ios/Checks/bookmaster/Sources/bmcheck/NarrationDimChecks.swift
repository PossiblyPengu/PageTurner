import Foundation

/// "Dim the screen while it reads": how far down, and when the light is given back (`NarrationDim`).
func runNarrationDimChecks() {
    section("Dimming the screen while it reads")
    check("a full screen goes down to about a third", abs(NarrationDim.dimmed(from: 1) - 0.35) < 1e-9, "\(NarrationDim.dimmed(from: 1))")
    check("half goes down to under a fifth", abs(NarrationDim.dimmed(from: 0.5) - 0.175) < 1e-9, "\(NarrationDim.dimmed(from: 0.5))")
    check("never below a level the page can be made out at", NarrationDim.dimmed(from: 0.1) == 0.05, "\(NarrationDim.dimmed(from: 0.1))")
    check("never brighter than it was", NarrationDim.dimmed(from: 0.03) == 0.03, "\(NarrationDim.dimmed(from: 0.03))")
    check("a screen already at its lowest is left alone", !NarrationDim.worthDimming(0.05) && !NarrationDim.worthDimming(0))
    check("a lit screen is worth dimming", NarrationDim.worthDimming(0.6))
    check("odd values are held to 0…1", NarrationDim.dimmed(from: 4) == 0.35 && NarrationDim.dimmed(from: -1) == 0)
    check("NaN is not dimmed", !NarrationDim.worthDimming(.nan))
    // the light given back
    check("left where it was turned down to: the old brightness comes back",
          NarrationDim.restored(saved: 0.8, applied: 0.28, now: 0.28) == 0.8)
    check("a rounding of the level still counts as untouched",
          NarrationDim.restored(saved: 0.8, applied: 0.28, now: 0.2801) == 0.8)
    check("moved since (Control Center, auto-brightness): theirs stands",
          NarrationDim.restored(saved: 0.8, applied: 0.28, now: 0.6) == nil)
    check("nothing odd is handed back", NarrationDim.restored(saved: .nan, applied: 0.28, now: 0.28) == nil)
}
