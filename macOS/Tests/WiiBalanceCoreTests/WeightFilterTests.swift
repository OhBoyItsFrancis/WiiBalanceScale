import XCTest
@testable import WiiBalanceCore

final class WeightFilterTests: XCTestCase {
    func testStartsHalfFullAndReachesFiveStarsWhenStable() {
        var filter = WeightFilter(zeroKilograms: 2.0)
        var measurement = filter.add(2.0)
        XCTAssertEqual(measurement.stableSamples, 52)
        XCTAssertEqual(measurement.stars, 2)
        XCTAssertEqual(measurement.kilograms, 0, accuracy: 1e-9)

        // Someone steps on: the history no longer agrees, accuracy drops to 1 kg.
        measurement = filter.add(82.34)
        XCTAssertEqual(measurement.stableSamples, 1)
        XCTAssertEqual(measurement.stars, 0)
        XCTAssertEqual(measurement.accuracyKilograms, 1)
        XCTAssertEqual(measurement.displayKilograms, 80)

        for _ in 0..<200 { measurement = filter.add(82.34) }
        XCTAssertEqual(measurement.stableSamples, WeightFilter.historyLength)
        XCTAssertEqual(measurement.stars, 5)
        XCTAssertEqual(measurement.kilograms, 80.34, accuracy: 1e-9)
        XCTAssertEqual(measurement.displayKilograms, 80.34, accuracy: 1e-9)
    }

    func testNoisyReadingsAverage() {
        var filter = WeightFilter(zeroKilograms: 0)
        var measurement = filter.add(70)
        for i in 0..<100 { measurement = filter.add(70 + (i % 2 == 0 ? 0.3 : -0.3)) }
        XCTAssertEqual(measurement.stars, 5)
        XCTAssertEqual(measurement.kilograms, 70, accuracy: 0.01)
    }

    func testRangeLargerThanOneKilogramBreaksTheRun() {
        var filter = WeightFilter(zeroKilograms: 0)
        for _ in 0..<100 { filter.add(70.0) }
        // 70.0 ... 71.2 spans more than 1 kg, so only the newest samples are averaged.
        for _ in 0..<10 { filter.add(71.2) }
        XCTAssertEqual(filter.stableSamples, 10)
    }

    func testZero() {
        var filter = WeightFilter(zeroKilograms: 0)
        for _ in 0..<100 { filter.add(1.5) }
        filter.zero()
        XCTAssertEqual(filter.zeroKilograms, 1.5, accuracy: 1e-9)
        XCTAssertEqual(filter.add(1.5).kilograms, 0, accuracy: 1e-9)
    }
}

final class WeightUnitTests: XCTestCase {
    func testScaleReadout() {
        XCTAssertEqual(WeightUnit.kilograms.scaleReadout(kilograms: 5.56), "05.560")
        XCTAssertEqual(WeightUnit.kilograms.scaleReadout(kilograms: 80.34), "80.340")
        XCTAssertEqual(WeightUnit.kilograms.scaleReadout(kilograms: 105.5), "105.50")
        XCTAssertEqual(WeightUnit.kilograms.scaleReadout(kilograms: -0.25), "-00.250")
        XCTAssertEqual(WeightUnit.pounds.scaleReadout(kilograms: 80), "176.37")
        // 6.33 kg = 13.955 lb, which must round up to a whole stone rather than show "00:14.0".
        XCTAssertEqual(WeightUnit.stones.scaleReadout(kilograms: 6.33), "01:00.0")
        XCTAssertEqual(WeightUnit.stones.scaleReadout(kilograms: 80), "12:08.4")
    }

    func testJournalFormatting() {
        XCTAssertEqual(WeightUnit.kilograms.format(kilograms: 81.26), "81.3 kg")
        XCTAssertEqual(WeightUnit.pounds.format(kilograms: 81.26), "179.1 lb")
        XCTAssertEqual(WeightUnit.stones.format(kilograms: 81.26), "12 st 11.1 lb")
        XCTAssertEqual(WeightUnit.kilograms.formatChange(kilograms: -2.44), "\u{2212}2.4 kg")
        XCTAssertEqual(WeightUnit.kilograms.formatChange(kilograms: 0.6), "+0.6 kg")
        XCTAssertEqual(WeightUnit.kilograms.formatChange(kilograms: 0.01), "\u{00B1}0.0 kg")
        XCTAssertEqual(WeightUnit.stones.formatChange(kilograms: -2), "\u{2212}4.4 lb")
        XCTAssertEqual(WeightUnit.stones.formatChange(kilograms: -8), "\u{2212}1 st 3.6 lb")
    }

    func testParsing() {
        XCTAssertEqual(WeightUnit.kilograms.parse("81.5")!, 81.5, accuracy: 1e-9)
        XCTAssertEqual(WeightUnit.kilograms.parse("81,5 kg")!, 81.5, accuracy: 1e-9)
        XCTAssertEqual(WeightUnit.pounds.parse("180")!, 180 / WeightUnit.poundsPerKilogram, accuracy: 1e-9)
        XCTAssertEqual(WeightUnit.stones.parse("12st 4.5lb")!, (12 * 14 + 4.5) / WeightUnit.poundsPerKilogram, accuracy: 1e-9)
        XCTAssertEqual(WeightUnit.stones.parse("12:4.5")!, (12 * 14 + 4.5) / WeightUnit.poundsPerKilogram, accuracy: 1e-9)
        XCTAssertEqual(WeightUnit.stones.parse("12.5")!, 12.5 * 14 / WeightUnit.poundsPerKilogram, accuracy: 1e-9)
        XCTAssertNil(WeightUnit.kilograms.parse(""))
        XCTAssertNil(WeightUnit.kilograms.parse("abc"))
        XCTAssertNil(WeightUnit.kilograms.parse("0"))
        XCTAssertNil(WeightUnit.kilograms.parse("80 81"))
    }
}
