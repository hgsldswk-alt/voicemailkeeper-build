import Foundation

private final class LocalizationBundle: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: LocalizationBundle.self), comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }

    static func count(_ count: Int) -> String {
        f(count == 1 ? "count.one" : "count.many", count)
    }

    static func duration(_ seconds: Double) -> String {
        let value = seconds.isFinite && seconds > 0 ? Int(min(seconds, 86_400).rounded(.down)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    static func isoDay(_ date: Date, zone: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(_ date: Date, zone: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date)
    }
}

enum KeeperError: String, LocalizedError {
    case unsupported, corrupt, tooLarge, disk, storage, unreadable, duplicate, invalid, badPackage, version
    case changed, authentication, cancelled, playback, failedExport

    var errorDescription: String? { L.t("error." + rawValue) }

    static func map(_ error: Error, fallback: Self = .storage) -> Self {
        if let keeper = error as? Self { return keeper }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 28 { return .disk }
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteOutOfSpaceError { return .disk }
            if ns.code == NSUserCancelledError { return .cancelled }
        }
        return fallback
    }
}

struct Person: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String

    static func normalized(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

struct Message: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var personID: UUID
    var hash: String
    var format: AudioFormat
    var filename: String
    var duration: Double
    var sourceDate: Date?
    var sourceZone: String?
    var savedAt: Date
    var savedZone: String
    var note: String
    var starred = false

    var date: Date { sourceDate ?? savedAt }
    var zone: String? { sourceDate == nil ? savedZone : sourceZone }
    var shownDate: String {
        let dateText = L.date(date, zone: zone)
        return sourceDate == nil ? L.f("date.saved", dateText) : dateText
    }
    var title: String { note.isEmpty ? filename : note }
    var blob: String { hash + "." + format.rawValue }
}

struct PersonAlias: Codable, Equatable, Hashable, Sendable {
    let sourceID: UUID
    let personID: UUID
}

struct Library: Equatable, Sendable {
    let people: [Person]
    let messages: [Message]
    let aliases: [PersonAlias]
    let lastPerson: UUID?
    let milestone: Int?
    let reviewDay: String?
    let faceLock: Bool
    private let byPerson: [UUID: [Message]]

    init(people: [Person] = [], messages: [Message] = [], aliases: [PersonAlias] = [], lastPerson: UUID? = nil,
         milestone: Int? = nil, reviewDay: String? = nil, faceLock: Bool = false) {
        self.people = people
        self.messages = messages
        self.aliases = aliases
        self.lastPerson = lastPerson
        self.milestone = milestone
        self.reviewDay = reviewDay
        self.faceLock = faceLock
        byPerson = Dictionary(grouping: messages, by: \.personID)
    }

    func messages(for person: UUID) -> [Message] { byPerson[person] ?? [] }

    func defaultImportPerson(suggestedName: String?) -> Person? {
        if let lastPerson, let person = people.first(where: { $0.id == lastPerson }) { return person }
        if let suggestedName {
            let matches = people.filter { Person.normalized($0.name) == Person.normalized(suggestedName) }
            if matches.count == 1 { return matches.first }
        }
        return people.first
    }

    func familyMatch(_ person: Person) -> Person? {
        if let id = aliases.first(where: { $0.sourceID == person.id })?.personID,
           let match = people.first(where: { $0.id == id }) { return match }
        if let match = people.first(where: { $0.id == person.id }) { return match }
        let candidates = people.filter { Person.normalized($0.name) == Person.normalized(person.name) }
        return candidates.count == 1 ? candidates.first : nil
    }
}

struct ImportProgress: Codable, Equatable, Sendable {
    var total = 0
    var days: Set<String> = []
    var milestone: Int?
    var reviewAttempt: String?
    var known: Set<String> = []
    var thirdImportDay: String?

    mutating func saved(key: String, at date: Date, zone: TimeZone = .current) {
        guard known.insert(key).inserted else { return }
        total += 1
        let day = Self.dayKey(date, zone: zone)
        if days.insert(day).inserted, days.count == 3 { thirdImportDay = day }
        if total == 1 || total == 10 { milestone = total }
    }

    static func dayKey(_ date: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return [day.year, day.month, day.day].compactMap { $0 }.map(String.init).joined(separator: "-")
    }

    func reviewDay(version: String) -> String? {
        guard reviewAttempt != version, days.count == 3 else { return nil }
        return thirdImportDay
    }
}

struct BackupStamp: Codable, Equatable, Sendable {
    var date: Date
    var people: Int
    var messages: Int

    func days(now: Date = .now) -> Int {
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0)
    }
}

enum PersonChoice: Equatable, Sendable {
    case existing(UUID)
    case new(String)
}

enum SaveOutcome: Equatable, Sendable {
    case saved
    case duplicate
    case otherPerson(String)
}
