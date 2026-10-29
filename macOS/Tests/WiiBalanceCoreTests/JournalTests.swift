import XCTest
@testable import WiiBalanceCore

final class JournalTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ day: Int, hour: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour))!
            .addingTimeInterval(Double(day - 1) * 86_400)
    }

    // MARK: Document

    func testEntriesStaySorted() {
        var document = JournalDocument()
        let late = WeighIn(date: date(3), kilograms: 80, source: .manual)
        let early = WeighIn(date: date(1), kilograms: 82, source: .manual)
        document.add(late)
        document.add(early)
        XCTAssertEqual(document.entries.map(\.id), [early.id, late.id])

        var moved = early
        moved.date = date(5)
        document.update(moved)
        XCTAssertEqual(document.entries.map(\.id), [late.id, early.id])
        XCTAssertEqual(document.previous(to: moved)?.id, late.id)

        document.remove(ids: [late.id])
        XCTAssertEqual(document.entries.count, 1)
    }

    func testMergeSkipsDuplicates() {
        var document = JournalDocument(entries: [WeighIn(date: date(1), kilograms: 80, source: .balanceBoard)])
        let added = document.merge([
            WeighIn(date: date(1).addingTimeInterval(20), kilograms: 80.01, source: .imported),
            WeighIn(date: date(2), kilograms: 79.5, source: .imported),
        ])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(document.entries.count, 2)
    }

    func testSaveAndLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")

        XCTAssertEqual(try JournalDocument.load(from: url), JournalDocument())

        let document = JournalDocument(
            entries: [WeighIn(date: date(1), kilograms: 81.25, note: "First day", source: .balanceBoard)],
            goalKilograms: 72, heightCentimeters: 180)
        try document.save(to: url)
        try document.save(to: url)
        XCTAssertEqual(try JournalDocument.load(from: url), document)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal.backup.json").path))
    }

    // MARK: CSV

    func testCSVRoundTrip() throws {
        let entries = [
            WeighIn(date: date(1), kilograms: 81.25, note: "Start, \"finally\"", source: .balanceBoard),
            WeighIn(date: date(2), kilograms: 80.9, note: "line\nbreak", source: .manual),
        ]
        let csv = JournalCSV.export(entries)
        XCTAssertTrue(csv.hasPrefix("date,weight_kg,weight_lb,note,source\n2026-01-01T07:00:00Z,81.25,179.13,"))
        let imported = try JournalCSV.importEntries(from: csv, calendar: calendar)
        XCTAssertEqual(imported.map(\.date), entries.map(\.date))
        XCTAssertEqual(imported.map(\.note), entries.map(\.note))
        XCTAssertEqual(imported[0].kilograms, 81.25, accuracy: 1e-9)
        XCTAssertEqual(imported[1].source, .imported)
    }

    func testCSVImportVariants() throws {
        let pounds = try JournalCSV.importEntries(from: "Date;Weight (lbs);Notes\r\n2026-01-05;180,5;ok\r\n", calendar: calendar)
        XCTAssertEqual(pounds.count, 1)
        XCTAssertEqual(pounds[0].kilograms, 180.5 / WeightUnit.poundsPerKilogram, accuracy: 1e-9)
        XCTAssertEqual(pounds[0].date, calendar.date(from: DateComponents(year: 2026, month: 1, day: 5)))
        XCTAssertEqual(pounds[0].note, "ok")

        let plain = try JournalCSV.importEntries(from: "date,weight\n2026-01-05 07:30,180\n", defaultUnit: .stones, calendar: calendar)
        XCTAssertEqual(plain[0].kilograms, 180 / WeightUnit.poundsPerKilogram, accuracy: 1e-9)

        XCTAssertThrowsError(try JournalCSV.importEntries(from: "date,weight\n", calendar: calendar))
        XCTAssertThrowsError(try JournalCSV.importEntries(from: "when,weight\nx,1\n", calendar: calendar))
        XCTAssertThrowsError(try JournalCSV.importEntries(from: "date,weight\nyesterday,80\n", calendar: calendar)) { error in
            XCTAssertEqual(error as? JournalCSV.ImportError, .invalidRow(line: 2, reason: "unrecognized date \"yesterday\""))
        }
    }

    // MARK: Analysis

    func testTrendAndDailyAveraging() {
        let entries = [
            WeighIn(date: date(1, hour: 7), kilograms: 100, source: .manual),
            WeighIn(date: date(1, hour: 20), kilograms: 102, source: .manual),
            WeighIn(date: date(2), kilograms: 91, source: .manual),
            WeighIn(date: date(4), kilograms: 91, source: .manual),
        ]
        let analysis = JournalAnalysis(entries: entries, calendar: calendar)
        XCTAssertEqual(analysis.daily.count, 3)
        XCTAssertEqual(analysis.daily[0].kilograms, 101)
        XCTAssertEqual(analysis.daily[0].trendKilograms, 101)
        XCTAssertEqual(analysis.daily[1].trendKilograms, 100, accuracy: 1e-9)
        // Two day gap: alpha = 1 - 0.9^2 = 0.19.
        XCTAssertEqual(analysis.daily[2].trendKilograms, 100 - 0.19 * 9, accuracy: 1e-9)
    }

    func testSummaryWithSteadyLoss() throws {
        // 100 kg losing 0.1 kg per day for 60 days.
        let entries = (1...60).map { WeighIn(date: date($0), kilograms: 100 - 0.1 * Double($0 - 1), source: .manual) }
        let analysis = JournalAnalysis(entries: entries, calendar: calendar)
        let summary = analysis.summary(goalKilograms: 90, heightCentimeters: 200)

        XCTAssertEqual(summary.weighInCount, 60)
        XCTAssertEqual(summary.startKilograms, 100)
        XCTAssertEqual(summary.latestKilograms!, 94.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.weeklyRateKilograms), -0.7, accuracy: 1e-9)
        // The trend lags a steady decline by (1 - alpha) / alpha days: 0.9 kg here.
        XCTAssertEqual(try XCTUnwrap(summary.trendKilograms), 95.0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.changeLast7Days), -0.7, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.goalProgress), 0.5, accuracy: 0.01)
        XCTAssertFalse(summary.goalReached)
        XCTAssertEqual(try XCTUnwrap(summary.bodyMassIndex), 95.0 / 4, accuracy: 0.01)

        // 5 kg to go at 0.1 kg/day: about 50 days after the last weigh-in.
        let projected = try XCTUnwrap(summary.projectedGoalDate)
        let days = calendar.dateComponents([.day], from: date(60), to: projected).day!
        XCTAssertEqual(Double(days), 50, accuracy: 1)
    }

    func testNoProjectionWhenMovingAwayFromGoal() {
        let entries = (1...20).map { WeighIn(date: date($0), kilograms: 80 + 0.1 * Double($0), source: .manual) }
        let summary = JournalAnalysis(entries: entries, calendar: calendar).summary(goalKilograms: 75, heightCentimeters: nil)
        XCTAssertNil(summary.projectedGoalDate)
        XCTAssertEqual(summary.goalProgress, 0)
        XCTAssertNil(summary.bodyMassIndex)
    }

    func testEmptySummary() {
        let summary = JournalAnalysis(entries: [], calendar: calendar).summary(goalKilograms: 70, heightCentimeters: 180)
        XCTAssertEqual(summary.weighInCount, 0)
        XCTAssertNil(summary.trendKilograms)
        XCTAssertNil(summary.weeklyRateKilograms)
    }

    func testMilestones() {
        // Drops 1 kg per day from 100 to 85.
        let entries = (0...15).map { WeighIn(date: date($0 + 1), kilograms: 100 - Double($0), source: .manual) }
        let milestones = JournalAnalysis(entries: entries, calendar: calendar).milestones(stepKilograms: 5, goalKilograms: 93)
        let kinds = milestones.map(\.kind)
        XCTAssertEqual(kinds.first, .changed(kilograms: -5))
        XCTAssertTrue(kinds.contains(.goalReached))
        XCTAssertFalse(kinds.contains(.changed(kilograms: -10)), "the lagging trend has not dropped 10 kg yet")
        XCTAssertEqual(milestones.map(\.date), milestones.map(\.date).sorted())
    }
}
