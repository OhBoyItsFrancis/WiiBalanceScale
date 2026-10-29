import AppKit
import SwiftUI
import WiiBalanceCore

struct SettingsView: View {
    @EnvironmentObject private var journal: JournalModel
    @AppStorage(Preferences.unit) private var unit: WeightUnit = .kilograms
    @AppStorage(Preferences.autoSave) private var autoSave = true

    var body: some View {
        TabView {
            Form {
                Picker("Units", selection: $unit) {
                    ForEach(WeightUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                Toggle("Save stable readings to the journal automatically", isOn: $autoSave)
                Text("When on, a weigh-in is saved once your weight is stable (all five stars lit). You can always save manually or undo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            GoalForm(unit: unit)
                .padding(20)
                .tabItem { Label("Goal", systemImage: "flag.checkered") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Your journal is stored on this Mac at:")
                Text(journal.fileURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("A backup of the previous version is kept next to it. Use History › Import / Export to save a CSV copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([journal.fileURL])
                }
            }
            .padding(20)
            .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 480, height: 260)
    }
}

/// Edits the goal weight and height (used for BMI).
struct GoalForm: View {
    let unit: WeightUnit
    var onDone: (() -> Void)? = nil

    @EnvironmentObject private var journal: JournalModel
    @State private var goalText = ""
    @State private var centimetersText = ""
    @State private var feetText = ""
    @State private var inchesText = ""

    private var usesMetricHeight: Bool { unit == .kilograms }

    private var parsedGoal: Double?? {
        let trimmed = goalText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        return unit.parse(trimmed).map { .some($0) }
    }

    private var parsedHeight: Double?? {
        if usesMetricHeight {
            let trimmed = centimetersText.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .some(nil) }
            guard let cm = Double(trimmed.replacingOccurrences(of: ",", with: ".")), cm > 50, cm < 280 else { return nil }
            return .some(cm)
        }
        let feet = feetText.trimmingCharacters(in: .whitespaces)
        let inches = inchesText.trimmingCharacters(in: .whitespaces)
        if feet.isEmpty && inches.isEmpty { return .some(nil) }
        guard let ft = Double(feet.isEmpty ? "0" : feet), let inch = Double(inches.isEmpty ? "0" : inches) else { return nil }
        let cm = (ft * 12 + inch) * 2.54
        guard cm > 50, cm < 280 else { return nil }
        return .some(cm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Goal weight (\(unit.rawValue))", text: $goalText, prompt: Text("optional"))
                if usesMetricHeight {
                    TextField("Height (cm)", text: $centimetersText, prompt: Text("optional, for BMI"))
                } else {
                    HStack {
                        TextField("Height (ft)", text: $feetText, prompt: Text("ft"))
                        TextField("in", text: $inchesText, prompt: Text("in"))
                            .labelsHidden()
                            .frame(width: 60)
                    }
                }
            }
            if parsedGoal == nil {
                Text("Enter a goal weight in \(unit.rawValue), or leave it empty.").font(.caption).foregroundStyle(.red)
            }
            if parsedHeight == nil {
                Text("Enter a height between 50 and 280 cm, or leave it empty.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if let onDone {
                    Button("Cancel", role: .cancel) { onDone() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Save") {
                    guard let goal = parsedGoal, let height = parsedHeight else { return }
                    journal.setGoal(kilograms: goal)
                    journal.setHeight(centimeters: height)
                    onDone?()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedGoal == nil || parsedHeight == nil)
            }
        }
        .onAppear(perform: load)
        .onChange(of: unit) { _ in load() }
    }

    private func load() {
        let document = journal.document
        goalText = document.goalKilograms.map { unit.format(kilograms: $0) } ?? ""
        if let cm = document.heightCentimeters {
            centimetersText = String(format: "%.0f", cm)
            let totalInches = (cm / 2.54).rounded()
            feetText = String(Int(totalInches) / 12)
            inchesText = String(Int(totalInches) % 12)
        } else {
            centimetersText = ""
            feetText = ""
            inchesText = ""
        }
    }
}
