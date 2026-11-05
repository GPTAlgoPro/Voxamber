import Foundation

public enum SIEditingUnit: String, CaseIterable, Sendable {
    case metres = "m", centimetres = "cm", millimetres = "mm"

    public var metresPerUnit: Double {
        switch self { case .metres: 1; case .centimetres: 0.01; case .millimetres: 0.001 }
    }

    fileprivate var decimalFactor: Decimal {
        switch self { case .metres: 1; case .centimetres: Decimal(string: "0.01")!; case .millimetres: Decimal(string: "0.001")! }
    }
}

public enum NumericAxisInputError: Error, Equatable, LocalizedError {
    case invalidNumber, outsideRange(minimum: Float, maximum: Float)

    public var errorDescription: String? {
        message(locale: .current)
    }

    public func message(locale: Locale) -> String {
        let english = locale.language.languageCode?.identifier != "zh"
        switch self {
        case .invalidNumber: return english ? "Enter a finite number in m, cm, or mm." : "请输入有限数值，可使用 m、cm 或 mm。"
        case .outsideRange(let minimum, let maximum):
            return english ? "Use \(minimum) to \(maximum) m. The previous value is kept."
                : "请输入 \(minimum) 至 \(maximum) m，原值尚未更改。"
        }
    }
}

public enum NumericAxisInput {
    /// Float's shortest decimal representation is kept through decimal unit
    /// conversion. Formatting never writes to a model binding.
    public static func text(for value: Float, unit: SIEditingUnit) -> String {
        guard value.isFinite,
              let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
            return String(value)
        }
        return NSDecimalNumber(decimal: decimal / unit.decimalFactor).stringValue
    }

    public static func parse(_ text: String, unit: SIEditingUnit, range: ClosedRange<Float>,
                             locale: Locale = .current) throws -> Float {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        var selected = unit
        for suffix in [SIEditingUnit.millimetres, .centimetres, .metres] {
            if raw.lowercased().hasSuffix(suffix.rawValue) {
                selected = suffix
                raw = String(raw.dropLast(suffix.rawValue.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if locale.decimalSeparator == ",", !raw.contains(".") {
            raw = raw.replacingOccurrences(of: ",", with: ".")
        }
        guard !raw.isEmpty, let number = Double(raw), number.isFinite else {
            throw NumericAxisInputError.invalidNumber
        }
        let metres = number * selected.metresPerUnit
        let value = Float(metres)
        guard metres.isFinite, value.isFinite else { throw NumericAxisInputError.invalidNumber }
        guard range.contains(value) else {
            throw NumericAxisInputError.outsideRange(minimum: range.lowerBound, maximum: range.upperBound)
        }
        return value
    }
}

public struct NumericAxisDomain: Equatable, Sendable {
    public let range: ClosedRange<Double>

    public static func contextual(value: Float, allowed: ClosedRange<Float>,
                                  preferredSpan: Double? = nil) -> Self? {
        guard value.isFinite, allowed.lowerBound.isFinite, allowed.upperBound.isFinite,
              allowed.lowerBound < allowed.upperBound, allowed.contains(value) else { return nil }
        let lower = Double(allowed.lowerBound), upper = Double(allowed.upperBound), current = Double(value)
        let naturalSpan = max(abs(current) * 0.5, 0.0005)
        let requested = preferredSpan ?? naturalSpan
        guard requested.isFinite, requested > 0 else { return nil }
        let span = min(requested, upper - lower)
        let start = max(lower, min(current - span / 2, upper - span))
        return Self(range: start...min(upper, start + span))
    }
}

/// The auxiliary slider's scale is captured once at touch-down, then released
/// at touch-up. Changing the value during a drag cannot move its endpoints.
public struct NumericAxisAdjustment: Sendable {
    public private(set) var frozenDomain: NumericAxisDomain?
    public init() {}

    public mutating func begin(value: Float, allowed: ClosedRange<Float>, preferredSpan: Double?) {
        guard frozenDomain == nil else { return }
        frozenDomain = .contextual(value: value, allowed: allowed, preferredSpan: preferredSpan)
    }
    public mutating func end() { frozenDomain = nil }

    public func domain(value: Float, allowed: ClosedRange<Float>, preferredSpan: Double?) -> NumericAxisDomain? {
        frozenDomain ?? .contextual(value: value, allowed: allowed, preferredSpan: preferredSpan)
    }
}
