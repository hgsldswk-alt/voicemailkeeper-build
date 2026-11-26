import SwiftUI
import UIKit

struct CardView: View {
    @ObservedObject var model: KeeperModel
    let milestone: Int?
    @State private var person: UUID?
    @State private var showName = false
    @State private var rendering = false

    private var selected: Person? { model.library.people.first { $0.id == person } }
    private var records: [Message] { selected.map { model.library.messages(for: $0.id) } ?? model.library.messages }
    private var design: CardDesign {
        let count = milestone ?? records.count
        let text: String
        if showName, let selected { text = L.f(count == 1 ? "card.namedOne" : "card.named", selected.name, count) }
        else { text = L.f(count == 1 ? "card.one" : "card.count", count) }
        let years = records.map { item -> Int in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = item.zone.flatMap(TimeZone.init(identifier:)) ?? .current
            return calendar.component(.year, from: item.date)
        }
        let start = years.min() ?? Calendar.current.component(.year, from: .now)
        let end = years.max() ?? start
        return CardDesign(caption: text, years: start == end ? String(start) : "\(start)–\(end)")
    }

    var body: some View {
        KeeperPage {
            LibraryBack()
            PageTitle(title: L.t(milestone == nil ? "home.card" : "milestone.card"))
            if milestone == nil {
                Picker(L.t("card.scope"), selection: $person) {
                    Text(L.t("card.everyone")).tag(UUID?.none)
                    ForEach(model.library.people) { item in Text(item.name).tag(Optional(item.id)) }
                }
                .frame(minHeight: 44).accessibilityIdentifier("card.scope")
            }
            CardArt(design: design).aspectRatio(4.0 / 5.0, contentMode: .fit)
                .frame(maxWidth: 380).frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            if milestone == nil, selected != nil {
                Toggle(L.t("card.includeName"), isOn: $showName)
                    .frame(minHeight: 44).accessibilityIdentifier("card.includeName")
                    .padding(.horizontal, 10).modifier(Theme.panel())
            }
            Text(design.caption + "\n" + ShareCard.topic).font(.subheadline).foregroundStyle(Theme.accent)
            KeeperButton(title: L.t("card.share"), symbol: "square.and.arrow.up", primary: true, id: "card.share", action: export)
                .disabled(model.working || rendering)
            Text(L.t("card.help")).font(.caption).foregroundStyle(Theme.accent)
            if model.working || rendering { Busy() }
            if let error = model.error { InlineError(error: error) }
            if let status = model.status { Text(status).accessibilityIdentifier("share.requested") }
        }
        .onAppear { model.status = nil; model.error = nil }
        .onChange(of: person) { _, _ in showName = false }
    }

    @MainActor private func export() {
        rendering = true
        let current = design
        Task {
            defer { rendering = false }
            let renderer = ImageRenderer(content: CardArt(design: current).frame(width: 360, height: 450))
            renderer.scale = 3
            guard let bytes = renderer.uiImage?.pngData() else { model.error = .failedExport; return }
            await model.export({ _ in
                let folder = try VaultFiles.temporary()
                let output = folder.appendingPathComponent("Voicemail-Keeper.png")
                do {
                    try bytes.write(to: output, options: [.atomic, .completeFileProtection])
                    return ExportFile(directory: folder, url: output)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
            }, caption: current.caption + "\n" + ShareCard.topic)
        }
    }
}

