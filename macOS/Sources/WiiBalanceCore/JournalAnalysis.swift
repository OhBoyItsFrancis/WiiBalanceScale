import Foundation

/// The weigh-ins of one calendar day, with the smoothed trend up to that day.
public struct DailyWeight: Identifiable, Equatable {
    /// Start of the day.
    public var day: Date
    /// Mean of that day's weigh-ins.
    public var kilograms: Double
    /// Exponentially smoothed weight. Day-to-day water weight swings by a kilogram or more, so
    /// the trend is a much better indicator of real progress than any single weigh-in.
    public var trendKilograms: Double
    public var weighIns: Int

    public var id: Date { day }
}

public struct Milestone: Identifiable, Equatable {
    public enum Kind: Equatable {
        /// The trend first moved this many kilograms away from the starting weight.
        case changed(kilograms: Double)
        case goalReached
    }

    public var kind: Kind
    public var date: Date
    /// Trend weight on that day.
    public var kilograms: Double

    public var id: String {
        switch kind {
        case .changed(let kg): return "changed-\(kg)"
        case .goalReached: return "goal"
        }
    }
}

public struct JournalSummary: Equatable {
    public var weighInCount = 0
    public var daysTracked = 0
    public var startDate: Date?
    public var startKilograms: Double?
    public var latestDate: Date?
    public var latestKilograms: Double?
    public var trendKilograms: Double?
    /// Trend minus starting weight (negative means weight lost).
    public var totalChangeKilograms: Double?
    public var changeLast7Days: Double?
    public var changeLast30Days: Double?
    /// Change per week fitted over the last four weeks.
    public var weeklyRateKilograms: Double?
    public var lowestKilograms: Double?
    public var lowestDate: Date?
    public var goalKilograms: Double?
    /// Goal minus trend.
    public var remainingToGoalKilograms: Double?
    /// 0...1 of the way from the starting weight to the goal.
    public var goalProgress: Double?
    public var goalReached = false
    /// When the goal will be reached at the current weekly rate.
    public var projectedGoalDate: Date?
    public var bodyMassIndex: Double?
}

public struct JournalAnalysis {
    /// Smoothing factor per day (as in "The Hacker's Diet").
    public static let trendSmoothing = 0.1
    /// Days of data used to estimate the weekly rate.
    public static let rateWindowDays = 28

    public let daily: [DailyWeight]
    public let calendar: Calendar
    private let weighInCount: Int

    public init(entries: [WeighIn], calendar: Calendar = .current) {
        self.calendar = calendar
        self.weighInCount = entries.count

        var byDay: [Date: [Double]] = [:]
        for entry in entries {
            byDay[calendar.startOfDay(for: entry.date), default: []].append(entry.kilograms)
        }

        var daily: [DailyWeight] = []
        for day in byDay.keys.sorted() {
            let weights = byDay[day]!
            let mean = weights.reduce(0, +) / Double(weights.count)
            var trend = mean
            if let previous = daily.last {
                // Skipped days count as several smoothing steps, so the trend catches up after a gap.
                let gap = max(1, calendar.dateComponents([.day], from: previous.day, to: day).day ?? 1)
                let alpha = 1 - pow(1 - Self.trendSmoothing, Double(gap))
                trend = previous.trendKilograms + alpha * (mean - previous.trendKilograms)
            }
            daily.append(DailyWeight(day: day, kilograms: mean, trendKilograms: trend, weighIns: weights.count))
        }
        self.daily = daily
    }

    /// The last day on or before `date`.
    public func day(onOrBefore date: Date) -> DailyWeight? {
        daily.last { $0.day <= date }
    }

    public func change(overDays days: Int) -> Double? {
        guard let latest = daily.last,
              let since = calendar.date(byAdding: .day, value: -days, to: latest.day),
              let earlier = day(onOrBefore: since) else { return nil }
        return latest.trendKilograms - earlier.trendKilograms
    }

    /// Least squares slope of the daily weights over the last `rateWindowDays`, per week.
    public func weeklyRate() -> Double? {
        guard let latest = daily.last,
              let windowStart = calendar.date(byAdding: .day, value: -Self.rateWindowDays, to: latest.day) else { return nil }
        let window = daily.filter { $0.day >= windowStart }
        guard window.count >= 3, let first = window.first,
              latest.day.timeIntervalSince(first.day) >= 6 * 86_400 else { return nil }

        let xs = window.map { $0.day.timeIntervalSince(first.day) / 86_400 }
        let ys = window.map(\.kilograms)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator * 7
    }

    public func summary(goalKilograms: Double?, heightCentimeters: Double?) -> JournalSummary {
        var summary = JournalSummary()
        summary.weighInCount = weighInCount
        summary.daysTracked = daily.count
        summary.goalKilograms = goalKilograms
        guard let first = daily.first, let latest = daily.last else { return summary }

        summary.startDate = first.day
        summary.startKilograms = first.kilograms
        summary.latestDate = latest.day
        summary.latestKilograms = latest.kilograms
        summary.trendKilograms = latest.trendKilograms
        summary.totalChangeKilograms = latest.trendKilograms - first.kilograms
        summary.changeLast7Days = change(overDays: 7)
        summary.changeLast30Days = change(overDays: 30)
        summary.weeklyRateKilograms = weeklyRate()
        if let lowest = daily.min(by: { $0.kilograms < $1.kilograms }) {
            summary.lowestKilograms = lowest.kilograms
            summary.lowestDate = lowest.day
        }

        if let height = heightCentimeters, height > 0 {
            let meters = height / 100
            summary.bodyMassIndex = latest.trendKilograms / (meters * meters)
        }

        if let goal = goalKilograms {
            let remaining = goal - latest.trendKilograms
            summary.remainingToGoalKilograms = remaining
            let losing = goal < first.kilograms
            summary.goalReached = losing ? latest.trendKilograms <= goal : latest.trendKilograms >= goal
            if goal != first.kilograms {
                let progress = (first.kilograms - latest.trendKilograms) / (first.kilograms - goal)
                summary.goalProgress = min(max(progress, 0), 1)
            }
            if !summary.goalReached, let rate = summary.weeklyRateKilograms {
                let perDay = rate / 7
                if abs(perDay) > 0.0001, (remaining < 0) == (perDay < 0) {
                    let days = remaining / perDay
                    if days <= 5 * 365 {
                        summary.projectedGoalDate = calendar.date(byAdding: .day, value: Int(days.rounded(.up)), to: latest.day)
                    }
                }
            }
        }
        return summary
    }

    /// The first day the trend moved each multiple of `stepKilograms` away from the start
    /// (downwards unless the goal is above the starting weight), plus reaching the goal.
    public func milestones(stepKilograms: Double, goalKilograms: Double?) -> [Milestone] {
        guard let first = daily.first, stepKilograms > 0 else { return [] }
        let direction: Double = (goalKilograms.map { $0 > first.kilograms } ?? false) ? 1 : -1
        func crossed(_ day: DailyWeight, _ threshold: Double) -> Bool {
            direction < 0 ? day.trendKilograms <= threshold : day.trendKilograms >= threshold
        }

        var milestones: [Milestone] = []
        var step = 1
        while step <= 200 {
            let amount = Double(step) * stepKilograms
            let threshold = first.kilograms + direction * amount
            guard let day = daily.first(where: { crossed($0, threshold) }) else { break }
            milestones.append(Milestone(kind: .changed(kilograms: direction * amount), date: day.day, kilograms: day.trendKilograms))
            step += 1
        }
        if let goal = goalKilograms, goal != first.kilograms,
           let day = daily.first(where: { crossed($0, goal) }) {
            milestones.append(Milestone(kind: .goalReached, date: day.day, kilograms: day.trendKilograms))
        }
        return milestones.sorted { ($0.date, $0.kind == .goalReached ? 1 : 0) < ($1.date, $1.kind == .goalReached ? 1 : 0) }
    }
}
