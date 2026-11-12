// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreHaptics
import Foundation
import PICSKit

/// Plays the sound and vibration that the user chose for a signal, before its change is
/// announced. They are played whether or not VoiceOver is on, so they also reach people who do
/// not use it.
///
/// The sounds use the ambient audio session category: they follow the Ring/Silent switch (silent
/// mode mutes them, while the vibration still plays) and mix with other audio instead of stopping
/// it. iOS does not tell apps whether silent mode is on, so the announcement still waits for a
/// muted sound.
@MainActor
final class SignalCuePlayer {
    struct Cue: Hashable {
        var sound: SignalCueSound
        var vibration: SignalCueVibration

        var isEmpty: Bool {
            sound == SignalCueSound.none && vibration == SignalCueVibration.none
        }
    }

    /// Silence between two cues played one after another.
    static let gap: TimeInterval = 0.15
    /// More cues than this at once would take too long before the announcement.
    static let maximumCues = 3

    /// Whether this device can vibrate with Core Haptics (iPads and simulators cannot).
    static var supportsVibration: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Synthesised WAV files, made the first time each sound is played.
    private var sounds: [SignalCueSound: Data] = [:]
    /// Players stay referenced until they have finished.
    private var activePlayers: [(player: AVAudioPlayer, until: Date)] = []
    private var hapticEngine: CHHapticEngine?

    /// Plays the cues one after another, each distinct cue once.
    /// - Returns: how long they take, so that an announcement can follow them.
    @discardableResult
    func play(_ cues: [Cue]) -> TimeInterval {
        var distinct: [Cue] = []
        for cue in cues where !cue.isEmpty && !distinct.contains(cue) {
            distinct.append(cue)
        }
        guard !distinct.isEmpty else { return 0 }
        var offset: TimeInterval = 0
        for cue in distinct.prefix(Self.maximumCues) {
            let soundLength = play(cue.sound, after: offset)
            let vibrationLength = play(cue.vibration, after: offset)
            offset += max(soundLength, vibrationLength) + Self.gap
        }
        return offset
    }

    func preview(_ sound: SignalCueSound) {
        play([Cue(sound: sound, vibration: .none)])
    }

    func preview(_ vibration: SignalCueVibration) {
        play([Cue(sound: .none, vibration: vibration)])
    }

    // MARK: - Sound

    private func play(_ sound: SignalCueSound, after delay: TimeInterval) -> TimeInterval {
        guard sound != SignalCueSound.none else { return 0 }
        let now = Date()
        activePlayers.removeAll { $0.until < now }
        let data = sounds[sound] ?? ToneSynthesizer.wav(for: sound)
        sounds[sound] = data
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            player.prepareToPlay()
            player.play(atTime: player.deviceCurrentTime + delay)
            let length = player.duration
            activePlayers.append((player, now.addingTimeInterval(delay + length + 1)))
            return length
        } catch {
            return 0
        }
    }

    // MARK: - Vibration

    /// (start, length) of each vibration, in seconds.
    static func pulses(for vibration: SignalCueVibration) -> [(start: Double, length: Double)] {
        switch vibration {
        case .none: []
        case .long: [(0, 0.5)]
        case .double: [(0, 0.12), (0.24, 0.12)]
        case .triple: [(0, 0.1), (0.2, 0.1), (0.4, 0.1)]
        }
    }

    private func play(_ vibration: SignalCueVibration, after delay: TimeInterval) -> TimeInterval {
        let pulses = Self.pulses(for: vibration)
        guard !pulses.isEmpty, Self.supportsVibration, let engine = startedHapticEngine() else { return 0 }
        let events = pulses.map { pulse in
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                ],
                relativeTime: delay + pulse.start,
                duration: pulse.length
            )
        }
        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            return 0
        }
        return pulses.map { $0.start + $0.length }.max() ?? 0
    }

    /// The haptic engine, started. After the system has stopped or reset it (for example while the
    /// app was in the background), starting fails and a new engine is made once.
    private func startedHapticEngine() -> CHHapticEngine? {
        if let engine = hapticEngine, (try? engine.start()) != nil {
            return engine
        }
        guard let engine = try? CHHapticEngine() else { return nil }
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        guard (try? engine.start()) != nil else { return nil }
        hapticEngine = engine
        return engine
    }
}
