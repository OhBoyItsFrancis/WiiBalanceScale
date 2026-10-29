import Foundation

/// One recorded weight.
public struct WeighIn: Codable, Identifiable, Hashable {
    public enum Source: String, Codable {
        /// Measured with the Balance Board.
        case balanceBoard
        /// Typed in by hand.
        case manual
        /// Imported from a CSV file.
        case imported
    }

    public var id: UUID
    public var date: Date
    public var kilograms: Double
    public var note: String
    public var source: Source

    public init(id: UUID = UUID(), date: Date, kilograms: Double, note: String = "", source: Source) {
        self.id = id
        self.date = date
        self.kilograms = kilograms
        self.note = note
        self.source = source
    }
}

/// Everything the weight journal stores: the weigh-ins plus goal and height.
public struct JournalDocument: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Sorted by date, oldest first.
    public private(set) var entries: [WeighIn]
    public var goalKilograms: Double?
    public var heightCentimeters: Double?

    public init(entries: [WeighIn] = [], goalKilograms: Double? = nil, heightCentimeters: Double? = nil) {
        self.version = Self.currentVersion
        self.entries = entries.sorted { $0.date < $1.date }
        self.goalKilograms = goalKilograms
        self.heightCentimeters = heightCentimeters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        entries = try container.decodeIfPresent([WeighIn].self, forKey: .entries) ?? []
        entries.sort { $0.date < $1.date }
        goalKilograms = try container.decodeIfPresent(Double.self, forKey: .goalKilograms)
        heightCentimeters = try container.decodeIfPresent(Double.self, forKey: .heightCentimeters)
    }

    // MARK: Editing

    public mutating func add(_ entry: WeighIn) {
        let index = entries.firstIndex { $0.date > entry.date } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    public mutating func update(_ entry: WeighIn) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries.remove(at: index)
        add(entry)
    }

    public mutating func remove(ids: Set<WeighIn.ID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    /// Adds entries, skipping ones that duplicate an existing weigh-in (same minute, within 50 g).
    /// Returns the number of entries added.
    @discardableResult
    public mutating func merge(_ newEntries: [WeighIn]) -> Int {
        var added = 0
        for entry in newEntries {
            let duplicate = entries.contains {
                abs($0.date.timeIntervalSince(entry.date)) < 60 && abs($0.kilograms - entry.kilograms) < 0.05
            }
            if !duplicate {
                add(entry)
                added += 1
            }
        }
        return added
    }

    public func entry(id: WeighIn.ID) -> WeighIn? {
        entries.first { $0.id == id }
    }

    /// The weigh-in recorded just before the given one.
    public func previous(to entry: WeighIn) -> WeighIn? {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return nil }
        return entries[index - 1]
    }

    // MARK: Persistence

    /// ~/Library/Application Support/WiiBalanceScale/journal.json
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("WiiBalanceScale", isDirectory: true)
            .appendingPathComponent("journal.json")
    }

    public static func load(from url: URL) throws -> JournalDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return JournalDocument() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JournalDocument.self, from: Data(contentsOf: url))
    }

    /// Writes the journal atomically. The previous version is kept next to it as a backup.
    public func save(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        if fileManager.fileExists(atPath: url.path) {
            let backup = url.deletingPathExtension().appendingPathExtension("backup.json")
            try? fileManager.removeItem(at: backup)
            try? fileManager.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }
}
