import SwiftUI

struct ImportView: View {
    let draft: AudioDraft
    let library: Library
    let vault: Vault
    let onCancel: () -> Void
    let onFinish: () -> Void
    var startWithNewPerson = false
    @StateObject private var playback = Playback()
    @FocusState private var nameFocused: Bool
    @State private var choice: UUID?
    @State private var adding = false
    @State private var name = ""
    @State private var note = ""
    @State private var date: Date = .now
    @State private var hasDate = false
    @State private var observedDate: Date?
    @State private var editingDetails = false
    @State private var error: KeeperError?
    @State private var conflict: (name: String, target: PersonChoice)?
    @State private var saving = false
    @State private var job: Task<Void, Never>?

    var body: some View {
        KeeperPage {
            HStack {
                Label(L.t("app.name"), systemImage: "waveform").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button(L.t("cancel"), action: onCancel)
                    .frame(minHeight: 44).accessibilityIdentifier("import.cancel")
                    .disabled(saving)
            }
            PageTitle(title: L.t(draft.family == nil ? "import.title" : "family.title"),
                      subtitle: draft.family == nil ? nil : L.t("family.subtitle"))
            filePreview
            if draft.family == nil {
                DisclosureGroup(isExpanded: $editingDetails) {
                    ImportDetails(note: $note, hasDate: $hasDate, date: $date)
                        .padding(.top, 8)
                } label: {
                    Text(L.t("import.details")).frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("import.details")
            }
            if let error { InlineError(error: error) }
            if let conflict {
                VStack(alignment: .leading) {
                    Text(L.f("import.other", conflict.name)).font(.subheadline)
                    KeeperButton(title: L.f("import.saveAnyway", destinationName(conflict.target)), id: "import.saveAnyway") {
                        save(to: conflict.target, allowOther: true)
                    }
                    .disabled(saving)
                }
            }
            personControls.disabled(saving)
            if saving { Busy() }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled()
        .onAppear(perform: initialize)
        .onDisappear {
            job?.cancel()
            playback.stop()
        }
        .onChange(of: name) { _, _ in clearFeedback() }
    }

    private var personControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.family != nil || adding { SectionLabel(L.t("import.to")) }
            if draft.family != nil {
                familyChoices
            } else if !adding, let person = library.defaultImportPerson(suggestedName: draft.suggestedName) {
                audioChoices(defaultPerson: person)
            }
            if adding {
                TextField(L.t("import.name"), text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit {
                        if conflict == nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            save(to: .new(name))
                        }
                    }
                    .padding(12)
                    .modifier(Theme.panel())
                    .focused($nameFocused)
                    .accessibilityIdentifier("import.name")
            } else if !library.people.isEmpty {
                Button {
                    choice = nil
                    adding = true
                    nameFocused = true
                    clearFeedback()
                } label: {
                    Label(L.t("import.new"), systemImage: "plus").frame(minHeight: 44)
                }
                .accessibilityIdentifier("import.new")
            }
            if draft.family != nil || adding, conflict == nil {
                let target = adding ? PersonChoice.new(name) : choice.map(PersonChoice.existing)
                KeeperButton(title: L.t("import.save"), primary: true, id: "import.save") {
                    if let target { save(to: target) }
                }
                .disabled(target == nil || (adding && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            if draft.family == nil, adding, !library.people.isEmpty {
                Button(L.t("import.existing")) {
                    adding = false
                    nameFocused = false
                    clearFeedback()
                }
                .frame(minHeight: 44)
            }
        }
    }

    private func audioChoices(defaultPerson: Person) -> some View {
        VStack(spacing: 7) {
            saveButton(for: defaultPerson, primary: true)
            ForEach(library.people.filter { $0.id != defaultPerson.id }) { person in
                saveButton(for: person, primary: false)
            }
        }
    }

    private func saveButton(for person: Person, primary: Bool) -> some View {
        let target = PersonChoice.existing(person.id)
        return KeeperButton(title: L.f("import.saveTo", person.name), primary: primary,
                            id: primary ? "import.save" : "import.saveTo." + person.id.uuidString) {
            save(to: target)
        }
        .disabled(conflict?.target == target)
    }

    private var familyChoices: some View {
        let matchedID = draft.family.flatMap(library.familyMatch)?.id
        return VStack(alignment: .leading, spacing: 2) {
            if !library.people.isEmpty {
                VStack(spacing: 0) {
                    ForEach(library.people) { person in
                        if person.id != library.people.first?.id { Divider().overlay(Theme.line) }
                        Button {
                            choice = person.id
                            adding = false
                            nameFocused = false
                            clearFeedback()
                        } label: {
                            HStack {
                                Avatar(name: person.name)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(person.name).foregroundStyle(Theme.ink)
                                    if person.id == matchedID {
                                        Text(L.t("family.matched")).font(.caption).foregroundStyle(Theme.accent)
                                    }
                                }
                                Spacer()
                                Image(systemName: choice == person.id && !adding ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 54)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("import.person." + person.id.uuidString)
                        .accessibilityAddTraits(choice == person.id && !adding ? .isSelected : [])
                    }
                }
                .modifier(Theme.panel())
            }
        }
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Theme.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.familyMessage?.title ?? draft.filename).font(.headline)
                    Text(L.f("import.original", L.duration(draft.duration))).font(.caption).foregroundStyle(Theme.accent)
                    if let familyMessage = draft.familyMessage {
                        Text(familyMessage.shownDate).font(.caption).foregroundStyle(Theme.accent)
                    } else if let date = draft.sourceDate {
                        Text(L.date(date, zone: draft.sourceZone)).font(.caption).foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                if draft.family != nil {
                    IconControl(symbol: playback.playing ? "pause.fill" : "play.fill",
                                label: L.t(playback.playing ? "pause" : "play"), id: "family.preview") {
                        playback.open(id: draft.id, from: draft.url, format: draft.format, duration: draft.duration, hash: draft.hash)
                    }
                    .background(Theme.tint, in: Circle())
                    .disabled(playback.loading)
                }
            }
            if draft.family != nil {
                Wave()
                Text(L.f("family.includes", draft.family?.name ?? "")).font(.caption).foregroundStyle(Theme.accent)
            }
            if let error = playback.error { InlineError(error: error) }
        }
        .padding(13).modifier(Theme.panel())
    }

    private func initialize() {
        observedDate = draft.sourceDate
        date = draft.sourceDate ?? .now
        hasDate = draft.sourceDate != nil
        note = draft.familyMessage?.note ?? ""
        if let family = draft.family {
            choice = library.familyMatch(family)?.id
            if choice == nil {
                let matches = library.people.filter { Person.normalized($0.name) == Person.normalized(family.name) }
                name = family.name
                adding = matches.isEmpty
            }
        } else {
            adding = startWithNewPerson || library.people.isEmpty
            if adding { name = draft.suggestedName ?? ""; nameFocused = true }
        }
    }

    private func clearFeedback() {
        conflict = nil
        error = nil
    }

    private func destinationName(_ target: PersonChoice) -> String {
        switch target {
        case .existing(let id): return library.people.first(where: { $0.id == id })?.name ?? ""
        case .new(let name): return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func save(to target: PersonChoice, allowOther: Bool = false) {
        guard !saving else { return }
        nameFocused = false
        saving = true
        clearFeedback()
        let note = note
        let savedDate = hasDate ? date : nil
        let draft = draft
        let zone = savedDate.flatMap { $0 == observedDate ? draft.sourceZone : TimeZone.current.identifier }
        let vault = vault
        job = Task {
            defer { saving = false }
            do {
                let outcome = try await offMain { try vault.save(draft, choice: target, note: note, date: savedDate, zone: zone, allowOtherPerson: allowOther) }
                guard !Task.isCancelled else { return }
                switch outcome {
                case .saved: onFinish()
                case .duplicate: error = .duplicate
                case .otherPerson(let name): conflict = (name, target)
                }
            } catch {
                if !Task.isCancelled { self.error = KeeperError.map(error) }
            }
        }
    }
}

struct ImportDetails: View {
    @Binding var note: String
    @Binding var hasDate: Bool
    @Binding var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(L.t("note"), text: $note, axis: .vertical)
                .lineLimit(1...3).padding(9).modifier(Theme.panel())
                .accessibilityIdentifier("message.note")
            Toggle(L.t("date.known"), isOn: $hasDate)
                .accessibilityIdentifier("message.hasDate")
            if hasDate {
                DatePicker(L.t("date.source"), selection: $date, displayedComponents: .date)
                    .accessibilityIdentifier("message.date")
            }
        }
    }
}
