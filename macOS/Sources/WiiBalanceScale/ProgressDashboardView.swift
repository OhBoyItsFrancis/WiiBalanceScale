import Charts
import SwiftUI
import WiiBalanceCore

enum ChartRange: String, CaseIterable, Identifiable {
    case month = "1M"
    case quarter = "3M"
    case halfYear = "6M"
    case year = "1Y"
    case all = "All"

    var id: Self { self }

    var days: Int? {
        switch self {
        case .month: return 31
        case .quarter: return 92
        case .halfYear: return 183
        case .year: return 366
        case .all: return nil
        }
    }
}

/// Overview of the weight loss journey: statistics, chart, goal and milestones.
struct ProgressDashboardView: View {
    @EnvironmentObject private var journal: JournalModel
    @AppStorage(Preferences.unit) private var unit: WeightUnit = .kilograms
    @AppStorage("chartRange") private var range: ChartRange = .quarter
    @State private var showingGoalEditor = false

    var body: some View {
        let summary = journal.summary
        ScrollView {
            if summary.weighInCount == 0 {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    statistics(summary)
                    chartSection
                    goalSection(summary)
                    milestonesSection
                }
                .padding(24)
            }
        }
        .navigationTitle("Progress")
        .toolbar {
            ToolbarItem {
                Button {
                    showingGoalEditor = true
                } label: {
                    Label("Goal…", systemImage: "flag.checkered")
                }
                .help("Set your goal weight and height")
            }
        }
        .sheet(isPresented: $showingGoalEditor) {
            GoalForm(unit: unit) { showingGoalEditor = false }
                .environmentObject(journal)
                .padding()
                .frame(width: 420)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No weigh-ins yet")
                .font(.title2.weight(.semibold))
            Text("Step on the Balance Board to record your first weigh-in, or add past weights in History.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    // MARK: Statistics

    private func statistics(_ summary: JournalSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            if let latest = summary.latestKilograms, let date = summary.latestDate {
                StatCard(title: "Latest", value: unit.format(kilograms: latest),
                         detail: date.formatted(date: .abbreviated, time: .omitted))
            }
            if let trend = summary.trendKilograms {
                StatCard(title: "Trend", value: unit.format(kilograms: trend), detail: "smoothed daily weight")
            }
            if let total = summary.totalChangeKilograms, let start = summary.startKilograms, let date = summary.startDate {
                StatCard(title: "Total change", value: unit.formatChange(kilograms: total),
                         detail: "from \(unit.format(kilograms: start)) on \(date.formatted(date: .abbreviated, time: .omitted))",
                         tint: changeColor(total))
            }
            if let change = summary.changeLast7Days {
                StatCard(title: "Last 7 days", value: unit.formatChange(kilograms: change), detail: "trend change",
                         tint: changeColor(change))
            }
            if let change = summary.changeLast30Days {
                StatCard(title: "Last 30 days", value: unit.formatChange(kilograms: change), detail: "trend change",
                         tint: changeColor(change))
            }
            if let rate = summary.weeklyRateKilograms {
                StatCard(title: "Weekly rate", value: unit.formatChange(kilograms: rate) + "/wk",
                         detail: "over the last 4 weeks", tint: changeColor(rate))
            }
            if let lowest = summary.lowestKilograms, let date = summary.lowestDate {
                StatCard(title: "Lowest", value: unit.format(kilograms: lowest),
                         detail: date.formatted(date: .abbreviated, time: .omitted))
            }
            if let bmi = summary.bodyMassIndex {
                StatCard(title: "BMI", value: String(format: "%.1f", bmi), detail: bmiCategory(bmi))
            }
            StatCard(title: "Weigh-ins", value: "\(summary.weighInCount)", detail: "on \(summary.daysTracked) days")
        }
    }

    private func changeColor(_ change: Double) -> Color {
        // Lower is better unless the goal is to gain weight.
        let goalIsGain = journal.document.goalKilograms.map { $0 > (journal.summary.startKilograms ?? $0) } ?? false
        if abs(change) < 0.05 { return .primary }
        return (change < 0) != goalIsGain ? .green : .orange
    }

    private func bmiCategory(_ bmi: Double) -> String {
        switch bmi {
        case ..<18.5: return "underweight"
        case ..<25: return "healthy range"
        case ..<30: return "overweight"
        default: return "obese range"
        }
    }

    // MARK: Chart

    private var chartSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Weight over time").font(.headline)
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                WeightChart(days: visibleDays, unit: unit, goalKilograms: journal.document.goalKilograms)
                    .frame(height: 300)
                HStack(spacing: 18) {
                    legend(symbol: "circle.fill", color: .secondary, text: "Daily weight")
                    legend(symbol: "line.diagonal", color: .accentColor, text: "Trend")
                    if journal.document.goalKilograms != nil {
                        legend(symbol: "line.horizontal.3", color: .green, text: "Goal")
                    }
                }
                .font(.caption)
            }
            .padding(8)
        }
    }

    private var visibleDays: [DailyWeight] {
        let daily = journal.analysis.daily
        guard let days = range.days, let latest = daily.last,
              let start = Calendar.current.date(byAdding: .day, value: -days, to: latest.day) else { return daily }
        return daily.filter { $0.day >= start }
    }

    private func legend(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: Goal

    @ViewBuilder
    private func goalSection(_ summary: JournalSummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Goal").font(.headline)
                if let goal = summary.goalKilograms {
                    SwiftUI.ProgressView(value: summary.goalProgress ?? 0)
                        .tint(.green)
                    HStack {
                        Text(summary.startKilograms.map { unit.format(kilograms: $0) } ?? "")
                        Spacer()
                        if summary.goalReached {
                            Text("Goal reached!").fontWeight(.semibold).foregroundStyle(.green)
                        } else if let progress = summary.goalProgress, let remaining = summary.remainingToGoalKilograms {
                            Text(verbatim: "\(Int((progress * 100).rounded()))% there · \(unit.formatAmount(kilograms: remaining)) to go")
                        }
                        Spacer()
                        Text(unit.format(kilograms: goal))
                    }
                    .font(.callout)
                    .monospacedDigit()
                    if !summary.goalReached {
                        Text(projectionText(summary))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Set a goal weight to track your progress towards it and see when you are likely to reach it.")
                        .foregroundStyle(.secondary)
                    Button("Set Goal…") { showingGoalEditor = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func projectionText(_ summary: JournalSummary) -> String {
        if let date = summary.projectedGoalDate {
            return "At your current rate you will reach your goal around \(date.formatted(date: .long, time: .omitted))."
        }
        if summary.weeklyRateKilograms == nil {
            return "Weigh in a few times over at least a week to see when you will reach your goal."
        }
        return "Your recent trend is not heading towards your goal yet. Keep going!"
    }

    // MARK: Milestones

    @ViewBuilder
    private var milestonesSection: some View {
        let milestones = journal.analysis.milestones(stepKilograms: unit.milestoneStepKilograms,
                                                     goalKilograms: journal.document.goalKilograms)
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Milestones").font(.headline)
                if milestones.isEmpty {
                    Text("Your first milestone is \(unit.formatAmount(kilograms: unit.milestoneStepKilograms)) of trend change from your starting weight.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(milestones.reversed()) { milestone in
                        HStack {
                            Image(systemName: milestone.kind == .goalReached ? "flag.checkered" : "rosette")
                                .foregroundStyle(milestone.kind == .goalReached ? Color.green : Color.accentColor)
                                .frame(width: 22)
                            Text(title(for: milestone))
                            Spacer()
                            Text(milestone.date.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func title(for milestone: Milestone) -> String {
        switch milestone.kind {
        case .goalReached:
            return "Reached your goal of \(journal.document.goalKilograms.map { unit.format(kilograms: $0) } ?? "")"
        case .changed(let kilograms):
            let amount = unit.formatAmount(kilograms: kilograms, fractionDigits: unit == .kilograms ? 1 : 0)
            return kilograms < 0 ? "Lost \(amount)" : "Gained \(amount)"
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WeightChart: View {
    let days: [DailyWeight]
    let unit: WeightUnit
    let goalKilograms: Double?

    var body: some View {
        Chart {
            ForEach(days) { day in
                PointMark(
                    x: .value("Date", day.day, unit: .day),
                    y: .value("Weight", unit.axisValue(fromKilograms: day.kilograms)))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .symbolSize(22)
            }
            ForEach(days) { day in
                LineMark(
                    x: .value("Date", day.day, unit: .day),
                    y: .value("Trend", unit.axisValue(fromKilograms: day.trendKilograms)))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.monotone)
            }
            if let goalKilograms {
                RuleMark(y: .value("Goal", unit.axisValue(fromKilograms: goalKilograms)))
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxisLabel { Text(unit.axisSymbol) }
    }

    /// Fits the weights (and the goal), instead of starting the axis at zero.
    private var yDomain: ClosedRange<Double> {
        var values = days.flatMap { [$0.kilograms, $0.trendKilograms] }
        if let goalKilograms { values.append(goalKilograms) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.1, 0.5)
        return unit.axisValue(fromKilograms: low - padding)...unit.axisValue(fromKilograms: high + padding)
    }
}
