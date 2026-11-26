import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class KeeperModel: ObservableObject {
    @Published private(set) var vault: Vault?
    @Published private(set) var library = Library()
    @Published private(set) var stamp: BackupStamp?
    @Published private(set) var locked = false
    @Published private(set) var privacyEnabled = false
    @Published private(set) var working = false
    @Published private(set) var reminder = false
    @Published private(set) var denied = false
    @Published var error: KeeperError?
    @Published var status: String?
    @Published var importDraft: AudioDraft?
    private(set) var importForNewPerson = false
    @Published var restoreDraft: RestoreDraft?
    @Published var share: ShareItems?
    @Published var backupExport: ExportFile?
    @Published var reviewRequested = false
    #if DEBUG
    private(set) var shareReceiptExtension = ""
    #endif
    private var didStart = false
    private var needsRefresh = false
    private var generation = UUID()
    private var pendingSource: URL?
    private var sharingBackup = false

    private var familyURL: URL?

    func start() async {
        guard !didStart else { return }
        didStart = true
        await refresh()
    }

    func refresh() async {
        if working { needsRefresh = true; return }
        if vault == nil {
            await work {
                let vault = try await offMain {
                    let container = try Launch.container()
                    #if DEBUG
                    if Launch.reset {
                        if FileManager.default.fileExists(atPath: container.path) {
                            try FileManager.default.removeItem(at: container)
                        }
                        Launch.defaults.removePersistentDomain(forName: Launch.group + ".uitest")
                    }
                    #endif
                    VaultFiles.cleanTemporary()
                    let vault = try Vault(root: container)
                    try vault.collectOrphans()
                    #if DEBUG
                    if Launch.seed { try await DemoLibrary.populate(vault) }
                    if Launch.testing, let days = ProcessInfo.processInfo.environment["VK_UI_REVIEW_DAYS"] {
                        try vault.seedReviewDays(Set(days.split(whereSeparator: \.isNewline).map(String.init)))
                    }
                    #endif
                    return vault
                }
                let enabled = try await offMain { try vault.faceLocked() }
                privacyEnabled = enabled
                locked = enabled
                self.vault = vault
                if !enabled { try await snapshot(vault) }
            }
        } else if let vault, !locked {
            await work { try await snapshot(vault) }
        }
        if !locked { await openNextIfNeeded() }
    }

    func unlock() async {
        guard locked, let vault else { return }
        let epoch = generation
        await work {
            guard await Authentication.verify(), generation == epoch else { throw KeeperError.authentication }
            locked = false
            try await snapshot(vault)
        }
        if !locked { await openNextIfNeeded() }
    }

    func hideForBackground() {
        generation = UUID()
        guard privacyEnabled else { return }
        locked = true
        library = Library()
        importDraft = nil
        restoreDraft = nil
        share = nil
        backupExport = nil
        pendingSource = nil
        error = nil
        status = nil
    }

    func handleIncoming(_ url: URL) async {
        guard url.pathExtension.lowercased() == "vkeep" else { error = .badPackage; return }
        do {
            let queued = try await offMain {
                let directory = try VaultFiles.temporary()
                let path = directory.appendingPathComponent("Incoming.vkeep")
                do { try VaultFiles.copy(url, to: path, limit: VaultFiles.familyLimit); return path }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
            }
            if let familyURL { await removeIncoming(familyURL) }
            familyURL = queued
            await openNextIfNeeded()
        } catch {
            self.error = KeeperError.map(error, fallback: .unreadable)
        }
    }

    func importFile(_ url: URL, family: Bool, startWithNewPerson: Bool = false) async {
        guard !locked, let vault else { return }
        let epoch = generation
        await work {
            let draft = try await offMain {
                if family { return try await Packages.openFamily(url) }
                return try await AudioImport.prepare(url)
            }
            guard generation == epoch || !privacyEnabled, !locked else { return }
            try await snapshot(vault)
            guard !locked else { return }
            importForNewPerson = startWithNewPerson && !family
            importDraft = draft
        }
    }

    func cancelImport() {
        importDraft = nil
        pendingSource = nil
    }

    func finishImport() async {
        let pending = pendingSource
        importDraft = nil
        pendingSource = nil
        guard let vault else { return }
        if let pending { _ = try? await offMain { try vault.removePending(pending) } }
        await work {
            try await snapshot(vault)
            if !locked { status = L.t("import.saved") }
        }
        await openNextIfNeeded()
    }

    func update(_ change: @escaping @Sendable (Vault) throws -> Void) async {
        guard let vault, !locked else { return }
        await work {
            try await offMain { try change(vault) }
            try await snapshot(vault)
        }
    }

    func export(_ operation: @escaping @Sendable (Vault) throws -> ExportFile, isBackup: Bool = false, caption: String? = nil) async {
        guard let vault, !locked else { return }
        let epoch = generation
        status = nil
        await work {
            let file = try await offMain { try operation(vault) }
            guard !locked, generation == epoch || !privacyEnabled else { return }
            if Launch.testing {
                #if DEBUG
                shareReceiptExtension = file.url.pathExtension.lowercased()
                #endif
                status = L.t("share.ready")
            } else if isBackup {
                backupExport = file
            } else {
                sharingBackup = file.stamp != nil
                share = ShareItems(file: file, caption: caption)
            }
        }
    }

    func finishActivity() {
        if sharingBackup, !locked { status = L.t("backup.unconfirmed") }
        sharingBackup = false
    }

    func completeBackup(_ file: ExportFile, destination: Bool) async {
        backupExport = nil
        guard let vault, !locked else { return }
        guard destination, let stamp = file.stamp else {
            status = L.t("backup.unconfirmed")
            return
        }
        await work {
            let completion = BackupStamp(date: .now, people: stamp.people, messages: stamp.messages)
            try await offMain { try vault.recordBackup(completion) }
            self.stamp = completion
            status = L.t("backup.confirmed")
            if reminder { await Reminders.schedule(after: completion.date, confirmed: true) }
        }
    }

    func previewRestore(_ url: URL) async {
        guard let vault, !locked else { return }
        let epoch = generation
        await work {
            let value = try await offMain { try vault.previewRestore(url) }
            if !locked, generation == epoch || !privacyEnabled { restoreDraft = value }
        }
    }

    func restore(_ draft: RestoreDraft) async {
        guard let vault, !locked else { return }
        await work {
            let result = try await offMain { try vault.restore(draft) }
            restoreDraft = nil
            try await snapshot(vault)
            if !locked { status = L.f("backup.restored", result.added, result.duplicates) }
        }
    }

    func changeLock(_ enabled: Bool) async {
        guard let vault, !locked else { return }
        let epoch = generation
        await work {
            guard await Authentication.verify(), generation == epoch, !locked else { throw KeeperError.authentication }
            try await offMain { try vault.setFaceLock(enabled) }
            privacyEnabled = enabled
            if generation != epoch && enabled { hideForBackground(); return }
            try await snapshot(vault)
        }
    }

    func changeReminders(_ enabled: Bool) async {
        if enabled {
            do {
                let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                denied = !ok
                reminder = ok
                if ok {
                    let now = Date()
                    Launch.defaults.set(now, forKey: "reminderSince")
                    await Reminders.schedule(after: stamp?.date ?? now, confirmed: stamp != nil)
                }
            } catch {
                denied = true
                reminder = false
            }
        } else {
            reminder = false
            denied = false
            Reminders.clear()
        }
        Launch.defaults.set(reminder, forKey: "reminder")
        Launch.defaults.set(denied, forKey: "reminderDenied")
    }

    func claimReview() async -> Bool {
        guard let vault, !locked, !working else { return false }
        do {
            return try await offMain { try vault.claimReview(version: Launch.runningVersion) }
        } catch {
            return false
        }
    }

    func releaseReview() async {
        guard let vault else { return }
        await Task.detached { try? vault.releaseReview(version: Launch.runningVersion) }.value
    }

    #if DEBUG
    func simulateImport(family: Bool = false, restored: Bool = false, startWithNewPerson: Bool = false) async {
        guard Launch.testing, vault != nil, !locked else { return }
        if restored {
            do {
                let snapshot = try await offMain { try await DemoLibrary.restoreExample() }
                await previewRestore(snapshot.url)
                withExtendedLifetime(snapshot) {}
            } catch {
                self.error = KeeperError.map(error)
            }
            return
        }
        let tag = Int.random(in: 10_000...(Int.max - 100))
        await work {
            let draft = try await offMain {
                if family {
                    let package = try await DemoLibrary.familyExample()
                    return try await Packages.openFamily(package.url)
                }
                return try await AudioImport.prepare(try DemoLibrary.sample(), testTag: 100 + tag)
            }
            importForNewPerson = startWithNewPerson && !family
            importDraft = draft
        }
    }

    func simulateBackupReceipt(confirmed: Bool) async {
        guard Launch.testing, let vault else { return }
        let result = try? await offMain { try vault.exportFull() }
        if let result { await completeBackup(result, destination: confirmed) }
    }
    #endif

    private func snapshot(_ vault: Vault) async throws {
        let epoch = generation
        let data = try await offMain { (try vault.state(), try vault.stamp()) }
        guard !locked, generation == epoch || !privacyEnabled else { return }
        library = data.0
        privacyEnabled = library.faceLock
        stamp = data.1
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let current = Launch.defaults.bool(forKey: "reminder")
        let deniedBySystem = settings.authorizationStatus == .denied
        reminder = current && !deniedBySystem
        denied = (current || Launch.defaults.bool(forKey: "reminderDenied")) && deniedBySystem
        if current && deniedBySystem { Reminders.clear() }
        else if reminder {
            let number = await UNUserNotificationCenter.current().pendingNotificationRequests()
                .filter { $0.identifier.hasPrefix(Reminders.prefix) }.count
            if number < 3 {
                let reference = stamp?.date ?? (Launch.defaults.object(forKey: "reminderSince") as? Date) ?? .now
                await Reminders.schedule(after: reference, confirmed: stamp != nil)
            }
        }
    }

    private func work(_ operation: () async throws -> Void) async {
        guard !working else { return }
        error = nil
        working = true
        do { try await operation() }
        catch { self.error = KeeperError.map(error) }
        working = false
        if needsRefresh {
            needsRefresh = false
            Task { await refresh() }
        }
    }

    private func openNextIfNeeded() async {
        guard let vault, !locked, importDraft == nil, restoreDraft == nil, !working else { return }
        if let url = familyURL {
            familyURL = nil
            await importFile(url, family: true)
            await removeIncoming(url)
            return
        }
        if let files = try? await offMain({ try vault.pending() }),
           let first = files.first, !working, !locked, importDraft == nil {
            pendingSource = first
            await importFile(first, family: false)
        }
    }

    private func removeIncoming(_ url: URL) async {
        _ = try? await offMain { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let file: ExportFile
    let caption: String?
}

enum Reminders {
    static let prefix = "backup-reminder-"
    static let seconds = TimeInterval(30 * 86_400)

    static func clear() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: (1...12).map { prefix + String($0) }
        )
    }

    static func schedule(after reference: Date, confirmed: Bool) async {
        let center = UNUserNotificationCenter.current()
        clear()
        let elapsed = max(0, Date().timeIntervalSince(reference))
        let first = Int(elapsed / seconds) + 1
        for offset in 0..<12 {
            let interval = max(seconds * Double(first + offset) - elapsed, 1)
            let content = UNMutableNotificationContent()
            content.title = L.t("notify.title")
            let days = (first + offset) * 30
            content.body = confirmed ? L.f("notify.last", days) : L.t("notify.body")
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: prefix + String(offset + 1), content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
