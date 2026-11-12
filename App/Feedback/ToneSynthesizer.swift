// SPDX-License-Identifier: Apache-2.0

import Foundation
import PICSKit

/// Synthesises the cue sounds in code, as short WAV files in memory, so that the app ships no
/// audio files.
///
/// Every sound is made of decaying notes with a few overtones (bell-like), and none of them falls
/// in pitch or sweeps: the guidance sounds of real pedestrian signals are bird calls such as
/// ピヨピヨ and カッコー (a falling pair of notes), and the phone must never be mistaken for one.
enum ToneSynthesizer {
    static let sampleRate = 44_100

    /// One note of a sound.
    struct Note {
        /// Start, in seconds from the beginning of the sound.
        var start: Double
        var frequency: Double
        /// Length of the note, after which it is cut off with a short fade.
        var length: Double
        /// Time for the note to fall to 1/e of its level.
        var decay: Double
        /// Relative levels of the fundamental and its overtones (×1, ×2, ×3…).
        var partials: [Double] = [1, 0.35, 0.12]
    }

    static func notes(for sound: SignalCueSound) -> [Note] {
        switch sound {
        case .none:
            []
        case .bell:
            // ポーン: C6.
            [Note(start: 0, frequency: 1046.5, length: 0.6, decay: 0.2)]
        case .arpeggio:
            // ドミソ: C5, E5, G5, rising.
            [
                Note(start: 0, frequency: 523.25, length: 0.14, decay: 0.08),
                Note(start: 0.13, frequency: 659.25, length: 0.14, decay: 0.08),
                Note(start: 0.26, frequency: 783.99, length: 0.3, decay: 0.12),
            ]
        case .low:
            // ボン: G4 with strong overtones, so that small speakers still play it clearly.
            [Note(start: 0, frequency: 392.0, length: 0.35, decay: 0.12, partials: [1, 0.6, 0.35, 0.2])]
        case .triple:
            // ポポポ: three short G6 pips.
            (0..<3).map { index in
                Note(start: Double(index) * 0.14, frequency: 1567.98, length: 0.07, decay: 0.5, partials: [1, 0.2])
            }
        }
    }

    /// Length of the sound in seconds.
    static func duration(of sound: SignalCueSound) -> Double {
        notes(for: sound).map { $0.start + $0.length }.max() ?? 0
    }

    /// Samples from -1 to 1, peaking at 0.8.
    static func samples(for sound: SignalCueSound) -> [Float] {
        let notes = notes(for: sound)
        let count = Int((duration(of: sound) * Double(sampleRate)).rounded(.up))
        guard count > 0 else { return [] }
        var samples = [Double](repeating: 0, count: count)
        let attack = 0.005
        let release = 0.02
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            let length = Int(note.length * Double(sampleRate))
            for offset in 0..<length where first + offset < count {
                let t = Double(offset) / Double(sampleRate)
                // A short fade in and out keeps the edges from clicking.
                let fadeIn = min(1, t / attack)
                let fadeOut = min(1, (note.length - t) / release)
                let envelope = exp(-t / note.decay) * fadeIn * max(0, fadeOut)
                var value = 0.0
                for (index, level) in note.partials.enumerated() {
                    value += level * sin(2 * .pi * note.frequency * Double(index + 1) * t)
                }
                samples[first + offset] += value * envelope
            }
        }
        let peak = samples.map { abs($0) }.max() ?? 0
        let gain = peak > 0 ? 0.8 / peak : 0
        return samples.map { Float($0 * gain) }
    }

    /// A 16-bit mono PCM WAV file of the sound.
    static func wav(for sound: SignalCueSound) -> Data {
        let pcm = samples(for: sound).map { Int16(($0 * Float(Int16.max)).rounded()) }
        let dataSize = UInt32(pcm.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)) // fmt chunk size
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // bytes per second
        append(UInt16(2)) // block align
        append(UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in pcm { append(sample) }
        return data
    }
}
