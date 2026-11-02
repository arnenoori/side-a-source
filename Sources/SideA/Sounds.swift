import AppKit

/// Small player sounds, synthesized at first use so no audio files ship with the app.
@MainActor
enum Sounds {
    enum Effect: CaseIterable {
        case tick, trackChange, spinUp, nudge, done
    }

    static let enabledKey = "soundEffects"
    static let volumeKey = "soundVolume"
    private static var cache: [Effect: NSSound] = [:]
    private static var lastPlayed: [Effect: Date] = [:]

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var volume: Float { Float(UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 0.5) }

    static func play(_ effect: Effect) {
        // A trade followed by a switch, or several sessions waiting at once, sounds once.
        guard enabled, Date().timeIntervalSince(lastPlayed[effect] ?? .distantPast) > 0.6 else { return }
        lastPlayed[effect] = Date()
        let sound = cache[effect] ?? NSSound(data: wav(samples(effect)))
        guard let sound else { return }
        cache[effect] = sound
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    private static let rate = 44_100.0

    private static func samples(_ effect: Effect) -> [Float] {
        switch effect {
        case .tick:
            return pluck(frequency: 2_200, length: 0.03, decay: 160, gain: 0.22)
        case .trackChange:
            return mix(pluck(frequency: 1_568, length: 0.09, decay: 55, gain: 0.2),
                       pluck(frequency: 2_093, length: 0.1, decay: 50, gain: 0.2), at: 0.075)
        case .spinUp:
            let count = Int(rate * 0.26)
            var phase = 0.0
            return (0..<count).map { index in
                let t = Double(index) / rate, progress = t / 0.26
                phase += 2 * .pi * (170 + 380 * progress * progress) / rate
                let envelope = sin(.pi * progress) * (1 - progress * 0.4)
                return Float((sin(phase) + 0.3 * sin(2 * phase)) * envelope * 0.12)
            }
        case .done:
            return mix(bell(frequency: 783.99, length: 0.3, gain: 0.13), bell(frequency: 1_046.5, length: 0.5, gain: 0.13), at: 0.09)
        case .nudge:
            return mix(bell(frequency: 659.3, length: 0.35, gain: 0.16), bell(frequency: 987.8, length: 0.45, gain: 0.14), at: 0.12)
        }
    }

    private static func pluck(frequency: Double, length: Double, decay: Double, gain: Double) -> [Float] {
        (0..<Int(rate * length)).map { index in
            let t = Double(index) / rate
            let attack = min(t / 0.002, 1)
            return Float(sin(2 * .pi * frequency * t) * exp(-decay * t) * attack * gain)
        }
    }

    private static func bell(frequency: Double, length: Double, gain: Double) -> [Float] {
        (0..<Int(rate * length)).map { index in
            let t = Double(index) / rate
            let attack = min(t / 0.004, 1)
            let tone = sin(2 * .pi * frequency * t) + 0.25 * sin(2 * .pi * frequency * 3 * t) * exp(-18 * t)
            return Float(tone * exp(-9 * t) * attack * gain)
        }
    }

    private static func mix(_ first: [Float], _ second: [Float], at offset: Double) -> [Float] {
        let start = Int(rate * offset)
        var result = first + [Float](repeating: 0, count: max(start + second.count - first.count, 0))
        for (index, value) in second.enumerated() { result[start + index] += value }
        return result
    }

    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}
