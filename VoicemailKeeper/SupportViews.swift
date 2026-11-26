import SwiftUI

struct GuideView: View {
    let close: () -> Void
    let importAudio: () -> Void

    var body: some View {
        KeeperPage {
            HStack {
                Text(L.t("app.name")).font(.subheadline.weight(.semibold))
                Spacer()
                Button(L.t("guide.skip"), action: close).frame(minHeight: 44).accessibilityIdentifier("guide.skip")
            }
            .foregroundStyle(Theme.accent)
            PageTitle(title: L.t("guide.title"))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(1...3, id: \.self) { number in
                    Label(L.t("guide.step" + String(number)), systemImage: "\(number).circle")
                        .font(.body.weight(.medium)).frame(minHeight: 44, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).modifier(Theme.panel())
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L.t("guide.carrier"))
                Text(L.t("guide.carrierHelp")).foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).modifier(Theme.panel())
            KeeperButton(title: L.t("guide.library"), primary: true, id: "guide.library", action: close)
            KeeperButton(title: L.t("guide.files"), id: "guide.import", action: importAudio)
        }
    }
}

struct BackupView: View {
    @ObservedObject var model: KeeperModel
    let restore: () -> Void

    var body: some View {
        KeeperPage {
            LibraryBack()
            PageTitle(title: L.t("backup.title"), subtitle: L.t("backup.subtitle"))
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(L.t("backup.last"))
                if let stamp = model.stamp {
                    Text(L.date(stamp.date)).font(.system(.title2, design: .serif))
                    Text(L.f("backup.days", stamp.days()) + " · " + L.f("backup.people", stamp.people) + " · " + L.count(stamp.messages))
                        .font(.subheadline).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("backup.stamp")
                } else {
                    Text(L.t("backup.never")).font(.subheadline)
                }
                if model.denied { Text(L.t("reminder.denied")).font(.caption).foregroundStyle(Theme.accent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(13).modifier(Theme.panel())
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L.t("backup.take"))
                Text(L.t("backup.takeHelp")).font(.subheadline).foregroundStyle(Theme.accent)
                KeeperButton(title: L.t("backup.export"), symbol: "arrow.down.document", primary: true, id: "backup.export") {
                    Task { await model.export({ try $0.exportFull() }, isBackup: true) }
                }
                .disabled(model.working)
                Button {
                    Task { await model.export { try $0.exportFull() } }
                } label: {
                    Label(L.t("backup.share"), systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
                .disabled(model.working)
                .accessibilityIdentifier("backup.share")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L.t("backup.bring"))
                Text(L.t("backup.bringHelp")).font(.subheadline).foregroundStyle(Theme.accent)
                KeeperButton(title: L.t("backup.restore"), symbol: "folder", id: "backup.restore", action: restore)
                    .disabled(model.working)
            }
            if model.working { Busy() }
            if let error = model.error { InlineError(error: error) }
            if let status = model.status {
                Text(status).font(.subheadline)
                    .accessibilityIdentifier(status == L.t("share.ready") ? "share.requested" : "backup.status")
            }
            Text(L.t("backup.originals"))
                .font(.subheadline).foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading).padding(13).modifier(Theme.panel())
            #if DEBUG
            if Launch.testing && !Launch.storeShots {
                KeeperButton(title: L.t("test.backupCancel"), id: "test.backupCancel") { Task { await model.simulateBackupReceipt(confirmed: false) } }
                KeeperButton(title: L.t("test.backupConfirm"), id: "test.backupConfirm") { Task { await model.simulateBackupReceipt(confirmed: true) } }
            }
            #endif
        }
        .onAppear { model.status = nil; model.error = nil }
    }
}

struct RestorePreview: View {
    @ObservedObject var model: KeeperModel
    let draft: RestoreDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        KeeperPage {
            PageTitle(title: L.t("restore.title"), subtitle: L.t("restore.subtitle"))
            VStack(alignment: .leading, spacing: 14) {
                Text(L.f("restore.added", draft.plan.added))
                Text(L.f("restore.duplicates", draft.plan.duplicates))
                Text(L.f("restore.conflicts", draft.plan.conflicts))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(15).modifier(Theme.panel())
            if let error = model.error { InlineError(error: error) }
            KeeperButton(title: L.t("restore.confirm"), primary: true, id: "restore.confirm") {
                Task { await model.restore(draft) }
            }
            .disabled(model.working)
            KeeperButton(title: L.t("cancel"), id: "restore.cancel") { dismiss() }.disabled(model.working)
            if model.working { Busy() }
        }
        .interactiveDismissDisabled(model.working)
    }
}

struct SettingsView: View {
    @ObservedObject var model: KeeperModel
    let guide: () -> Void
    let backup: () -> Void
    @State private var askingForNotification = false

    var body: some View {
        KeeperPage {
            LibraryBack()
            PageTitle(title: L.t("home.settings"))
            SectionLabel(L.t("settings.privacy"))
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L.t("settings.lock"), isOn: Binding(get: { model.privacyEnabled }, set: { enabled in
                    Task { await model.changeLock(enabled) }
                }))
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.lock")
                .disabled(model.working)
                Text(L.t("settings.lockHelp")).font(.subheadline).foregroundStyle(Theme.accent)
            }
            .padding(13).modifier(Theme.panel())
            SectionLabel(L.t("home.backup"))
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L.t("settings.reminder"), isOn: Binding(get: { model.reminder }, set: { enabled in
                    askingForNotification = true
                    Task {
                        await model.changeReminders(enabled)
                        askingForNotification = false
                    }
                }))
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.reminder")
                .disabled(askingForNotification)
                Text(L.t(model.denied ? "reminder.denied" : "settings.reminderHelp")).font(.subheadline).foregroundStyle(Theme.accent)
                Divider()
                Button(action: backup) {
                    Label(model.stamp.map { L.f("backup.days", $0.days()) } ?? L.t("backup.never"), systemImage: "archivebox")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("settings.backup")
            }
            .padding(13).modifier(Theme.panel())
            if let error = model.error { InlineError(error: error) }
            KeeperButton(title: L.t("guide.open"), symbol: "questionmark.circle", id: "settings.guide", action: guide)
        }
        .onAppear { model.error = nil }
    }
}
