import SwiftUI

struct HomeView: View {
    @ObservedObject var model: KeeperModel
    let importAudio: () -> Void
    let importForNewPerson: () -> Void
    let restore: () -> Void
    let guide: () -> Void
    let backup: () -> Void
    let settings: () -> Void
    let card: (Int?) -> Void
    let open: (UUID) -> Void

    var body: some View {
        KeeperPage {
            Label(L.t("app.name"), systemImage: "waveform")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            PageTitle(title: L.t("home.title"), subtitle: L.t("home.subtitle"))
            if model.library.messages.isEmpty && model.library.people.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(L.t("home.empty"))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(L.t("home.people"))
                    VStack(spacing: 0) {
                        ForEach(model.library.people) { person in
                            let messages = model.library.messages(for: person.id)
                            if person.id != model.library.people.first?.id { Divider().overlay(Theme.line) }
                            Button { open(person.id) } label: {
                                HStack(spacing: 11) {
                                    Avatar(name: person.name)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(person.name).font(.headline).foregroundStyle(Theme.ink)
                                        Text(messages.first.map { L.count(messages.count) + " · " + $0.shownDate } ?? L.count(0))
                                            .font(.subheadline).foregroundStyle(Theme.accent)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                                        .accessibilityHidden(true)
                                }
                                .frame(minHeight: 60).padding(.horizontal, 12).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home.person." + person.id.uuidString)
                        }
                    }
                    .modifier(Theme.panel())
                }
            }
            if let milestone = model.library.milestone {
                HStack {
                    Button { card(milestone) } label: {
                        Label(L.f("milestone.title", milestone), systemImage: "photo")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("home.milestone")
                    IconControl(symbol: "xmark", label: L.t("milestone.dismiss"), id: "home.dismissMilestone") {
                        Task { await model.update { try $0.dismissMilestone() } }
                    }
                }
                .padding(.leading, 12).modifier(Theme.panel())
            }
            if model.working { Busy() }
            if let error = model.error { InlineError(error: error) }
            if let status = model.status { Text(status).font(.subheadline).accessibilityIdentifier("home.status") }
            VStack(alignment: .leading, spacing: 9) {
                KeeperButton(title: L.t("home.import"), symbol: "plus", primary: true, id: "home.import", action: importAudio)
                    .disabled(model.working)
                KeeperButton(title: L.t("backup.restore"), symbol: "folder", id: "home.restore", action: restore)
                    .disabled(model.working)
                if model.library.people.isEmpty {
                    Button(action: guide) {
                        Label(L.t("guide.open"), systemImage: "questionmark.circle").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("home.guide")
                } else {
                    Button(action: importForNewPerson) {
                        Label(L.t("home.importNew"), systemImage: "person.crop.circle.badge.plus").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("home.importNew")
                    .disabled(model.working)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { tools }
                    VStack(spacing: 8) { tools }
                }
            }
            #if DEBUG
            if Launch.testing && !Launch.storeShots {
                VStack(spacing: 8) {
                    KeeperButton(title: L.t("test.import"), id: "test.import") {
                        Task { await model.simulateImport() }
                    }
                    KeeperButton(title: L.t("test.family"), id: "test.family") {
                        Task { await model.simulateImport(family: true) }
                    }
                    if model.reviewRequested { Text(L.t("test.review")).accessibilityIdentifier("test.reviewRequested") }
                }
                .disabled(model.working)
            }
            #endif
        }
    }

    @ViewBuilder private var tools: some View {
        KeeperButton(title: L.t("home.backup"), symbol: "archivebox", id: "home.backup", action: backup)
        if !model.library.messages.isEmpty {
            KeeperButton(title: L.t("home.card"), symbol: "square.and.arrow.up", id: "home.card") { card(nil) }
        }
        KeeperButton(title: L.t("home.settings"), symbol: "gearshape", id: "home.settings", action: settings)
    }
}

struct PersonView: View {
    @ObservedObject var model: KeeperModel
    @ObservedObject var playback: Playback
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var starredOnly = false
    @State private var editing: Message?
    @State private var deleting: Message?
    @State private var showDeleteConfirmation = false

    private var person: Person? { model.library.people.first { $0.id == id } }
    private var messages: [Message] { model.library.messages(for: id) }

    private var filtered: [Message] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.filter { message in
            (!starredOnly || message.starred) && (needle.isEmpty ||
              message.note.localizedStandardContains(needle) ||
              message.shownDate.localizedStandardContains(needle) ||
              L.isoDay(message.date, zone: message.zone).contains(needle))
        }
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 16) {
                Button { dismiss() } label: {
                    Label(L.t("library"), systemImage: "chevron.left").frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("person.back")
                if let person { PageTitle(title: person.name, subtitle: L.count(messages.count)) }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.accent).accessibilityHidden(true)
                    TextField(L.t("person.search"), text: $query)
                        .frame(minHeight: 44).accessibilityIdentifier("person.search")
                }
                .padding(.horizontal, 10).modifier(Theme.panel())
            }
            .listRowInsets(EdgeInsets(top: 3, leading: 22, bottom: 0, trailing: 22))
            .listRowBackground(Theme.paper)
            .listRowSeparator(.hidden)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { starredOnly.toggle() } label: {
                        Label(L.t("person.starred"), systemImage: starredOnly ? "star.fill" : "star")
                            .frame(minHeight: 44).padding(.horizontal, 9)
                            .background(starredOnly ? Theme.tint : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(starredOnly ? .isSelected : [])
                    .accessibilityIdentifier("person.starred")
                    Spacer()
                    Button { Task { await model.export { try $0.exportPerson(id) } } } label: {
                        Label(L.t("person.export"), systemImage: "square.and.arrow.up").frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("person.export")
                    .disabled(model.working)
                }
                if let selected = messages.first(where: { $0.id == playback.selected }) {
                    PlaybackControls(playback: playback, message: selected) {
                        Task { await model.update { try $0.setStar(selected.id) } }
                    }
                }
                if model.working { Busy() }
                if let error = model.error { InlineError(error: error) }
                if let status = model.status {
                    shareStatus(status).accessibilityIdentifier("share.requested")
                }
                SectionLabel(L.t("person.messages"))
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 22, bottom: 7, trailing: 22))
            .listRowBackground(Theme.paper)
            .listRowSeparator(.hidden)
            if filtered.isEmpty {
                Text(L.t("person.empty")).foregroundStyle(Theme.accent)
                    .listRowBackground(Theme.paper).listRowSeparator(.hidden)
            }
            ForEach(filtered) { message in
                messageRow(message)
                    .listRowBackground(Theme.card)
                    .listRowInsets(EdgeInsets(top: 3, leading: 19, bottom: 3, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleting = message
                            showDeleteConfirmation = true
                        } label: {
                            Label(L.t("delete"), systemImage: "trash")
                        }
                        .accessibilityIdentifier("message.delete")
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .scrollDismissesKeyboard(.immediately)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { model.status = nil; model.error = nil }
        .onDisappear { playback.stop() }
        .sheet(item: $editing) { message in
            if !model.locked {
                MessageEditor(model: model, message: message)
                    .accessibilityHidden(model.locked)
            }
        }
        .alert(L.t("delete.title"), isPresented: $showDeleteConfirmation, presenting: deleting) { message in
            Button(L.t("delete"), role: .destructive) {
                if playback.selected == message.id { playback.stop() }
                Task { await model.update { try $0.remove(message.id) } }
            }
            Button(L.t("cancel"), role: .cancel) { }
        } message: { _ in Text(L.t("delete.body")) }
    }

    @ViewBuilder private func shareStatus(_ status: String) -> some View {
        let text = Text(status).font(.subheadline)
        #if DEBUG
        if Launch.testing, status == L.t("share.ready") {
            text.accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(status))
                .accessibilityValue(Text(verbatim: model.shareReceiptExtension))
        } else {
            text
        }
        #else
        text
        #endif
    }

    private func messageRow(_ message: Message) -> some View {
        HStack(spacing: 10) {
            Button {
                if let vault = model.vault {
                    playback.open(id: message.id, from: vault.originalURL(message), format: message.format,
                                  duration: message.duration, hash: message.hash)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: playback.selected == message.id && playback.playing ? "pause.circle" : "play.circle")
                        .font(.title3).foregroundStyle(Theme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(message.shownDate + " · " + L.duration(message.duration))
                            .font(.caption).foregroundStyle(Theme.accent)
                        if playback.selected == message.id, playback.error != nil {
                            Text(L.t("error.playback")).font(.caption).foregroundStyle(Theme.ink)
                        }
                    }
                    Spacer(minLength: 0)
                    if message.starred {
                        Image(systemName: "star.fill").foregroundStyle(Theme.wheat).accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 57).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("message.play." + message.id.uuidString)
            .accessibilityValue(message.starred ? L.t("star") : "")
            .contextMenu { messageActions(message) }

            #if DEBUG
            if Launch.testing && Launch.arguments.contains("-share-export-test") {
                HStack(spacing: 0) {
                    IconControl(symbol: "arrow.up.document", label: "Test " + L.t("message.original"),
                                id: "test.message.original." + message.id.uuidString) {
                        exportMessage(message.id, family: false)
                    }
                    if person != nil {
                        IconControl(symbol: "person.2", label: "Test " + L.t("message.family"),
                                    id: "test.message.family." + message.id.uuidString) {
                            exportMessage(message.id, family: true)
                        }
                    }
                }
                .disabled(model.working)
            }
            #endif

            Menu { messageActions(message) } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.accent).frame(width: 44, height: 44)
            }
            .accessibilityLabel(L.t("message.more"))
            .accessibilityIdentifier("message.more." + message.id.uuidString)
            .disabled(model.working)
        }
    }

    private func exportMessage(_ id: UUID, family: Bool) {
        Task { await model.export { try $0.exportMessage(id, family: family) } }
    }

    @ViewBuilder private func messageActions(_ message: Message) -> some View {
        Button(L.t("message.edit"), systemImage: "square.and.pencil") { editing = message }
            .accessibilityIdentifier("message.edit")
        if model.library.people.contains(where: { $0.id != message.personID }) {
            Menu {
                ForEach(model.library.people.filter { $0.id != message.personID }) { person in
                    Button(person.name) {
                        if playback.selected == message.id { playback.stop() }
                        Task { await model.update { try $0.move(message.id, to: person.id) } }
                    }
                    .accessibilityIdentifier("message.move." + person.id.uuidString)
                }
            } label: { Label(L.t("message.move"), systemImage: "person.crop.circle.badge.arrow.right") }
            .accessibilityIdentifier("message.move")
        }
        Button(L.t("message.original"), systemImage: "arrow.up.document") {
            exportMessage(message.id, family: false)
        }
        .accessibilityIdentifier("message.original")
        if let person {
            Button {
                exportMessage(message.id, family: true)
            } label: {
                Text(L.t("message.family"))
                Text(L.f("family.includes", person.name))
                Image(systemName: "person.2")
            }
            .accessibilityIdentifier("message.family")
        }
        Button(L.t(message.starred ? "unstar" : "star"), systemImage: message.starred ? "star.slash" : "star") {
            Task { await model.update { try $0.setStar(message.id) } }
        }
        .accessibilityIdentifier("message.star")
    }
}

private struct MessageEditor: View {
    @ObservedObject var model: KeeperModel
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var name: UUID
    @State private var note: String
    @State private var date: Date
    @State private var hasDate: Bool

    init(model: KeeperModel, message: Message) {
        self.model = model
        self.message = message
        _name = State(initialValue: message.personID)
        _note = State(initialValue: message.note)
        _date = State(initialValue: message.date)
        _hasDate = State(initialValue: message.sourceDate != nil)
    }

    var body: some View {
        let covered = model.privacyEnabled && (phase != .active || model.locked)
        KeeperPage {
            HStack {
                PageTitle(title: L.t("message.edit"))
                Button(L.t("cancel")) { dismiss() }
                    .frame(minHeight: 44).accessibilityIdentifier("edit.cancel")
            }
            ImportDetails(note: $note, hasDate: $hasDate, date: $date)
            Picker(L.t("import.to"), selection: $name) {
                ForEach(model.library.people) { person in Text(person.name).tag(person.id) }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("edit.person")
            if let error = model.error { InlineError(error: error) }
            KeeperButton(title: L.t("save"), primary: true, id: "edit.save") {
                let selected = name
                let text = note
                let chosenDate = hasDate ? date : nil
                let zone = chosenDate.flatMap { $0 == message.sourceDate ? message.sourceZone : TimeZone.current.identifier }
                Task {
                    await model.update { try $0.edit(message.id, person: selected, note: text, date: chosenDate, zone: zone) }
                    if model.error == nil { dismiss() }
                }
            }
            .disabled(model.working)
        }
        .accessibilityHidden(covered)
        .overlay { if covered { Theme.paper.ignoresSafeArea() } }
    }
}
