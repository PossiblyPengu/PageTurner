import Foundation

/// The pace a neural voice makes a sentence at, for the speed it is listened to at. Pure, so it is checked on Linux.
///
/// A sentence used to be made at the voice's own pace and sped up by the player's time-stretch: at 1.5× the voice made
/// half as much sound again as was heard, every sentence, for as long as it read — and the stretch ran on every sample
/// besides. VITS can be asked to speak faster, and its cost goes with the sound it makes. It does not speed up by exactly
/// what it is asked (each sound's length is rounded up to a whole frame and the short gaps between sounds stay as they
/// are, so 1.5× comes out nearer 1.4×), so what a pace really gives is measured once per voice and pace on a sample
/// (`NeuralSynth.calibrate`), and the player stretches by what is left (`stretch`), keeping the speed exact.
enum NeuralPace {
    /// The fastest a voice is asked to speak itself; beyond it, the player's stretch does the rest. VITS asked for much
    /// more than this starts to slur.
    static let fastest: Double = 1.75

    /// The pace to make a sentence at for `speed`: the quarter step at or below it, from 1.25 to `fastest`. Below
    /// 1.25 the voice makes its own pace and the player stretches (a slower voice would make more sound, not less).
    static func made(for speed: Double) -> Double {
        guard speed.isFinite, speed >= 1.25 else { return 1 }
        return min((speed * 4).rounded(.down) / 4, fastest)
    }

    /// sherpa-onnx's `speed` argument for a pace: it sets length_scale = 1 / speed and forgets the voice's own, so the
    /// voice's is put back in.
    static func sherpaSpeed(pace: Double, lengthScale: Double) -> Double {
        max(pace, 0.1) / max(lengthScale, 0.1)
    }

    /// How much faster a pace really made the sample than the voice's own: nil when it made no worthwhile
    /// difference (or the measurement is nonsense), and never more than a little over what was asked.
    static func achieved(natural: Double, made: Double, asked pace: Double) -> Double? {
        guard natural.isFinite, made.isFinite, pace.isFinite, natural > 0, made > 0 else { return nil }
        let ratio = natural / made
        guard ratio > 1.03 else { return nil }
        return min(ratio, pace * 1.05)
    }

    /// What the player stretches a sentence by, made `achieved` times faster than the voice's own pace, so that it is
    /// heard at `speed`.
    static func stretch(speed: Double, achieved: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 1 }
        guard achieved.isFinite, achieved > 0 else { return speed }
        return speed / achieved
    }
}
