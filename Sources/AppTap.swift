import AudioToolbox
import CoreAudio
import Foundation

/// Shared between the UI thread (writes) and the real-time audio thread (reads).
/// A single aligned Float store/load is effectively atomic on arm64/x86_64.
final class GainBox: @unchecked Sendable {
    var target: Float
    var current: Float
    init(_ g: Float) { target = g; current = g }
}

/// Captures the audio of a set of processes (one "app"), mutes the original,
/// and re-plays it to the output device with an adjustable gain.
///
/// Pipeline: process tap (muted at source) -> private aggregate device
/// [output device + tap] -> IOProc copies tap input to device output * gain.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputUID: String
    let gain: GainBox

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.gain = GainBox(gain)
        do { try start() } catch { stop(); throw error }
    }

    deinit { stop() }

    private func start() throws {
        // 1. Tap the app's audio and silence the original stream.
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = "Faders tap"
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "Create process tap")

        // 2. Private aggregate device = real output device + the tap as an input.
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faders",
            kAudioAggregateDeviceUIDKey: "faders-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Create aggregate device")

        // 3. Real-time render callback.
        let gain = self.gain
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inData, _, outData, _ in
            AppTap.render(input: inData, output: outData, gain: gain)
        }, "Create IOProc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Start device")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Real-time DSP (no allocation, no locks)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: GainBox) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)

        // The tap's stream(s) come after any input streams of the output device,
        // so take them from the end. Stereo mixdown is normally 1 interleaved
        // 2-channel buffer; handle 2 mono buffers too.
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
        var inStride = 1
        var inFrames = 0
        if let last = ins.last, let p = last.mData?.assumingMemoryBound(to: Float.self) {
            let ch = Int(max(1, last.mNumberChannels))
            if ch >= 2 {
                left = p; right = p + 1; inStride = ch
                inFrames = Int(last.mDataByteSize) / (4 * ch)
            } else if ins.count >= 2, let lp = ins[ins.count - 2].mData?.assumingMemoryBound(to: Float.self),
                      ins[ins.count - 2].mNumberChannels == 1 {
                left = lp; right = p
                inFrames = Int(last.mDataByteSize) / 4
            } else {
                left = p; right = p
                inFrames = Int(last.mDataByteSize) / 4
            }
        }

        let target = gain.target
        var channelBase = 0
        var endGain = gain.current
        for buf in outs {
            guard let dst = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(max(1, buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / (4 * ch)
            let n = min(frames, inFrames)
            var g = gain.current
            if let left, let right {
                for f in 0..<n {
                    g += (target - g) * 0.002 // ~10ms smoothing, avoids zipper noise
                    let l = left[f * inStride], r = right[f * inStride]
                    for c in 0..<ch {
                        let s = ((channelBase + c) & 1) == 0 ? l : r
                        dst[f * ch + c] = softClip(s * g)
                    }
                }
            }
            if n < frames { (dst + n * ch).update(repeating: 0, count: (frames - n) * ch) }
            channelBase += ch
            endGain = g
        }
        gain.current = endGain
    }

    /// Linear up to 0.9, then smoothly saturates toward 1.0 so boosting past 100% doesn't crackle.
    @inline(__always) private static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.9 { return x }
        let y = 0.9 + 0.1 * tanhf((a - 0.9) / 0.1)
        return x < 0 ? -y : y
    }
}
