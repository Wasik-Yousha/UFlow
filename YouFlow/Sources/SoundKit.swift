import AppKit
import Foundation

/// The mechanical response of the deck.
///
/// Nothing is shipped as an audio file. A latching plastic key is a short noise
/// burst through a low-pass plus a low body tone that drops in pitch as the key
/// seats — that is cheaper to synthesise than to store, and it means the cues
/// can be retuned by editing numbers instead of re-recording samples.
///
/// Every cue is rendered once on first use and cached.
@MainActor
enum SoundKit {

    /// Turned off by the Settings toggle. Nothing else in the app checks this.
    static var isEnabled = true

    private static var cache: [Tok.Sfx: NSSound] = [:]

    static func play(_ sfx: Tok.Sfx) {
        guard isEnabled else { return }
        let sound: NSSound?
        if let cached = cache[sfx] {
            sound = cached
        } else {
            sound = NSSound(data: render(sfx))
            sound?.volume = Tok.Sfx.volume
            cache[sfx] = sound
        }
        // Retrigger rather than overlap: these are UI clicks, not music.
        sound?.stop()
        sound?.play()
    }

    /// Pre-renders every cue so the first key press is not the one that pays
    /// for the synthesis.
    static func warmUp() {
        for sfx in Tok.Sfx.allCases where cache[sfx] == nil {
            let sound = NSSound(data: render(sfx))
            sound?.volume = Tok.Sfx.volume
            cache[sfx] = sound
        }
    }

    // MARK: - Voicing

    /// The whole sound design, as a table. These are the tuning knobs.
    private struct Voice {
        var body: Double          // fundamental, Hz
        var bodyDecay: Double     // seconds to 1/e
        var noise: Double         // burst amplitude, 0...1
        var noiseDecay: Double
        var duration: Double
        var pitchDrop: Double = 0 // fraction of `body` lost over the sound; negative rises
        var damping: Double = 0.5 // one-pole low-pass on the noise, 0 dull ... 1 bright
        var square: Bool = false
    }

    private static func voice(for sfx: Tok.Sfx) -> Voice {
        switch sfx {
        case .recordDown: Voice(body: 96,   bodyDecay: 0.045, noise: 0.55, noiseDecay: 0.012, duration: 0.12,  pitchDrop: 0.35, damping: 0.35)
        case .stopDown:   Voice(body: 150,  bodyDecay: 0.028, noise: 0.70, noiseDecay: 0.008, duration: 0.08,  pitchDrop: 0.30, damping: 0.50)
        case .keyUp:      Voice(body: 300,  bodyDecay: 0.012, noise: 0.50, noiseDecay: 0.005, duration: 0.045, pitchDrop: 0.20, damping: 0.70)
        case .tabSwitch:  Voice(body: 880,  bodyDecay: 0.010, noise: 0.25, noiseDecay: 0.004, duration: 0.040, damping: 0.80)
        case .copy:       Voice(body: 1250, bodyDecay: 0.008, noise: 0.18, noiseDecay: 0.003, duration: 0.032, damping: 0.85)
        case .add:        Voice(body: 620,  bodyDecay: 0.030, noise: 0.20, noiseDecay: 0.006, duration: 0.10,  pitchDrop: -0.55, damping: 0.70)
        case .delete:     Voice(body: 80,   bodyDecay: 0.050, noise: 0.30, noiseDecay: 0.015, duration: 0.13,  pitchDrop: 0.20, damping: 0.25)
        case .error:      Voice(body: 130,  bodyDecay: 0.120, noise: 0.12, noiseDecay: 0.020, duration: 0.20,  damping: 0.30, square: true)
        }
    }

    // MARK: - Rendering

    private static let sampleRate = 44_100.0

    private static func render(_ sfx: Tok.Sfx) -> Data {
        let v = voice(for: sfx)
        let count = Int(v.duration * sampleRate)
        var samples = [Int16](repeating: 0, count: count)

        var phase = 0.0        // integrated, so the pitch can slide
        var lowpass = 0.0      // one-pole state for the noise
        var generator = SystemRandomNumberGenerator()
        let fadeStart = Int(Double(count) * 0.85)

        for i in 0..<count {
            let t = Double(i) / sampleRate
            let progress = t / v.duration

            let frequency = v.body * (1 - v.pitchDrop * progress)
            phase += frequency / sampleRate
            let wave = v.square
                ? (sin(2 * .pi * phase) >= 0 ? 1.0 : -1.0)
                : sin(2 * .pi * phase)
            var sample = wave * exp(-t / v.bodyDecay)

            let white = Double.random(in: -1...1, using: &generator)
            lowpass += (white - lowpass) * v.damping
            sample += lowpass * v.noise * exp(-t / v.noiseDecay)

            // Fade the tail so the buffer never ends on a step.
            if i >= fadeStart {
                sample *= 1 - Double(i - fadeStart) / Double(count - fadeStart)
            }

            samples[i] = Int16(max(-1, min(1, sample)) * 32_000)
        }

        return wav(samples)
    }

    /// Minimal 16-bit mono RIFF/WAVE wrapper — the one container NSSound is
    /// guaranteed to take from raw Data.
    private static func wav(_ samples: [Int16]) -> Data {
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        var data = Data()

        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(UInt32(36 + payload.count)); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                                   // PCM
        u16(1)                                   // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * 2)              // byte rate
        u16(2)                                   // block align
        u16(16)                                  // bits per sample
        ascii("data"); u32(UInt32(payload.count))
        data.append(payload)
        return data
    }
}
