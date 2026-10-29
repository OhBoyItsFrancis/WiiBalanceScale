import Foundation

/// CSV export/import so the journal can be backed up, opened in a spreadsheet, or seeded with
/// weights recorded elsewhere.
public enum JournalCSV {
    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case empty
        case missingColumn(String)
        case invalidRow(line: Int, reason: String)

        public var description: String {
            switch self {
            case .empty: return "The file contains no rows."
            case .missingColumn(let name): return "The file has no \(name) column."
            case .invalidRow(let line, let reason): return "Line \(line): \(reason)"
            }
        }
    }

    // MARK: Export

    public static func export(_ entries: [WeighIn]) -> String {
        var lines = ["date,weight_kg,weight_lb,note,source"]
        for entry in entries {
            let fields = [
                isoFormatter.string(from: entry.date),
                String(format: "%.2f", entry.kilograms),
                String(format: "%.2f", entry.kilograms * WeightUnit.poundsPerKilogram),
                entry.note,
                entry.source.rawValue,
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == ";" || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Import

    /// Imports a CSV with a header row. Needs a `date` column and a weight column: `weight_kg`,
    /// `weight_lb`, or any header containing "weight", "kg" or "lb". A plain "weight" column is
    /// read in `defaultUnit` (stones are read as pounds there). Optional `note` column.
    public static func importEntries(from text: String, defaultUnit: WeightUnit = .kilograms,
                                     calendar: Calendar = .current) throws -> [WeighIn] {
        let rows = parse(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let header = rows.first, rows.count > 1 else { throw ImportError.empty }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        guard let dateColumn = names.firstIndex(where: { $0.hasPrefix("date") || $0 == "day" || $0 == "time" }) else {
            throw ImportError.missingColumn("date")
        }
        let weightColumn: Int
        let weightUnit: WeightUnit
        if let index = names.firstIndex(where: { $0.contains("kg") || $0.contains("kilo") }) {
            (weightColumn, weightUnit) = (index, .kilograms)
        } else if let index = names.firstIndex(where: { $0.contains("lb") || $0.contains("pound") }) {
            (weightColumn, weightUnit) = (index, .pounds)
        } else if let index = names.firstIndex(where: { $0.contains("weight") }) {
            (weightColumn, weightUnit) = (index, defaultUnit == .stones ? .pounds : defaultUnit)
        } else {
            throw ImportError.missingColumn("weight")
        }
        let noteColumn = names.firstIndex { $0.hasPrefix("note") || $0.hasPrefix("comment") }

        var entries: [WeighIn] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            func field(_ index: Int) -> String {
                index < row.count ? row[index].trimmingCharacters(in: .whitespaces) : ""
            }
            guard let date = parseDate(field(dateColumn), calendar: calendar) else {
                throw ImportError.invalidRow(line: line, reason: "unrecognized date \"\(field(dateColumn))\"")
            }
            guard let kilograms = weightUnit.parse(field(weightColumn)) else {
                throw ImportError.invalidRow(line: line, reason: "unrecognized weight \"\(field(weightColumn))\"")
            }
            entries.append(WeighIn(date: date, kilograms: kilograms,
                                   note: noteColumn.map(field) ?? "", source: .imported))
        }
        return entries
    }

    /// Accepts ISO 8601 timestamps, "yyyy-MM-dd HH:mm[:ss]" and "yyyy-MM-dd" (in local time).
    static func parseDate(_ text: String, calendar: Calendar) -> Date? {
        if let date = isoFormatter.date(from: text) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd"] {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Minimal RFC 4180 parser: quoted fields, escaped quotes and newlines inside quotes.
    /// Files whose header uses semicolons (common where the decimal separator is a comma)
    /// are split on semicolons instead of commas.
    static func parse(_ text: String) -> [[String]] {
        let headerLine = text.prefix { !$0.isNewline }
        let delimiter: Character = headerLine.contains(";") && !headerLine.contains(",") ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextCharacter() -> Character? {
            if let character = pending { pending = nil; return character }
            return iterator.next()
        }

        while let character = nextCharacter() {
            if inQuotes {
                if character == "\"" {
                    let following = nextCharacter()
                    if following == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = following
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
            case delimiter:
                row.append(field)
                field = ""
            case _ where character.isNewline:
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
