import Foundation

/// The pace a neural voice makes a sentence at for a listening speed, and what the player stretches by (`NeuralPace`).
func runNeuralPaceChecks() {
    section("Neural voices: made at the pace they are heard")
    check("at its own pace or slower, the voice makes its own pace", NeuralPace.made(for: 1) == 1 && NeuralPace.made(for: 0.8) == 1)
    check("just over 1× is not worth asking for", NeuralPace.made(for: 1.2) == 1)
    check("1.25× and 1.5× are asked for as they are", NeuralPace.made(for: 1.25) == 1.25 && NeuralPace.made(for: 1.5) == 1.5)
    check("in between, the quarter step below", NeuralPace.made(for: 1.6) == 1.5 && NeuralPace.made(for: 1.74) == 1.5)
    check("never faster than the voice can say well", NeuralPace.made(for: 3) == NeuralPace.fastest)
    check("nonsense speeds make the voice's own pace", NeuralPace.made(for: .nan) == 1 && NeuralPace.made(for: .infinity) == 1)
    // sherpa's argument keeps the voice's own length scale
    check("the voice's own scale is kept at its own pace", abs(NeuralPace.sherpaSpeed(pace: 1, lengthScale: 1.25) - 0.8) < 1e-12)
    check("and at 1.5×", abs(NeuralPace.sherpaSpeed(pace: 1.5, lengthScale: 1.25) - 1.2) < 1e-12)
    // what a pace gives, from the sample made both ways
    check("10 s made in 7.25 s is 1.38× faster", abs((NeuralPace.achieved(natural: 10, made: 7.25, asked: 1.5) ?? 0) - 10 / 7.25) < 1e-12)
    check("a pace that made no difference is not used", NeuralPace.achieved(natural: 10, made: 9.9, asked: 1.5) == nil)
    check("a reading faster than asked is held to a little over it",
          NeuralPace.achieved(natural: 10, made: 4, asked: 1.5) == 1.5 * 1.05)
    check("nothing made is no reading", NeuralPace.achieved(natural: 10, made: 0, asked: 1.5) == nil
              && NeuralPace.achieved(natural: .nan, made: 5, asked: 1.5) == nil)
    // the player's stretch keeps the speed exact
    check("made 1.38× faster, heard at 1.5×: stretched by the rest", abs(NeuralPace.stretch(speed: 1.5, achieved: 1.38) * 1.38 - 1.5) < 1e-12)
    check("made at its own pace: stretched by the whole speed", NeuralPace.stretch(speed: 1.5, achieved: 1) == 1.5)
    check("made faster, heard slower after a change of speed: slowed down", NeuralPace.stretch(speed: 1, achieved: 1.38) < 1)
    check("odd values fall back to the speed", NeuralPace.stretch(speed: 1.5, achieved: 0) == 1.5
              && NeuralPace.stretch(speed: .nan, achieved: 1.2) == 1)
}
