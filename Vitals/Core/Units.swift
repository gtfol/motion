import Foundation

/// Display unit for external load. Loads are always stored in kilograms; this only changes presentation and entry.
enum WeightUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case pounds = "lb"
    case kilograms = "kg"

    static let kilogramsPerPound = 0.45359237

    var id: String { rawValue }
    var symbol: String { rawValue }

    func kilograms(fromDisplayed value: Double) -> Double {
        self == .kilograms ? value : value * Self.kilogramsPerPound
    }

    func displayed(fromKilograms kilograms: Double) -> Double {
        self == .kilograms ? kilograms : kilograms / Self.kilogramsPerPound
    }
}

/// Parsing and formatting shared by set entry, summaries, and history.
enum NumberText {
    static let maximumReps = 999
    static let maximumLoadKilograms = 1_000.0

    /// At most `maxFractionDigits` decimals, trailing zeros removed: "135", "61.23", "2.5".
    static func decimal(_ value: Double, maxFractionDigits: Int = 2, locale: Locale = .current) -> String {
        let rounded = (value * pow(10, Double(maxFractionDigits))).rounded() / pow(10, Double(maxFractionDigits))
        return rounded.formatted(.number.precision(.fractionLength(0...maxFractionDigits)).locale(locale))
    }

    static func whole(_ value: Double, locale: Locale = .current) -> String {
        value.rounded().formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    /// Accepts "." or "," as the decimal separator. Rejects negative, non-finite, and implausibly large values.
    static func parseDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func parseReps(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (0...maximumReps).contains(value) else { return nil }
        return value
    }

    /// Converts typed load text in the display unit to kilograms, or nil if it isn't a usable load.
    static func parseLoad(_ text: String, unit: WeightUnit) -> Double? {
        guard let value = parseDecimal(text) else { return nil }
        let kilograms = unit.kilograms(fromDisplayed: value)
        return kilograms <= maximumLoadKilograms ? kilograms : nil
    }
}

/// Load text. Zero external load is shown as bodyweight ("bw"), never as zero effort.
enum LoadText {
    /// The number alone in the display unit, used for editable fields: "135", "61.23", "0".
    static func number(_ kilograms: Double, unit: WeightUnit, locale: Locale = .current) -> String {
        NumberText.decimal(unit.displayed(fromKilograms: kilograms), locale: locale)
    }

    /// "135 lb", "bw", or "bw + 20 lb" for bodyweight movements with added load.
    static func load(_ kilograms: Double, unit: WeightUnit, isBodyweight: Bool, locale: Locale = .current) -> String {
        guard kilograms > 0 else { return "bw" }
        let value = "\(number(kilograms, unit: unit, locale: locale)) \(unit.symbol)"
        return isBodyweight ? "bw + \(value)" : value
    }

    /// "135 × 5" or "bw × 12". The unit is omitted to keep compact lists readable.
    static func set(reps: Int, kilograms: Double, unit: WeightUnit, isBodyweight: Bool, locale: Locale = .current) -> String {
        if kilograms <= 0 { return "bw × \(reps)" }
        let value = number(kilograms, unit: unit, locale: locale)
        return isBodyweight ? "bw+\(value) × \(reps)" : "\(value) × \(reps)"
    }

    /// Volume in whole display units: "12,340 lb".
    static func volume(_ kilograms: Double, unit: WeightUnit, locale: Locale = .current) -> String {
        "\(NumberText.whole(unit.displayed(fromKilograms: kilograms), locale: locale)) \(unit.symbol)"
    }
}
