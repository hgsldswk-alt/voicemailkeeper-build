import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var host: UIHostingController<ShareRoot>?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let context = extensionContext else { return }
        let host = UIHostingController(rootView: ShareRoot(model: ShareModel(context: context)))
        self.host = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.overrideUserInterfaceStyle = .light
        host.didMove(toParent: self)
    }
}

@MainActor
private final class ShareModel: ObservableObject {
    @Published var locked = true
    @Published var working = true
    @Published var concealed = false
    @Published var error: KeeperError?
    @Published var queued = false
    @Published var draft: AudioDraft?
    @Published var library = Library()
    private(set) var vault: Vault?
    private var epoch = UUID()
    private var needsAuth = false
    private let context: NSExtensionContext

    init(context: NSExtensionContext) { self.context = context }

    func start() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let vault = try await offMain {
                VaultFiles.cleanTemporary()
                return try Vault(root: Launch.container())
            }
            self.vault = vault
            needsAuth = try await offMain { try vault.faceLocked() }
            locked = needsAuth
            if !needsAuth { try await load(vault) }
        } catch {
            self.error = KeeperError.map(error)
        }
    }

    func unlock() async {
        guard let vault, !working else { return }
        working = true
        error = nil
        let generation = epoch
        defer { working = false }
        guard await Authentication.verify(), generation == epoch else {
            error = .authentication
            return
        }
        locked = false
        do { try await load(vault) }
        catch { self.error = KeeperError.map(error, fallback: .unreadable) }
    }

    func queue() async {
        guard let vault, !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let staged = try await stageSource()
            let value = try await offMain { try await AudioImport.validate(staged) }
            try await offMain { try vault.queuePending(value.url) }
            queued = true
        } catch {
            self.error = KeeperError.map(error, fallback: .unreadable)
        }
    }

    func backgrounded() {
        epoch = UUID()
        concealed = true
        if needsAuth {
            locked = true
            draft = nil
            library = Library()
            error = nil
        }
    }

    func finish() { context.completeRequest(returningItems: nil) }
    func cancel() {
        context.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func load(_ vault: Vault) async throws {
        let generation = epoch
        let staged = try await stageSource()
        let result = try await offMain {
            let draft = try await AudioImport.validate(staged)
            return (draft, try vault.state())
        }
        guard generation == epoch, !locked else { return }
        draft = result.0
        library = result.1
    }

    private func stageSource() async throws -> URL {
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        guard let provider = items.lazy.compactMap({ $0.attachments?.first }).first else { throw KeeperError.unreadable }
        return try await SharedProvider.stage(provider)
    }
}

private struct ShareRoot: View {
    @ObservedObject var model: ShareModel
    private let willResign = Notification.Name("NSExtensionHostWillResignActiveNotification")
    private let foreground = Notification.Name("NSExtensionHostDidBecomeActiveNotification")
    private let backgroundName = Notification.Name("NSExtensionHostDidEnterBackgroundNotification")

    var body: some View {
        ZStack {
            if let draft = model.draft, let vault = model.vault, !model.locked {
                ImportView(draft: draft, library: model.library, vault: vault, onCancel: model.cancel, onFinish: model.finish)
            } else {
                KeeperPage {
                    PageTitle(title: L.t("import.title"))
                    if model.working { Busy() }
                    if let error = model.error { InlineError(error: error) }
                    if model.queued {
                        Text(L.t("extension.queued"))
                        KeeperButton(title: L.t("done"), primary: true, id: "extension.done", action: model.finish)
                    } else if !model.working {
                        if model.locked && model.vault != nil {
                            Text(L.t("extension.locked"))
                            KeeperButton(title: L.t("lock.unlock"), symbol: "faceid", primary: true, id: "extension.unlock") {
                                Task { await model.unlock() }
                            }
                            KeeperButton(title: L.t("extension.queue"), id: "extension.queue") { Task { await model.queue() } }
                        } else if model.error != nil {
                            KeeperButton(title: L.t("retry"), id: "extension.retry") { Task { await model.start() } }
                        }
                        KeeperButton(title: L.t("cancel"), id: "extension.cancel", action: model.cancel)
                    }
                }
            }
            if model.concealed { Theme.paper.ignoresSafeArea().zIndex(1) }
        }
        .tint(Theme.accent)
        .accessibilityHidden(model.concealed)
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: willResign)) { _ in model.concealed = true }
        .onReceive(NotificationCenter.default.publisher(for: foreground)) { _ in model.concealed = false }
        .onReceive(NotificationCenter.default.publisher(for: backgroundName)) { _ in model.backgrounded() }
    }
}

private enum SharedProvider {
    static func stage(_ provider: NSItemProvider) async throws -> URL {
        let known = Set(["public.data", "public.item", "public.mpeg-4", "com.apple.coreaudio-format",
                         "org.3gpp.adaptive-multi-rate-audio"])
        let available = provider.registeredTypeIdentifiers
        let audio = available.filter { UTType($0)?.conforms(to: .audio) == true }
        let fallback = available.filter { known.contains($0) && !audio.contains($0) }
        var lastError: KeeperError = .unreadable
        for identifier in audio + fallback {
            do {
                return try await representation(provider, identifier: identifier)
            } catch {
                lastError = KeeperError.map(error, fallback: .unreadable)
                if lastError == .cancelled || lastError == .disk || lastError == .tooLarge { throw lastError }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await fileURL(provider)
        }
        throw lastError
    }

    private static func representation(_ provider: NSItemProvider, identifier: String) async throws -> URL {
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                guard let url else { continuation.resume(throwing: error ?? KeeperError.unreadable); return }
                continuation.resume(with: Result {
                    let filename = name.map {
                        ($0 as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? $0 + "." + url.pathExtension : $0
                    }
                    return try AudioImport.stage(url, filename: filename, coordinate: false)
                })
            }
        }
    }

    private static func fileURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else { continuation.resume(throwing: error ?? KeeperError.unreadable); return }
                continuation.resume(with: Result { try AudioImport.stage(url) })
            }
        }
    }
}
