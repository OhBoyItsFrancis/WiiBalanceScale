import SwiftUI
import WiiBalanceCore

/// The live scale: the original application's window, plus saving to the journal.
struct ScaleView: View {
    @EnvironmentObject private var scale: ScaleModel
    @EnvironmentObject private var journal: JournalModel
    @AppStorage(Preferences.unit) private var unit: WeightUnit = .kilograms
    @AppStorage(Preferences.autoSave) private var autoSave = true
    @State private var editingEntry: WeighIn?

    var body: some View {
        VStack(spacing: 18) {
            Picker("Units", selection: $unit) {
                ForEach(WeightUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)

            Spacer(minLength: 0)
            readout
            quality.frame(height: 48)
            status
            Spacer(minLength: 0)
            actions
            savedBanner
            comparison
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Scale")
        .sheet(item: $editingEntry) { entry in
            EntryEditor(entry: entry, unit: unit) { journal.update($0) }
        }
    }

    // MARK: Readout

    @ViewBuilder
    private var readout: some View {
        if scale.phase == .measuring, let measurement = scale.measurement {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(unit.scaleReadout(kilograms: measurement.displayKilograms))
                    .font(.system(size: 120, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                Text(unit.scaleSymbol)
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.3)
        } else {
            Text("WAIT...")
                .font(.system(size: 120, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
        }
    }

    @ViewBuilder
    private var quality: some View {
        if scale.phase == .measuring, let measurement = scale.measurement {
            HStack(spacing: 14) {
                ForEach(0..<WeightFilter.maxStars, id: \.self) { index in
                    Image(systemName: index < measurement.stars ? "star.fill" : "circle")
                        .foregroundStyle(index < measurement.stars ? Color.accentColor : Color.secondary)
                }
            }
            .font(.system(size: 34))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Accuracy \(measurement.stars) of \(WeightFilter.maxStars) stars")
        } else {
            // The original's growing row of hourglasses while waiting for the board.
            TimelineView(.periodic(from: .now, by: 0.3)) { context in
                let count = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 6
                HStack(spacing: 10) {
                    ForEach(0..<count, id: \.self) { _ in
                        Image(systemName: "hourglass")
                    }
                }
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var status: some View {
        VStack(spacing: 6) {
            Text(statusMessage)
                .font(.title3)
                .multilineTextAlignment(.center)
            if let problem = scale.lastProblem, !scale.isConnected {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 560)
    }

    private var statusMessage: String {
        switch scale.phase {
        case .idle:
            return "Starting…"
        case .bluetoothUnavailable(let message):
            return message
        case .searching:
            return "Press the red SYNC button in the battery compartment of your Wii Balance Board."
        case .connecting(let name):
            return "Connecting to \(name)…"
        case .zeroing(let waitingForEmptyBoard):
            return waitingForEmptyBoard
                ? "Please step off the board so it can be zeroed."
                : "Zeroing the scale… keep the board empty."
        case .measuring:
            guard scale.isOnBoard, let measurement = scale.measurement else {
                return "Step on the board."
            }
            if scale.recordedThisStepOn { return "Saved. You can step off the board." }
            if measurement.stars < WeightFilter.maxStars {
                return autoSave ? "Stand still… your weight is saved once all five stars are lit." : "Stand still…"
            }
            return "Stable."
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 14) {
            Button {
                scale.zero()
            } label: {
                Text("Zero").frame(minWidth: 140)
            }
            .disabled(scale.phase != .measuring)
            .help("Zero the scale using the current reading")

            Button {
                guard let measurement = scale.measurement else { return }
                journal.addWeighIn(kilograms: measurement.kilograms, source: .balanceBoard)
                scale.markSaved()
            } label: {
                Text("Save Weigh-In").frame(minWidth: 140)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!scale.isOnBoard || scale.recordedThisStepOn)
            .help("Save the current weight to your journal")
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var savedBanner: some View {
        if let entry = journal.lastBoardEntry, scale.recordedThisStepOn {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved \(unit.format(kilograms: entry.kilograms, fractionDigits: 2)) to your journal.")
                Spacer()
                Button("Add Note…") { editingEntry = entry }
                Button("Undo") {
                    journal.undoLastBoardEntry()
                    scale.markSaved(false)
                }
            }
            .padding(12)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 620)
        }
    }

    // MARK: Journal context

    @ViewBuilder
    private var comparison: some View {
        let summary = journal.summary
        let justSaved = scale.recordedThisStepOn ? journal.lastBoardEntry?.id : nil
        let previous = journal.entries.last { $0.id != justSaved }

        if previous != nil || summary.trendKilograms != nil {
            HStack(spacing: 28) {
                if let previous {
                    if scale.isOnBoard, let measurement = scale.measurement {
                        context("Since last weigh-in",
                                unit.formatChange(kilograms: measurement.kilograms - previous.kilograms),
                                previous.date.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        context("Last weigh-in", unit.format(kilograms: previous.kilograms),
                                previous.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let trend = summary.trendKilograms {
                    context("Trend", unit.format(kilograms: trend), "smoothed")
                }
                if let total = summary.totalChangeKilograms, summary.daysTracked > 1 {
                    context("Total change", unit.formatChange(kilograms: total),
                            summary.startDate.map { "since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
                }
                if let remaining = summary.remainingToGoalKilograms {
                    context("Goal", summary.goalReached ? "Reached!" : unit.formatAmount(kilograms: remaining),
                            summary.goalReached ? "well done" : "to go")
                }
            }
            .padding(.top, 6)
        }
    }

    private func context(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
