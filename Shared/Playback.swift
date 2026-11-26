import AVFoundation
import SwiftUI

@MainActor
final class Playback: ObservableObject {
    static let speeds = [0.75, 1, 1.25, 1.5, 2.0]

    @MainActor
    final class Progress: ObservableObject {
        @Published fileprivate(set) var position: Double = 0
    }

    let progress = Progress()
    @Published private(set) var selected: UUID?
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var duration: Double = 0
    @Published var speed: Double = 1 { didSet { player?.rate = Float(speed) } }
    @Published var loop = false { didSet { player?.numberOfLoops = loop ? -1 : 0 } }
    @Published var error: KeeperError?

    private var prepared: Prepared?
    private var player: AVAudioPlayer? { prepared?.player }
    private var generation = UUID()
    private var job: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var monitors: [Task<Void, Never>] = []

    func open(id: UUID, from url: URL, format: AudioFormat, duration: Double, hash: String) {
        if selected == id {
            if loading { return }
            if player != nil { toggle(); return }
        }
        stop()
        selected = id
        self.duration = duration
        loading = true
        let request = generation
        job = Task { [weak self] in
            do {
                let value = try await offMain { try Prepared(url: url, format: format, hash: hash) }
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.prepared = value
                self.duration = value.player.duration
                self.loading = false
                self.start()
            } catch {
                guard let self, self.generation == request else { return }
                self.loading = false
                self.error = KeeperError.map(error, fallback: .playback)
            }
        }
        monitorSession()
    }

    func toggle() {
        if playing { pause() } else { start() }
    }

    func seek(_ value: Double) {
        let position = min(max(value, 0), duration)
        progress.position = position
        player?.currentTime = position
    }

    func pause() {
        player?.pause()
        playing = false
        if let player { progress.position = player.currentTime }
        observation?.cancel()
        observation = nil
    }

    func stop() {
        generation = UUID()
        job?.cancel()
        job = nil
        pause()
        player?.stop()
        if prepared != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        prepared = nil
        loading = false
        duration = 0
        progress.position = 0
        selected = nil
        error = nil
        loop = false
        speed = 1
    }

    private func start() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            player.enableRate = true
            player.rate = Float(speed)
            player.numberOfLoops = loop ? -1 : 0
            if progress.position >= duration { seek(0) }
            guard player.play() else { throw KeeperError.playback }
            playing = true
            observation?.cancel()
            observation = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, let self, let player = self.player else { break }
                    if !player.isPlaying {
                        self.playing = false
                        self.progress.position = 0
                        break
                    }
                    self.progress.position = player.currentTime
                }
            }
        } catch {
            self.error = .playback
        }
    }

    private func monitorSession() {
        guard monitors.isEmpty else { return }
        monitors = [
            Task { [weak self] in
                for await event in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                    guard let self else { break }
                    if (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { self.pause() }
                }
            },
            Task { [weak self] in
                for await event in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                    guard let self else { break }
                    if (event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self.pause() }
                }
            }
        ]
    }

    deinit { monitors.forEach { $0.cancel() } }

    private final class Prepared: @unchecked Sendable {
        let player: AVAudioPlayer
        let folder: URL?

        init(url: URL, format: AudioFormat, hash: String) throws {
            try Task.checkCancellation()
            guard try VaultFiles.hash(url) == hash else { throw KeeperError.playback }
            let working = format == .amr ? try VaultFiles.temporary() : nil
            do {
                var playable = url
                if let working {
                    playable = working.appendingPathComponent("Playback.caf")
                    let duration = try AMR.decode(url, to: playable)
                    guard duration > 0 else { throw KeeperError.playback }
                }
                player = try AVAudioPlayer(contentsOf: playable)
                guard player.prepareToPlay() else { throw KeeperError.playback }
                folder = working
            } catch {
                if let working { try? FileManager.default.removeItem(at: working) }
                throw error
            }
        }

        deinit { if let folder { try? FileManager.default.removeItem(at: folder) } }
    }
}

struct PlaybackControls: View {
    @ObservedObject var playback: Playback
    @ObservedObject private var progress: Playback.Progress
    let message: Message
    let star: () -> Void

    @MainActor
    init(playback: Playback, message: Message, star: @escaping () -> Void) {
        self._playback = ObservedObject(wrappedValue: playback)
        self._progress = ObservedObject(wrappedValue: playback.progress)
        self.message = message
        self.star = star
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconControl(symbol: playback.playing ? "pause.fill" : "play.fill",
                            label: L.t(playback.playing ? "pause" : "play"), id: "playback.toggle") { playback.toggle() }
                    .background(Theme.tint, in: Circle())
                    .disabled(playback.loading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.title).font(.headline)
                    Text(message.shownDate).font(.caption).foregroundStyle(Theme.accent)
                }
                Spacer()
                IconControl(symbol: message.starred ? "star.fill" : "star",
                            label: L.t(message.starred ? "unstar" : "star"), id: "playback.star",
                            color: message.starred ? Theme.wheat : Theme.accent, action: star)
                    .accessibilityValue(L.t(message.starred ? "yes" : "no"))
            }
            if playback.loading { Busy() }
            if let error = playback.error { InlineError(error: error) }
            Slider(value: Binding(get: { progress.position }, set: { playback.seek($0) }),
                   in: 0...max(playback.duration, 0.01))
                .accessibilityLabel(L.t("playback.position"))
                .accessibilityIdentifier("playback.seek")
            HStack {
                Text(L.duration(progress.position) + " / " + L.duration(playback.duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                Spacer()
                Menu {
                    ForEach(Playback.speeds, id: \.self) { rate in
                        Button(speedText(rate)) { playback.speed = rate }
                    }
                } label: {
                    Text(speedText(playback.speed)).font(.subheadline.weight(.semibold))
                        .frame(minWidth: 48, minHeight: 44)
                }
                .accessibilityLabel(L.t("playback.speed"))
                .accessibilityValue(speedText(playback.speed))
                .accessibilityIdentifier("playback.speed")
                IconControl(symbol: "repeat.1", label: L.t("playback.loop"), id: "playback.loop") { playback.loop.toggle() }
                    .background(playback.loop ? Theme.tint : .clear, in: Circle())
                    .accessibilityValue(L.t(playback.loop ? "yes" : "no"))
            }
        }
        .padding(13)
        .modifier(Theme.panel())
    }

    private func speedText(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
