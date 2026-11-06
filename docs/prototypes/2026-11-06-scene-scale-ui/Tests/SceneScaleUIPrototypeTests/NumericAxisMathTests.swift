import Foundation
import Testing
@testable import SceneScaleUIPrototype

@Suite struct NumericAxisMathTests {
    private let size: ClosedRange<Float> = 0.001...100
    private let position: ClosedRange<Float> = -1000...1000

    @Test func typedMillimetresAndNegativePositionsKeepTheirSIValues() throws {
        #expect(try NumericAxisInput.parse("1 mm", unit: .metres, range: size) == Float(0.001))
        #expect(try NumericAxisInput.parse("350 cm", unit: .metres, range: size) == 3.5)
        #expect(try NumericAxisInput.parse("−125.5 mm", unit: .metres, range: position) == Float(-0.1255))
        #expect(try NumericAxisInput.parse("1e-3", unit: .metres, range: size) == Float(0.001))
        #expect(try NumericAxisInput.parse("3,5", unit: .metres, range: size,
            locale: Locale(identifier: "de_DE")) == 3.5)
    }

    @Test func unitDisplayRoundTripsArbitraryExistingFloatValuesWithoutRounding() throws {
        for value: Float in [0.001, 0.12345679, 3.5, 99.99999, 100, -999.99994, 1000] {
            for unit in SIEditingUnit.allCases {
                let text = NumericAxisInput.text(for: value, unit: unit)
                #expect(try NumericAxisInput.parse(text, unit: unit, range: position) == value)
            }
        }
    }

    @Test func malformedNonfiniteAndOutOfRangeDraftsAreRejectedRatherThanClipped() {
        for text in ["", "abc", "1 2", "NaN", "Inf", "1e400", "101", "0", "-0.001", "0.5 mm"] {
            #expect(throws: NumericAxisInputError.self) {
                try NumericAxisInput.parse(text, unit: .metres, range: size)
            }
        }
        #expect(throws: NumericAxisInputError.self) {
            try NumericAxisInput.parse("1000.5", unit: .metres, range: position)
        }
    }

    @Test func millimetreSliderUsesALocalDomainAndThousandMetrePositionUsesObjectSpan() throws {
        let tiny = try #require(NumericAxisDomain.contextual(value: 0.001, allowed: size))
        #expect(tiny.range.contains(Double(Float(0.001))))
        #expect(tiny.range.upperBound - tiny.range.lowerBound <= 0.000501)
        let distant = try #require(NumericAxisDomain.contextual(value: 1000, allowed: position, preferredSpan: 0.1))
        #expect(distant.range.contains(1000))
        #expect(abs(distant.range.lowerBound - 999.9) < 1e-9)
        #expect(distant.range.upperBound == 1000)
    }

    @Test func sliderDomainRemainsFixedUntilTheDragEnds() throws {
        var adjustment = NumericAxisAdjustment()
        adjustment.begin(value: 3.5, allowed: size, preferredSpan: nil)
        let first = try #require(adjustment.domain(value: 3.5, allowed: size, preferredSpan: nil))
        adjustment.begin(value: 4, allowed: size, preferredSpan: 10)
        #expect(adjustment.domain(value: 4, allowed: size, preferredSpan: 10) == first)
        adjustment.end()
        #expect(adjustment.domain(value: 4, allowed: size, preferredSpan: nil) != first)
    }

    @Test func unsupportedCurrentValuesKeepTheirTextAndDoNotProduceASliderDomain() {
        #expect(NumericAxisInput.text(for: 5000, unit: .metres) == "5000")
        #expect(NumericAxisDomain.contextual(value: 5000, allowed: position) == nil)
        #expect(NumericAxisDomain.contextual(value: .nan, allowed: position) == nil)
        #expect(NumericAxisDomain.contextual(value: 1, allowed: size, preferredSpan: -1) == nil)
    }
}
