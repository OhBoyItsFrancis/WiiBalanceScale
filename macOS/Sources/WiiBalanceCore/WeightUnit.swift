import Foundation

public enum WeightUnit: String, CaseIterable, Codable, Identifiable {
    case kilograms = "kg"
    case pounds = "lb"
    case stones = "st"

    public static let poundsPerKilogram = 2.20462262
    public static let poundsPerStone = 14.0

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kilograms: return "Kilograms (kg)"
        case .pounds: return "Pounds (lb)"
        case .stones: return "Stone & pounds (st lb)"
        }
    }

    /// Unit label used next to the large scale readout.
    public var scaleSymbol: String {
        switch self {
        case .kilograms: return "kg"
        case .pounds: return "lbs"
        case .stones: return "st:lbs"
        }
    }

    /// Unit used for plain numbers (charts, CSV). Stones are charted in pounds.
    public var axisSymbol: String { self == .kilograms ? "kg" : "lb" }

    /// Converts kilograms to the number plotted/exported for this unit (stones use pounds).
    public func axisValue(fromKilograms kg: Double) -> Double {
        self == .kilograms ? kg : kg * Self.poundsPerKilogram
    }

    public func kilograms(fromAxisValue value: Double) -> Double {
        self == .kilograms ? value : value / Self.poundsPerKilogram
    }

    // MARK: Formatting

    /// The large scale readout, matching the original app: "05.560", "-00.250", "12:07.3".
    public func scaleReadout(kilograms kg: Double, fractionDigits: Int = 3) -> String {
        switch self {
        case .kilograms, .pounds:
            let value = axisValue(fromKilograms: kg)
            let digits = abs(value) >= 100 ? max(fractionDigits - 1, 0) : fractionDigits
            return Self.padded(value, integerDigits: 2, fractionDigits: digits)
        case .stones:
            let pounds = kg * Self.poundsPerKilogram
            let (sign, stones, remainder) = Self.splitStones(pounds: pounds, fractionDigits: 1)
            return sign + String(format: "%02d", stones) + ":" + Self.padded(remainder, integerDigits: 2, fractionDigits: 1)
        }
    }

    /// A journal style weight such as "81.3 kg", "179.2 lb" or "12 st 11.2 lb".
    public func format(kilograms kg: Double, fractionDigits: Int = 1) -> String {
        switch self {
        case .kilograms, .pounds:
            return String(format: "%.\(fractionDigits)f", axisValue(fromKilograms: kg)) + " " + axisSymbol
        case .stones:
            let (sign, stones, pounds) = Self.splitStones(pounds: kg * Self.poundsPerKilogram, fractionDigits: fractionDigits)
            return sign + "\(stones) st " + String(format: "%.\(fractionDigits)f", pounds) + " lb"
        }
    }

    /// A signed change such as "−2.4 kg", "+0.6 lb" or "−1 st 3.0 lb".
    public func formatChange(kilograms kg: Double, fractionDigits: Int = 1) -> String {
        let rounded = Self.round(axisValue(fromKilograms: kg), fractionDigits: fractionDigits)
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "\u{2212}" : "\u{00B1}")
        return sign + formatAmount(kilograms: kg, fractionDigits: fractionDigits)
    }

    /// An unsigned amount; for stones, amounts under one stone are given in pounds ("4.4 lb").
    public func formatAmount(kilograms kg: Double, fractionDigits: Int = 1) -> String {
        let magnitude = abs(kg)
        if self == .stones && magnitude * Self.poundsPerKilogram >= Self.poundsPerStone {
            return format(kilograms: magnitude, fractionDigits: fractionDigits)
        }
        let unit: WeightUnit = self == .stones ? .pounds : self
        return unit.format(kilograms: magnitude, fractionDigits: fractionDigits)
    }

    /// Weight change between journal milestones.
    public var milestoneStepKilograms: Double {
        switch self {
        case .kilograms: return 2.5
        case .pounds: return 5 / Self.poundsPerKilogram
        case .stones: return 7 / Self.poundsPerKilogram
        }
    }

    // MARK: Parsing

    /// Parses user input in this unit and returns kilograms. Stones accept "12 4.5",
    /// "12st 4.5lb", "12:4.5" or a single decimal number of stones.
    public func parse(_ text: String) -> Double? {
        let numbers = Self.numbers(in: text)
        switch self {
        case .kilograms, .pounds:
            guard numbers.count == 1, numbers[0] > 0 else { return nil }
            return kilograms(fromAxisValue: numbers[0])
        case .stones:
            let pounds: Double
            switch numbers.count {
            case 1: pounds = numbers[0] * Self.poundsPerStone
            case 2: pounds = numbers[0] * Self.poundsPerStone + numbers[1]
            default: return nil
            }
            guard pounds > 0 else { return nil }
            return pounds / Self.poundsPerKilogram
        }
    }

    // MARK: Helpers

    static func numbers(in text: String) -> [Double] {
        var numbers: [Double] = []
        var current = ""
        for character in text + " " {
            if character.isNumber || ((character == "." || character == ",") && !current.contains(".")) {
                current.append(character == "," ? "." : character)
            } else if !current.isEmpty {
                if let value = Double(current) { numbers.append(value) }
                current = ""
            }
        }
        return numbers
    }

    static func round(_ value: Double, fractionDigits: Int) -> Double {
        let factor = pow(10.0, Double(fractionDigits))
        return (value * factor).rounded() / factor
    }

    /// Splits pounds into whole stones and remaining pounds, rounding first so that
    /// 13.96 lb becomes "1 st 0.0 lb" instead of "0 st 14.0 lb".
    static func splitStones(pounds: Double, fractionDigits: Int) -> (sign: String, stones: Int, pounds: Double) {
        let rounded = round(abs(pounds), fractionDigits: fractionDigits)
        let sign = (pounds < 0 && rounded > 0) ? "-" : ""
        let stones = Int((rounded / poundsPerStone).rounded(.down))
        let remainder = round(rounded - Double(stones) * poundsPerStone, fractionDigits: fractionDigits)
        return (sign, stones, remainder)
    }

    /// Formats like .NET's "00.000": at least `integerDigits` integer digits.
    static func padded(_ value: Double, integerDigits: Int, fractionDigits: Int) -> String {
        let rounded = round(value, fractionDigits: fractionDigits)
        let sign = rounded < 0 ? "-" : ""
        let width = integerDigits + (fractionDigits > 0 ? fractionDigits + 1 : 0)
        return sign + String(format: "%0\(width).\(fractionDigits)f", abs(rounded))
    }
}
