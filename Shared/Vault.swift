import Foundation

struct Vault: Sendable {
    let root: URL
    private var blobs: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    private var inbox: URL { root.appendingPathComponent("Pending", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("Library.sqlite3") }

    init(root: URL) throws {
        self.root = root
        try VaultFiles.directory(root)
        try VaultFiles.directory(blobs)
        try VaultFiles.directory(inbox)
        let db = try Database(index)
        try db.transaction {
            try db.run("""
                CREATE TABLE IF NOT EXISTS people(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(
                    id TEXT PRIMARY KEY, person TEXT NOT NULL REFERENCES people(id),
                    hash TEXT NOT NULL, blob TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(person, hash)
                );
                CREATE INDEX IF NOT EXISTS message_hash ON messages(hash);
                CREATE INDEX IF NOT EXISTS message_blob ON messages(blob);
                CREATE TABLE IF NOT EXISTS aliases(
                    source TEXT PRIMARY KEY, person TEXT NOT NULL REFERENCES people(id)
                );
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                """)
        }
        try FileManager.default.setAttributes(VaultFiles.protection, ofItemAtPath: index.path)
    }

    func state() throws -> Library {
        let db = try Database(index)
        return try db.transaction(write: false) { try read(db) }
    }

    func faceLocked() throws -> Bool {
        try value(Database(index), key: "lock", default: false)
    }

    func setFaceLock(_ enabled: Bool) throws {
        try put(Database(index), key: "lock", value: enabled)
    }

    func stamp() throws -> BackupStamp? {
        try value(Database(index), key: "stamp", default: Optional<BackupStamp>.none)
    }

    func recordBackup(_ stamp: BackupStamp) throws {
        try put(Database(index), key: "stamp", value: stamp)
    }

    func dismissMilestone() throws {
        let db = try Database(index)
        try db.transaction {
            var progress = try progress(db)
            progress.milestone = nil
            try put(db, key: "progress", value: progress)
        }
    }

    func claimReview(version: String, now: Date = .now, zone: TimeZone = .current) throws -> Bool {
        let db = try Database(index)
        return try db.transaction {
            var progress = try progress(db)
            guard progress.reviewDay(version: version) == ImportProgress.dayKey(now, zone: zone) else { return false }
            progress.reviewAttempt = version
            try put(db, key: "progress", value: progress)
            return true
        }
    }

    func releaseReview(version: String) throws {
        let db = try Database(index)
        try db.transaction {
            var progress = try progress(db)
            guard progress.reviewAttempt == version else { return }
            progress.reviewAttempt = nil
            try put(db, key: "progress", value: progress)
        }
    }

    func save(_ draft: AudioDraft, choice: PersonChoice, note: String, date: Date?, zone: String?,
              allowOtherPerson: Bool = false, now: Date = .now, zoneAtSave: TimeZone = .current,
              trackProgress: Bool = true) throws -> SaveOutcome {
        let db = try Database(index)
        return try transactionWithFiles(db) {
            let person: Person
            let isNew: Bool
            switch choice {
            case .existing(let id):
                guard let found = try getPerson(db, id: id) else { throw KeeperError.changed }
                person = found
                isNew = false
            case .new(let name):
                person = Person(name: try Self.checkedName(name))
                isNew = true
            }
            let existing = try db.rows("SELECT payload FROM messages WHERE hash = ?", [.text(draft.hash)]) {
                try db.decode($0, as: Message.self)
            }
            if let previous = existing.first(where: { $0.personID == person.id }) {
                try store(draft, for: previous)
                if let source = draft.family?.id { try putAlias(db, source: source, person: person.id, replace: true) }
                try put(db, key: "last", value: person.id)
                return .duplicate
            }
            if !allowOtherPerson, let first = existing.first,
               let other = try getPerson(db, id: first.personID) {
                return .otherPerson(other.name)
            }
            let cleanNote = try Self.checkedNote(note)
            try Task.checkCancellation()
            if isNew { try insert(db, person: person) }
            let message = Message(personID: person.id, hash: draft.hash, format: draft.format, filename: draft.filename,
                                  duration: draft.duration, sourceDate: date, sourceZone: zone, savedAt: now,
                                  savedZone: zoneAtSave.identifier, note: cleanNote, starred: draft.familyMessage?.starred ?? false)
            try store(draft, for: message)
            try insert(db, message: message)
            if let source = draft.family?.id { try putAlias(db, source: source, person: person.id, replace: true) }
            try put(db, key: "last", value: person.id)
            if trackProgress {
                var progress = try progress(db)
                progress.saved(key: person.id.uuidString + ":" + message.hash, at: now, zone: zoneAtSave)
                try put(db, key: "progress", value: progress)
            }
            try Task.checkCancellation()
            return .saved
        }
    }

    func setStar(_ id: UUID) throws {
        let db = try Database(index)
        try db.transaction {
            var message = try getMessage(db, id: id)
            message.starred.toggle()
            try update(db, message: message)
        }
    }

    func edit(_ id: UUID, person: UUID, note: String, date: Date?, zone: String?) throws {
        let db = try Database(index)
        try db.transaction {
            var message = try getMessage(db, id: id)
            try assign(&message, to: person, using: db)
            message.note = try Self.checkedNote(note)
            message.sourceDate = date
            message.sourceZone = zone
            try update(db, message: message)
        }
    }

    func move(_ id: UUID, to person: UUID) throws {
        let db = try Database(index)
        try db.transaction {
            var message = try getMessage(db, id: id)
            try assign(&message, to: person, using: db)
            try update(db, message: message)
        }
    }

    func remove(_ id: UUID) throws {
        let db = try Database(index)
        try db.transaction {
            _ = try getMessage(db, id: id)
            try db.execute("DELETE FROM messages WHERE id = ?", [.text(id.uuidString)])
        }
        try? collectOrphans()
    }

    func originalURL(_ message: Message) -> URL { blobs.appendingPathComponent(message.blob) }

    func exportFull() throws -> ExportFile {
        try export { db, directory in
            let library = try read(db)
            let index = PackageIndex(kind: .backup, people: library.people, messages: library.messages, aliases: library.aliases)
            return try Packages.make(index, in: directory, blobs: blobs)
        }
    }

    func exportPerson(_ id: UUID) throws -> ExportFile {
        try export { db, directory in
            guard let person = try getPerson(db, id: id) else { throw KeeperError.changed }
            let messages = try db.rows("SELECT payload FROM messages WHERE person = ?", [.text(id.uuidString)]) {
                try db.decode($0, as: Message.self)
            }.sorted { $0.date > $1.date }
            return try Packages.person(person, messages: messages, in: directory, blobs: blobs)
        }
    }

    func exportMessage(_ id: UUID, family: Bool) throws -> ExportFile {
        try export { db, directory in
            let message = try getMessage(db, id: id)
            if family {
                guard let person = try getPerson(db, id: message.personID) else { throw KeeperError.changed }
                let package = PackageIndex(kind: .family, people: [person], messages: [message], aliases: [])
                return try Packages.make(package, in: directory, blobs: blobs)
            }
            let url = directory.appendingPathComponent(message.filename)
            try VaultFiles.copy(originalURL(message), to: url, limit: VaultFiles.audioLimit, coordinate: false)
            guard try VaultFiles.hash(url) == message.hash else { throw KeeperError.corrupt }
            return ExportFile(directory: directory, url: url)
        }
    }

    func previewRestore(_ source: URL) throws -> RestoreDraft {
        let directory = try VaultFiles.temporary()
        do {
            let (index, archive) = try Packages.read(source, in: directory, kind: .backup)
            let result = Self.merge(local: try state(), incoming: index)
            return RestoreDraft(directory: directory, index: index, plan: result.plan, archive: archive)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw KeeperError.map(error, fallback: .badPackage)
        }
    }

    func restore(_ draft: RestoreDraft) throws -> RestorePlan {
        let db = try Database(index)
        return try transactionWithFiles(db) {
            let result = Self.merge(local: try read(db), incoming: draft.index)
            guard result.plan == draft.plan else { throw KeeperError.changed }
            var verified = Set<String>()
            for message in draft.index.messages where verified.insert(message.blob).inserted {
                try Task.checkCancellation()
                let original = originalURL(message)
                if (try? VaultFiles.hash(original)) != message.hash {
                    let bytes = try draft.bytes(for: message)
                    try VaultFiles.requireSpace(at: blobs, bytes: bytes.count)
                    let temp = blobs.appendingPathComponent("." + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try bytes.write(to: temp, options: [.atomic, .completeFileProtection])
                    guard try VaultFiles.hash(temp) == message.hash else { throw KeeperError.badPackage }
                    try install(temp, at: original)
                }
            }
            for person in result.people { try insert(db, person: person) }
            for message in result.messages { try insert(db, message: message) }
            for alias in draft.index.aliases {
                try putAlias(db, source: alias.sourceID, person: alias.personID, replace: false)
            }
            try Task.checkCancellation()
            return result.plan
        }
    }

    static func merge(local: Library, incoming: PackageIndex) -> (plan: RestorePlan, people: [Person], messages: [Message]) {
        let personIDs = Set(local.people.map(\.id))
        var messageIDs = Set(local.messages.map(\.id))
        let names = Set(local.people.map { Person.normalized($0.name) })
        let people = incoming.people.filter { !personIDs.contains($0.id) }
        let sameNames = Set(people.filter { names.contains(Person.normalized($0.name)) }.map(\.id))
        var fingerprints = Set(local.messages.map { $0.personID.uuidString + ":" + $0.hash })
        var messages: [Message] = []
        var plan = RestorePlan()
        for var message in incoming.messages {
            guard fingerprints.insert(message.personID.uuidString + ":" + message.hash).inserted else {
                plan.duplicates += 1
                continue
            }
            let idConflict = !messageIDs.insert(message.id).inserted
            if idConflict {
                repeat { message.id = UUID() } while !messageIDs.insert(message.id).inserted
            }
            if idConflict || sameNames.contains(message.personID) { plan.conflicts += 1 }
            messages.append(message)
            plan.added += 1
        }
        return (plan, people, messages)
    }

    func collectOrphans() throws {
        let db = try Database(index)
        try db.transaction {
            let known = Set(try db.rows("SELECT DISTINCT blob FROM messages") { try Database.text($0) })
            let files = try FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)
            for url in files where !known.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func queuePending(_ staged: URL) throws {
        let name = VaultFiles.safeName(staged.lastPathComponent)
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try VaultFiles.directory(folder)
        do {
            let temporary = folder.appendingPathComponent(".partial")
            try VaultFiles.copy(staged, to: temporary, limit: VaultFiles.audioLimit, coordinate: false)
            try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func pending() throws -> [URL] {
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])
        return try folders.sorted { left, right in
            let a = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }.compactMap {
            try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).first
        }
    }

    func removePending(_ url: URL) throws {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent() == inbox, UUID(uuidString: folder.lastPathComponent) != nil else {
            throw KeeperError.invalid
        }
        try FileManager.default.removeItem(at: folder)
    }

    private func export(_ operation: (Database, URL) throws -> ExportFile) throws -> ExportFile {
        let db = try Database(index)
        let directory = try VaultFiles.temporary()
        do { return try db.transaction { try operation(db, directory) } }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func store(_ draft: AudioDraft, for message: Message) throws {
        let original = originalURL(message)
        if (try? VaultFiles.hash(original)) == draft.hash { return }
        let temporary = blobs.appendingPathComponent("." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try VaultFiles.copy(draft.url, to: temporary, limit: VaultFiles.audioLimit, coordinate: false)
        guard try VaultFiles.hash(temporary) == draft.hash else { throw KeeperError.corrupt }
        try install(temporary, at: original)
    }

    private func transactionWithFiles<T>(_ db: Database, _ action: () throws -> T) throws -> T {
        do { return try db.transaction(action) }
        catch {
            try? collectOrphans()
            throw error
        }
    }

    private func install(_ incoming: URL, at target: URL) throws {
        let handle = try FileHandle(forWritingTo: incoming)
        defer { try? handle.close() }
        try handle.synchronize()
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            try fm.replaceItemAt(target, withItemAt: incoming, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: incoming, to: target)
        }
    }

    private func read(_ db: Database) throws -> Library {
        let people = try db.rows("SELECT payload FROM people") { try db.decode($0, as: Person.self) }
        let messages = try db.rows("SELECT payload FROM messages") { try db.decode($0, as: Message.self) }
        let aliases = try db.rows("SELECT source, person FROM aliases") {
            guard let source = UUID(uuidString: try Database.text($0)),
                  let person = UUID(uuidString: try Database.text($0, at: 1)) else { throw KeeperError.storage }
            return PersonAlias(sourceID: source, personID: person)
        }
        let last = try value(db, key: "last", default: Optional<UUID>.none)
        let progress = try progress(db)
        let lock = try value(db, key: "lock", default: false)
        return Library(people: people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                       messages: messages.sorted { $0.date > $1.date }, aliases: aliases, lastPerson: last,
                       milestone: progress.milestone, reviewDay: progress.reviewDay(version: Launch.runningVersion),
                       faceLock: lock)
    }

    #if DEBUG
    func seedReviewDays(_ days: Set<String>) throws {
        guard Launch.testing else { return }
        try put(Database(index), key: "progress", value: ImportProgress(total: days.count, days: days, milestone: 1))
    }
    #endif

    private func progress(_ db: Database) throws -> ImportProgress {
        try value(db, key: "progress", default: ImportProgress())
    }

    private func value<T: Decodable>(_ db: Database, key: String, default defaultValue: T) throws -> T {
        let existing = try db.rows("SELECT payload FROM settings WHERE key = ?", [.text(key)]) { try db.decode($0, as: T.self) }
        return existing.first ?? defaultValue
    }

    private func put<T: Encodable>(_ db: Database, key: String, value: T) throws {
        try db.execute("INSERT OR REPLACE INTO settings VALUES(?, ?)", [.text(key), try encoded(value)])
    }

    private func getPerson(_ db: Database, id: UUID) throws -> Person? {
        try db.rows("SELECT payload FROM people WHERE id = ?", [.text(id.uuidString)]) { try db.decode($0, as: Person.self) }.first
    }

    private func getMessage(_ db: Database, id: UUID) throws -> Message {
        guard let result = try db.rows("SELECT payload FROM messages WHERE id = ?", [.text(id.uuidString)],
                                       decode: { try db.decode($0, as: Message.self) }).first else { throw KeeperError.changed }
        return result
    }

    private func putAlias(_ db: Database, source: UUID, person: UUID, replace: Bool) throws {
        let rule = replace ? "REPLACE" : "IGNORE"
        try db.execute("INSERT OR \(rule) INTO aliases VALUES(?, ?)", [.text(source.uuidString), .text(person.uuidString)])
    }

    private func insert(_ db: Database, person: Person) throws {
        try db.execute("INSERT INTO people VALUES(?, ?)", [.text(person.id.uuidString), try encoded(person)])
    }

    private func insert(_ db: Database, message: Message) throws {
        try db.execute("INSERT INTO messages VALUES(?, ?, ?, ?, ?)",
                       [.text(message.id.uuidString), .text(message.personID.uuidString), .text(message.hash),
                        .text(message.blob), try encoded(message)])
    }

    private func assign(_ message: inout Message, to person: UUID, using db: Database) throws {
        guard try getPerson(db, id: person) != nil else { throw KeeperError.changed }
        if message.personID != person,
           try !db.rows("SELECT id FROM messages WHERE person = ? AND hash = ?", [.text(person.uuidString), .text(message.hash)],
                        decode: { try Database.text($0) }).isEmpty { throw KeeperError.duplicate }
        message.personID = person
    }

    private func update(_ db: Database, message: Message) throws {
        try db.execute("UPDATE messages SET person = ?, payload = ? WHERE id = ?",
                       [.text(message.personID.uuidString), try encoded(message), .text(message.id.uuidString)])
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Database.Value { .blob(try JSONEncoder().encode(value)) }

    private static func checkedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, name.utf8.count <= 1024,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw KeeperError.invalid }
        return name
    }

    private static func checkedNote(_ input: String) throws -> String {
        let note = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= 240, note.utf8.count <= 4096 else { throw KeeperError.invalid }
        return note
    }
}
