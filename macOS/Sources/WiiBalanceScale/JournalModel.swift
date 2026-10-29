import Foundation
import WiiBalanceCore

enum Preferences {
    static let unit = "unit"
    static let autoSave = "autoSaveStableReadings"
}

/// The weight journal as seen by the interface. Every change is written to disk immediately.
final class JournalModel: ObservableObject {
    @Published private(set) var document: JournalDocument {
        didSet { analysis = JournalAnalysis(entries: document.entries) }
    }
    /// Daily averages, trend and statistics; recomputed whenever the journal changes.
    private(set) var analysis: JournalAnalysis
    /// The most recent weigh-in saved from the board, for the "Saved · Undo" banner.
    @Published private(set) var lastBoardEntry: WeighIn?
    @Published var errorMessage: String?

    let fileURL: URL

    init(fileURL: URL = JournalDocument.defaultURL) {
        self.fileURL = fileURL
        analysis = JournalAnalysis(entries: [])
        do {
            document = try JournalDocument.load(from: fileURL)
        } catch {
            // Never overwrite a journal we could not read: move it aside and start fresh.
            document = JournalDocument()
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            errorMessage = "Your journal could not be read (\(error.localizedDescription)). It was moved to \(aside.lastPathComponent) and a new journal was started."
        }
        analysis = JournalAnalysis(entries: document.entries)
    }

    var entries: [WeighIn] { document.entries }

    var summary: JournalSummary {
        analysis.summary(goalKilograms: document.goalKilograms, heightCentimeters: document.heightCentimeters)
    }

    // MARK: Editing

    @discardableResult
    func addWeighIn(kilograms: Double, date: Date = Date(), note: String = "", source: WeighIn.Source) -> WeighIn {
        let entry = WeighIn(date: date, kilograms: kilograms, note: note, source: source)
        document.add(entry)
        if source == .balanceBoard { lastBoardEntry = entry }
        persist()
        return entry
    }

    func update(_ entry: WeighIn) {
        document.update(entry)
        if lastBoardEntry?.id == entry.id { lastBoardEntry = entry }
        persist()
    }

    func delete(ids: Set<WeighIn.ID>) {
        document.remove(ids: ids)
        if let last = lastBoardEntry, ids.contains(last.id) { lastBoardEntry = nil }
        persist()
    }

    func undoLastBoardEntry() {
        guard let entry = lastBoardEntry else { return }
        delete(ids: [entry.id])
    }

    func setGoal(kilograms: Double?) {
        document.goalKilograms = kilograms
        persist()
    }

    func setHeight(centimeters: Double?) {
        document.heightCentimeters = centimeters
        persist()
    }

    // MARK: CSV

    /// Returns the number of imported weigh-ins.
    @discardableResult
    func importCSV(from url: URL, unit: WeightUnit) -> Int? {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let entries = try JournalCSV.importEntries(from: text, defaultUnit: unit)
            let added = document.merge(entries)
            persist()
            return added
        } catch {
            errorMessage = "Import failed: \(error)"
            return nil
        }
    }

    func exportCSV(to url: URL) {
        do {
            try JournalCSV.export(document.entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try document.save(to: fileURL)
        } catch {
            errorMessage = "Your journal could not be saved: \(error.localizedDescription)"
        }
    }
}
