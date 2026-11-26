#if DEBUG
import Foundation

enum DemoLibrary {
    static func sample() throws -> URL {
        guard Launch.testing, let url = Bundle.main.url(forResource: "Sample", withExtension: "m4a") else {
            throw KeeperError.storage
        }
        return url
    }

    static func populate(_ vault: Vault) async throws {
        guard try vault.state().messages.isEmpty else { return }
        let rows = [("mom", "birthday", 23), ("dad", "hello", 11), ("aunt", "sunday", 4)]
        var number = 0
        for (person, note, count) in rows.reversed() {
            let name = L.t("demo." + person)
            var id: UUID?
            for index in 0..<count {
                number += 1
                let draft = try await AudioImport.prepare(try sample(), testTag: number)
                let date = Date(timeIntervalSince1970: 1_794_000_000 - Double(index * 9_700_000))
                let text = index == 0 ? L.t("demo." + note) : L.t("demo.hello")
                _ = try vault.save(draft, choice: id.map(PersonChoice.existing) ?? .new(name), note: text,
                                   date: date, zone: "GMT", now: date, trackProgress: false)
                id = try vault.state().lastPerson
            }
        }
        let library = try vault.state()
        if let id = library.lastPerson, let first = library.messages(for: id).first { try vault.setStar(first.id) }
        try vault.recordBackup(.init(date: Date().addingTimeInterval(-12 * 86_400), people: 3, messages: 38))
    }

    static func familyExample() async throws -> ExportFile {
        let root = try VaultFiles.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(root: root)
        let draft = try await AudioImport.prepare(try sample(), testTag: 991)
        _ = try vault.save(draft, choice: .new(L.t("demo.mom")), note: L.t("demo.sunday"),
                           date: Date(timeIntervalSince1970: 1_794_700_000), zone: "GMT", trackProgress: false)
        guard let message = try vault.state().messages.first else { throw KeeperError.storage }
        return try vault.exportMessage(message.id, family: true)
    }

    static func restoreExample() async throws -> ExportFile {
        let root = try VaultFiles.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(root: root)
        let draft = try await AudioImport.prepare(try sample(), testTag: 998)
        _ = try vault.save(draft, choice: .new(L.t("demo.aunt")), note: L.t("demo.hello"), date: nil, zone: nil)
        return try vault.exportFull()
    }
}
#endif
