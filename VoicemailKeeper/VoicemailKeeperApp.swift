import StoreKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct VoicemailKeeperApp: App {
    var body: some Scene {
        WindowGroup { LibraryRoot().preferredColorScheme(.light) }
    }
}

private enum Route: Hashable { case person(UUID), backup, settings, card(Int?) }
private enum PickerIntent { case audio, newPerson, restore }

struct LibraryRoot: View {
    @StateObject private var model = KeeperModel()
    @StateObject private var playback = Playback()
    @State private var path = [Route]()
    @State private var guide = false
    @State private var showPicker = false
    @State private var intent = PickerIntent.audio
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        ZStack {
            if model.locked {
                KeeperPage {
                    PageTitle(title: L.t("lock.title"), subtitle: L.t("lock.subtitle"))
                    KeeperButton(title: L.t("lock.unlock"), symbol: "faceid", primary: true, id: "lock.unlock") {
                        Task { await model.unlock() }
                    }
                    .disabled(model.working)
                    if model.working { Busy() }
                    if let error = model.error { InlineError(error: error) }
                }
            } else if model.vault != nil {
                library
            } else {
                KeeperPage {
                    PageTitle(title: L.t("app.name"))
                    if let error = model.error {
                        InlineError(error: error)
                        KeeperButton(title: L.t("retry"), id: "start.retry") { Task { await model.refresh() } }
                    } else {
                        Busy()
                    }
                }
            }
            if phase != .active && model.privacyEnabled { Theme.paper.ignoresSafeArea().zIndex(1) }
        }
        .tint(Theme.accent)
        .accessibilityHidden(phase != .active && model.privacyEnabled)
        .task {
            await model.start()
            #if DEBUG
            if let family = Self.storeShotImportIsFamily {
                await model.simulateImport(family: family)
            }
            #endif
        }
        .task(id: reviewConditions) {
            guard reviewConditions else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard reviewConditions, await model.claimReview() else { return }
            guard !Task.isCancelled, reviewConditions else {
                await model.releaseReview()
                return
            }
            if Launch.testing { model.reviewRequested = true } else { requestReview() }
        }
        .onOpenURL { url in Task { await model.handleIncoming(url) } }
        .onChange(of: phase) { _, value in
            if value == .active {
                #if DEBUG
                if Self.storeShotImportIsFamily != nil { return }
                #endif
                Task { await model.refresh() }
            }
            if value != .active && model.privacyEnabled { playback.stop() }
            if value == .background {
                playback.stop()
                if model.privacyEnabled {
                    guide = false
                    path.removeAll()
                    showPicker = false
                }
                model.hideForBackground()
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: pickerTypes) { selection in
            let requested = intent
            switch selection {
            case .success(let url):
                Task {
                    if requested == .restore { await model.previewRestore(url) }
                    else {
                        await model.importFile(url, family: url.pathExtension.lowercased() == "vkeep",
                                               startWithNewPerson: requested == .newPerson)
                    }
                }
            case .failure(let error):
                let mapped = KeeperError.map(error, fallback: .unreadable)
                if mapped != .cancelled { model.error = mapped }
            }
        }
        .sheet(isPresented: $guide) {
            privacyProtected(GuideView(close: { guide = false }, importAudio: {
                guide = false
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    pick(.audio)
                }
            }))
        }
        .sheet(item: $model.importDraft) { draft in
            if let vault = model.vault {
                privacyProtected(ImportView(draft: draft, library: model.library, vault: vault,
                                            onCancel: model.cancelImport,
                                            onFinish: { Task { await model.finishImport() } },
                                            startWithNewPerson: model.importForNewPerson))
            }
        }
        .sheet(item: $model.restoreDraft) { draft in
            privacyProtected(RestorePreview(model: model, draft: draft))
        }
        .sheet(item: $model.share, onDismiss: model.finishActivity) { items in ActivitySheet(items: items) }
        .sheet(item: $model.backupExport, onDismiss: {
            if model.status == nil, !model.locked { model.status = L.t("backup.unconfirmed") }
        }) { file in
            BackupDestination(file: file) { success in Task { await model.completeBackup(file, destination: success) } }
                .interactiveDismissDisabled()
        }
    }

    private var library: some View {
        NavigationStack(path: $path) {
            HomeView(model: model, importAudio: { pick(.audio) }, importForNewPerson: { pick(.newPerson) },
                     restore: { pick(.restore) }, guide: { guide = true },
                     backup: { path.append(.backup) }, settings: { path.append(.settings) },
                     card: { path.append(.card($0)) }, open: { path.append(.person($0)) })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .person(let id):
                        PersonView(model: model, playback: playback, id: id)
                    case .backup:
                        BackupView(model: model, restore: { pick(.restore) })
                    case .settings:
                        SettingsView(model: model, guide: { guide = true }, backup: { path.append(.backup) })
                    case .card(let milestone):
                        CardView(model: model, milestone: milestone)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var pickerTypes: [UTType] {
        if intent == .restore { return [.zip] }
        let audioTypes = [UTType.audio, .mpeg4Movie] +
            AudioFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue) }
        return intent == .newPerson ? audioTypes : audioTypes + [VaultFiles.familyType]
    }

    #if DEBUG
    private static let storeShotImportIsFamily: Bool? = {
        guard Launch.storeShots else { return nil }
        if Launch.arguments.contains("-store-import") { return false }
        if Launch.arguments.contains("-store-family") { return true }
        return nil
    }()
    #endif

    private var reviewConditions: Bool {
        phase == .active && path.isEmpty && !guide && !showPicker && !model.locked && !model.working &&
        model.library.reviewDay == ImportProgress.dayKey(.now) && model.error == nil &&
        model.importDraft == nil && model.restoreDraft == nil && model.share == nil && model.backupExport == nil &&
        !playback.playing
    }

    private func pick(_ requested: PickerIntent) {
        model.status = nil
        model.error = nil
        #if DEBUG
        if Launch.testing, Launch.arguments.contains("-fixture-picker") {
            Task { await model.simulateImport(restored: requested == .restore, startWithNewPerson: requested == .newPerson) }
            return
        }
        #endif
        intent = requested
        showPicker = true
    }

    private func privacyProtected<V: View>(_ view: V) -> some View {
        let covered = model.privacyEnabled && (phase != .active || model.locked)
        return view.accessibilityHidden(covered).overlay {
            if covered { Theme.paper.ignoresSafeArea() }
        }
    }
}
