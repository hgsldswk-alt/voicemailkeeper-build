import LocalAuthentication
import SwiftUI
import UIKit

enum Theme {
    static let paper = Color(red: 250/255, green: 246/255, blue: 240/255)
    static let ink = Color(red: 43/255, green: 38/255, blue: 34/255)
    static let accent = Color(red: 110/255, green: 98/255, blue: 89/255)
    static let wheat = Color(red: 201/255, green: 164/255, blue: 106/255)
    static let tint = Color(red: 237/255, green: 228/255, blue: 218/255)
    static let line = Color(red: 223/255, green: 213/255, blue: 201/255)
    static let card = Color(red: 255/255, green: 252/255, blue: 247/255)

    static func panel(_ radius: CGFloat = 17) -> some ViewModifier { Panel(radius: radius) }

    private struct Panel: ViewModifier {
        let radius: CGFloat
        func body(content: Content) -> some View {
            content
                .background(Theme.card, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

struct KeeperPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 560)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper.ignoresSafeArea())
    }
}

struct PageTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(.largeTitle, design: .serif)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).foregroundStyle(Theme.accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            .accessibilityAddTraits(.isHeader)
    }
}

struct KeeperButton: View {
    let title: String
    var symbol: String? = nil
    var primary = false
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).multilineTextAlignment(.center)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 10)
            .foregroundStyle(primary ? Theme.paper : Theme.accent)
            .background(primary ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: primary ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct IconControl: View {
    let symbol: String
    let label: String
    let id: String
    var color: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .foregroundStyle(color).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

struct Avatar: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).lineLimit(1)
            .font(.system(.title3, design: .serif)).foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44).background(Theme.tint, in: Circle())
            .accessibilityHidden(true)
    }
}

struct Wave: View {
    private let heights: [CGFloat] = [8, 14, 11, 24, 36, 19, 28, 37, 25, 13, 24, 32, 37, 17, 30, 40, 22, 15, 33, 23, 28, 14, 17, 10, 6]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule().fill(Theme.wheat).frame(width: 3, height: heights[index])
            }
        }
        .accessibilityHidden(true)
    }
}

struct InlineError: View {
    let error: KeeperError
    var body: some View {
        Label(error.localizedDescription, systemImage: "exclamationmark.circle")
            .font(.subheadline).foregroundStyle(Theme.ink)
            .accessibilityIdentifier("status.error")
    }
}

struct Busy: View {
    var body: some View {
        ProgressView().padding(8).accessibilityLabel(L.t("working"))
    }
}

struct LibraryBack: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Label(L.t("library"), systemImage: "chevron.left").frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .accessibilityIdentifier("library.back")
    }
}

enum Authentication {
    static func verify() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = L.t("cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L.t("lock.reason"))) ?? false
    }
}
