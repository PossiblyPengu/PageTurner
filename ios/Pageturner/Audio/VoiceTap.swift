import AVFoundation
import MediaToolbox

/// Puts `VoiceDSP` into the audio path of a playing item: a processing tap on its audio track sees every block
/// just before it is heard.
final class VoiceTap {
    /// Shared with the audio thread: written from the main thread when a switch is turned, read per block.
    final class State {
        var dsp = VoiceDSP()
        var planar = true
        var supported = true
        /// The audio has been quiet for a moment (read by the main thread, written by the audio thread).
        var inSilence: Bool { dsp.inSilence }
        /// Told when `inSilence` flips — runs on the realtime audio thread, so reply, don't work.
        var onSilenceChange: ((Bool) -> Void)?
        /// What `onSilenceChange` last reported (audio thread only) — the flip alone is worth a call.
        var lastInSilence = false
    }

    let state = State()

    /// The audio mix that taps `track`, or nil if the tap cannot be made.
    func makeMix(for track: AVAssetTrack) -> AVAudioMix? {
        let retained = Unmanaged.passRetained(state)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, clientInfo, storage in
                storage.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                state.dsp.sampleRate = description.mSampleRate
                // only 32-bit float audio is processed; anything else passes through untouched
                state.supported = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && description.mBitsPerChannel == 32
                state.planar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard state.supported, state.dsp.boost || state.dsp.trim else { return }
                var planes: [UnsafeMutableBufferPointer<Float>] = []
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    planes.append(UnsafeMutableBufferPointer(start: data, count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
                }
                state.dsp.process(planes, frames: Int(framesOut.pointee))
                let silent = state.inSilence
                if silent != state.lastInSilence {
                    state.lastInSilence = silent
                    state.onSilenceChange?(silent)
                }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            retained.release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
