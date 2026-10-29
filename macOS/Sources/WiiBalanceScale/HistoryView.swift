import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WiiBalanceCore

/// Every weigh-in, newest first, with editing, manual entry and CSV import/export.
struct HistoryView: View {
    private struct Row: Identifiable {
        let entry: WeighIn
        let change: Double?
        var id: UUID { entry.id }
    }

    private enum EditorTarget: Identifiable {
        case new
        case existing(WeighIn)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let entry): return entry.id.uuidString
            }
        }
    }

    @EnvironmentObject private var journal: JournalModel
    @AppStorage(Preferences.unit) private var unit: WeightUnit = .kilograms
    @State private var selection = Set<WeighIn.ID>()
    @State private var editorTarget: EditorTarget?
    @State private var pendingDeletion = Set<WeighIn.ID>()
    @State private var importMessage: String?

    private var rows: [Row] {
        let entries = journal.entries
        return entries.indices.reversed().map { index in
            Row(entry: entries[index], change: index > 0 ? entries[index].kilograms - entries[index - 1].kilograms : nil)
        }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Date") { row in
                Text(row.entry.date.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 140, ideal: 170)
            TableColumn("Weight") { row in
                Text(unit.format(kilograms: row.entry.kilograms, fractionDigits: unit == .stones ? 1 : 2))
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            TableColumn("Change") { row in
                if let change = row.change {
                    Text(unit.formatChange(kilograms: change))
                        .monospacedDigit()
                        .foregroundStyle(change < -0.05 ? Color.green : (change > 0.05 ? Color.orange : Color.secondary))
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn("Note") { row in
                Text(row.entry.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.entry.note)
            }
            TableColumn("Source") { row in
                Image(systemName: icon(for: row.entry.source))
                    .foregroundStyle(.secondary)
                    .help(description(for: row.entry.source))
            }
            .width(50)
        }
        .contextMenu(forSelectionType: WeighIn.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let entry = journal.document.entry(id: id) {
                Button("Edit…") { editorTarget = .existing(entry) }
            }
            if !ids.isEmpty {
                Button("Delete", role: .destructive) { pendingDeletion = ids }
            }
        } primaryAction: { ids in
            if let id = ids.first, let entry = journal.document.entry(id: id) {
                editorTarget = .existing(entry)
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty { pendingDeletion = selection }
        }
        .overlay {
            if journal.entries.isEmpty {
                VStack(spacing: 8) {
                    Text("No weigh-ins yet").font(.title3.weight(.semibold))
                    Text("Weigh-ins from the Balance Board appear here. Use + to add a weight by hand, or import a CSV file.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 380)
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editorTarget = .new
                } label: {
                    Label("Add Weigh-In", systemImage: "plus")
                }
                .help("Add a weigh-in by hand")

                Menu {
                    Button("Import CSV…", action: importCSV)
                    Button("Export CSV…", action: exportCSV)
                        .disabled(journal.entries.isEmpty)
                } label: {
                    Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Import or export your journal as CSV")
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                EntryEditor(entry: nil, unit: unit) { entry in
                    journal.addWeighIn(kilograms: entry.kilograms, date: entry.date, note: entry.note, source: .manual)
                }
            case .existing(let entry):
                EntryEditor(entry: entry, unit: unit) { journal.update($0) }
            }
        }
        .confirmationDialog(
            pendingDeletion.count == 1 ? "Delete this weigh-in?" : "Delete \(pendingDeletion.count) weigh-ins?",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
        ) {
            Button("Delete", role: .destructive) {
                journal.delete(ids: pendingDeletion)
                selection.subtract(pendingDeletion)
                pendingDeletion = []
            }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func icon(for source: WeighIn.Source) -> String {
        switch source {
        case .balanceBoard: return "scalemass"
        case .manual: return "pencil"
        case .imported: return "square.and.arrow.down"
        }
    }

    private func description(for source: WeighIn.Source) -> String {
        switch source {
        case .balanceBoard: return "Measured with the Balance Board"
        case .manual: return "Entered by hand"
        case .imported: return "Imported"
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CSV file with a date column and a weight column (kg or lb)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let added = journal.importCSV(from: url, unit: unit) {
            importMessage = added == 1 ? "Imported 1 weigh-in." : "Imported \(added) weigh-ins."
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Weight Journal.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        journal.exportCSV(to: url)
    }
}

/// Adds or edits a single weigh-in.
struct EntryEditor: View {
    let entry: WeighIn?
    let unit: WeightUnit
    let onSave: (WeighIn) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var weightText: String
    @State private var note: String
    private let initialWeightText: String

    init(entry: WeighIn?, unit: WeightUnit, onSave: @escaping (WeighIn) -> Void) {
        self.entry = entry
        self.unit = unit
        self.onSave = onSave
        let text = entry.map { unit.format(kilograms: $0.kilograms, fractionDigits: unit == .stones ? 1 : 2) } ?? ""
        initialWeightText = text
        _date = State(initialValue: entry?.date ?? Date())
        _weightText = State(initialValue: text)
        _note = State(initialValue: entry?.note ?? "")
    }

    private var parsedKilograms: Double? {
        // Keep the full precision of board measurements when only the note or date is edited.
        if let entry, weightText == initialWeightText { return entry.kilograms }
        return unit.parse(weightText)
    }

    private var weightPrompt: String {
        switch unit {
        case .kilograms: return "e.g. 82.5"
        case .pounds: return "e.g. 181.6"
        case .stones: return "e.g. 12 st 13.5 lb"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry == nil ? "Add Weigh-In" : "Edit Weigh-In")
                .font(.title2.weight(.semibold))
            Form {
                DatePicker("Date", selection: $date, in: ...Date().addingTimeInterval(86_400),
                           displayedComponents: [.date, .hourAndMinute])
                TextField("Weight (\(unit.rawValue))", text: $weightText, prompt: Text(weightPrompt))
                TextField("Note", text: $note, prompt: Text("Optional, e.g. \"after the holidays\""), axis: .vertical)
                    .lineLimit(2...4)
            }
            if !weightText.isEmpty && parsedKilograms == nil {
                Text("Enter a weight such as \(weightPrompt.replacingOccurrences(of: "e.g. ", with: "")).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let kilograms = parsedKilograms else { return }
                    var saved = entry ?? WeighIn(date: date, kilograms: kilograms, source: .manual)
                    saved.date = date
                    saved.kilograms = kilograms
                    saved.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedKilograms == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
