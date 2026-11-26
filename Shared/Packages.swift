import Foundation

enum PackageKind: String, Codable, Sendable { case backup, family }

struct PackageIndex: Codable, Sendable {
    static let latest = 1
    static let maxMessages = 10_000
    var version = latest
    var kind: PackageKind
    var people: [Person]
    var messages: [Message]
    var aliases: [PersonAlias]

    func validate() throws {
        guard version == Self.latest else { throw KeeperError.version }
        guard people.count <= Self.maxMessages, messages.count <= Self.maxMessages, aliases.count <= Self.maxMessages,
              kind != .family || (people.count == 1 && messages.count == 1 && aliases.isEmpty) else {
            throw KeeperError.badPackage
        }
        let personIDs = Set(people.map(\.id))
        guard personIDs.count == people.count, Set(messages.map(\.id)).count == messages.count,
              Set(aliases.map(\.sourceID)).count == aliases.count,
              aliases.allSatisfy({ personIDs.contains($0.personID) }),
              people.allSatisfy({ !Person.normalized($0.name).isEmpty && $0.name.count <= 80 && $0.name.utf8.count <= 1024 }) else {
            throw KeeperError.badPackage
        }
        var fingerprints: Set<String> = []
        for message in messages {
            let key = message.personID.uuidString + ":" + message.hash
            guard personIDs.contains(message.personID), VaultFiles.isHash(message.hash), fingerprints.insert(key).inserted,
                  message.duration.isFinite, message.duration > 0, message.duration <= 86_401,
                  message.note.count <= 240, message.note.utf8.count <= 4096,
                  message.filename.utf8.count <= 1024, ZipArchive.safePath(message.filename), !message.filename.contains("/"),
                  (message.filename as NSString).pathExtension == message.format.rawValue,
                  TimeZone(identifier: message.savedZone) != nil,
                  message.sourceZone.map({ TimeZone(identifier: $0) != nil }) ?? true,
                  abs(message.savedAt.timeIntervalSince1970) < 253_402_300_799,
                  message.sourceDate.map({ abs($0.timeIntervalSince1970) < 253_402_300_799 }) ?? true else {
                throw KeeperError.badPackage
            }
        }
    }
}

struct RestorePlan: Equatable, Sendable {
    var added = 0
    var duplicates = 0
    var conflicts = 0
}

final class RestoreDraft: @unchecked Sendable, Identifiable {
    let id = UUID()
    let directory: URL
    let index: PackageIndex
    let plan: RestorePlan
    private let archive: ZipArchive.Reader

    init(directory: URL, index: PackageIndex, plan: RestorePlan, archive: ZipArchive.Reader) {
        self.directory = directory
        self.index = index
        self.plan = plan
        self.archive = archive
    }

    func bytes(for message: Message) throws -> Data { try archive.bytes(Packages.path(message)) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class ExportFile: @unchecked Sendable, Identifiable {
    let id = UUID()
    let directory: URL
    let url: URL
    let stamp: BackupStamp?

    init(directory: URL, url: URL, stamp: BackupStamp? = nil) {
        self.directory = directory
        self.url = url
        self.stamp = stamp
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum Packages {
    private static let indexName = "index.json"
    private static let listName = "清单.txt"
    private static let indexLimit = 32 * 1024 * 1024

    static func path(_ message: Message) -> String { "audio/" + message.blob }

    static func make(_ index: PackageIndex, in directory: URL, blobs: URL) throws -> ExportFile {
        try index.validate()
        let kind = index.kind
        let output = directory.appendingPathComponent(kind == .backup ? "Voicemail-Keeper-Backup.zip" : "Voice-Message.vkeep")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(index)
        guard manifest.count <= indexLimit else { throw KeeperError.tooLarge }
        var entries: [ZipArchive.Entry] = [
            .init(name: indexName, payload: .bytes(manifest)),
            .init(name: listName, payload: .bytes(readable(index.people, index.messages, path: path)))
        ]
        var checked = Set<String>()
        for message in index.messages where checked.insert(message.blob).inserted {
            let url = blobs.appendingPathComponent(message.blob)
            guard try VaultFiles.hash(url) == message.hash else { throw KeeperError.corrupt }
            entries.append(.init(name: path(message), payload: .file(url)))
        }
        try ZipArchive.write(entries, to: output)
        let stamp = kind == .backup ? BackupStamp(date: .now, people: index.people.count, messages: index.messages.count) : nil
        return ExportFile(directory: directory, url: output, stamp: stamp)
    }

    static func person(_ person: Person, messages: [Message], in directory: URL, blobs: URL) throws -> ExportFile {
        let output = directory.appendingPathComponent(VaultFiles.safeName(person.name) + ".zip")
        var names: [UUID: String] = [:]
        var entries = [ZipArchive.Entry]()
        for (index, message) in messages.enumerated() {
            let name = "audio/\(index + 1)-\(message.filename)"
            names[message.id] = name
            let url = blobs.appendingPathComponent(message.blob)
            guard try VaultFiles.hash(url) == message.hash else { throw KeeperError.corrupt }
            entries.append(.init(name: name, payload: .file(url)))
        }
        let list = readable([person], messages) { names[$0.id] ?? $0.filename }
        entries.insert(.init(name: listName, payload: .bytes(list)), at: 0)
        try ZipArchive.write(entries, to: output)
        return ExportFile(directory: directory, url: output)
    }

    static func read(_ source: URL, in directory: URL, kind: PackageKind) throws -> (PackageIndex, ZipArchive.Reader) {
        let copy = directory.appendingPathComponent("package.zip")
        try VaultFiles.copy(source, to: copy, limit: kind == .family ? VaultFiles.familyLimit : VaultFiles.packageLimit)
        let archive = try ZipArchive.Reader(copy)
        let manifest = try archive.bytes(indexName)
        guard manifest.count <= indexLimit else { throw KeeperError.badPackage }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: manifest)
        guard header.version == PackageIndex.latest else { throw KeeperError.version }
        let index = try decoder.decode(PackageIndex.self, from: manifest)
        try index.validate()
        guard index.kind == kind else { throw KeeperError.badPackage }
        let expected = Set(index.messages.map(path) + [indexName, listName])
        guard expected == Set(archive.entries.keys) else { throw KeeperError.badPackage }

        let verification = directory.appendingPathComponent("verify", isDirectory: true)
        try VaultFiles.directory(verification)
        defer { try? FileManager.default.removeItem(at: verification) }
        var verified: [String: Double] = [:]
        for message in index.messages {
            try Task.checkCancellation()
            let duration: Double
            if let previous = verified[message.blob] {
                duration = previous
            } else {
                let temp = verification.appendingPathComponent(message.blob)
                let bytes = try archive.bytes(path(message))
                try VaultFiles.requireSpace(at: verification, bytes: bytes.count)
                try bytes.write(to: temp, options: [.atomic, .completeFileProtection])
                guard try VaultFiles.hash(temp) == message.hash,
                      try AudioImport.detect(temp) == message.format else { throw KeeperError.badPackage }
                duration = try AudioImport.verify(temp, format: message.format)
                verified[message.blob] = duration
                try FileManager.default.removeItem(at: temp)
            }
            guard abs(duration - message.duration) < 0.1 else { throw KeeperError.badPackage }
        }
        return (index, archive)
    }

    static func openFamily(_ source: URL) async throws -> AudioDraft {
        let directory = try VaultFiles.temporary()
        do {
            let (index, archive) = try read(source, in: directory, kind: .family)
            guard let message = index.messages.first, let person = index.people.first else { throw KeeperError.badPackage }
            let original = directory.appendingPathComponent(message.filename)
            let bytes = try archive.bytes(path(message))
            try VaultFiles.requireSpace(at: directory, bytes: bytes.count)
            try bytes.write(to: original, options: [.atomic, .completeFileProtection])
            try FileManager.default.removeItem(at: directory.appendingPathComponent("package.zip"))
            return try await AudioImport.validate(original, family: person, message: message)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw KeeperError.map(error, fallback: .badPackage)
        }
    }

    private struct Header: Decodable { let version: Int }

    private static func readable(_ people: [Person], _ messages: [Message], path: (Message) -> String) -> Data {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let lines = messages.map { message in
            L.f("manifest.row", names[message.personID] ?? "", message.shownDate, L.duration(message.duration),
                message.note, message.filename, path(message))
        }
        return Data(([L.t("manifest.title")] + lines).joined(separator: "\n").appending("\n").utf8)
    }
}
