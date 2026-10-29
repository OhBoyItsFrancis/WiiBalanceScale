/*********************************************************************************
WiiBalanceScale

MIT License

Copyright (c) 2017-2023 Bernhard Schelling
**********************************************************************************/

import Foundation

/// A filtered scale reading.
public struct ScaleMeasurement: Equatable {
    /// Zeroed weight averaged over the stable history, not rounded.
    public var kilograms: Double
    /// `kilograms` rounded to the current accuracy, which is what the scale displays.
    public var displayKilograms: Double
    /// The rounding step: 1 kg for a fresh reading, down to 10 g after the full history is stable.
    public var accuracyKilograms: Double
    /// 0...5, the original "quality stars".
    public var stars: Int
    /// Number of consecutive samples that agree within 1 kg.
    public var stableSamples: Int
}

/// The Balance Board is noisy for a single sample but accurate when averaged over time.
/// This keeps a history of samples (100 samples, 5 seconds at the 20 Hz sampling rate) and
/// averages the most recent run of samples that agree within 1 kg. The longer the run, the
/// more digits are shown. Ported from the original WiiBalanceScale.
public struct WeightFilter {
    public static let historyLength = 100
    public static let maxStars = 5

    private var history: [Double?]
    private var cursor: Int
    /// Raw board reading that corresponds to 0 kg.
    public private(set) var zeroKilograms: Double
    public private(set) var stableSamples: Int

    public init(zeroKilograms: Double = 0) {
        history = []
        cursor = 0
        self.zeroKilograms = 0
        stableSamples = 0
        reset(zeroKilograms: zeroKilograms)
    }

    /// Sets the zero point and starts with a half full quality bar, like the original.
    public mutating func reset(zeroKilograms: Double) {
        self.zeroKilograms = zeroKilograms
        let half = Self.historyLength / 2
        history = (0..<Self.historyLength).map { $0 > half ? nil : zeroKilograms }
        cursor = half
        stableSamples = half
    }

    /// Zeroes the scale at the current (stable) reading.
    public mutating func zero() {
        zeroKilograms = rawAverage
    }

    /// Average raw reading over the stable part of the history.
    public var rawAverage: Double {
        let count = max(stableSamples, 1)
        var sum = 0.0
        for i in 0..<count {
            sum += history[index(back: i)] ?? zeroKilograms
        }
        return sum / Double(count)
    }

    private func index(back offset: Int) -> Int {
        (cursor - offset % Self.historyLength + Self.historyLength) % Self.historyLength
    }

    /// Adds a raw sample (kilograms, not zeroed) and returns the filtered measurement.
    @discardableResult
    public mutating func add(_ sample: Double) -> ScaleMeasurement {
        cursor = (cursor + 1) % Self.historyLength
        history[cursor] = sample

        var sum = 0.0
        var maxSeen = sample
        var minSeen = sample
        var count = 0
        while count < Self.historyLength {
            guard let entry = history[index(back: count)] else { break }
            if abs(maxSeen - entry) > 1 || abs(minSeen - entry) > 1 { break }
            maxSeen = max(maxSeen, entry)
            minSeen = min(minSeen, entry)
            let diff = max(abs(entry - sample), abs((sum + entry) / Double(count + 1) - sample))
            if diff > 1 { break }
            sum += entry
            count += 1
        }
        stableSamples = count

        let kilograms = sum / Double(count) - zeroKilograms
        let accuracy = 1.0 / Double(count)
        let display = (kilograms / accuracy + 0.5).rounded(.down) * accuracy
        let stars = min(Self.maxStars, (count + 5) / (Self.historyLength / Self.maxStars))
        return ScaleMeasurement(
            kilograms: kilograms,
            displayKilograms: display,
            accuracyKilograms: accuracy,
            stars: stars,
            stableSamples: count)
    }
}
