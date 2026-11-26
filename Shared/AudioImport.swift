import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum AudioFormat: String, Codable, CaseIterable, Sendable {
    case m4a, amr, wav, mp3, caf

    static func identify(_ prefix: Data) -> Self? {
        let ascii = Array(prefix.prefix(16))
        if ascii.starts(with: Array("#!AMR\n".utf8)) || ascii.starts(with: Array("#!AMR-WB\n".utf8)) { return .amr }
        if ascii.starts(with: Array("caff".utf8)) { return .caf }
        if ascii.count >= 12 {
            if ascii.starts(with: Array("RIFF".utf8)) && ascii[8..<12].elementsEqual("WAVE".utf8) { return .wav }
            if ascii[4..<8].elementsEqual("ftyp".utf8) { return .m4a }
        }
        if ascii.starts(with: Array("ID3".utf8)) { return .mp3 }
        if ascii.count >= 4 && ascii[0] == 0xff && ascii[1] & 0xe0 == 0xe0
            && ascii[1] & 0x18 != 0x08 && ascii[1] & 0x06 != 0
            && ascii[2] & 0xf0 != 0xf0 && ascii[2] & 0x0c != 0x0c { return .mp3 }
        return nil
    }
}

enum VaultFiles {
    static let audioLimit = 128 * 1024 * 1024
    static let packageLimit = 1024 * 1024 * 1024
    static let familyLimit = audioLimit + 1024 * 1024
    static let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
    static let familyType = UTType(exportedAs: "com.hgsldswk.voicemailkeeper.message", conformingTo: .data)

    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: protection)
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    static func temporary() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceWork", isDirectory: true)
        try directory(parent)
        let url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try directory(url)
        return url
    }

    static func cleanTemporary() {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceWork", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in children {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate, Date().timeIntervalSince(date) > 86_400 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func safeName(_ name: String) -> String {
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = name.components(separatedBy: disallowed).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(48))
        let visible = short.drop(while: { $0 == "." })
        return visible.isEmpty ? "Audio" : String(visible)
    }

    static func size(_ url: URL, max: Int) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0 else {
            throw KeeperError.corrupt
        }
        guard bytes <= max else { throw KeeperError.tooLarge }
        return bytes
    }

    static func requireSpace(at url: URL, bytes: Int) throws {
        if let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           capacity < bytes { throw KeeperError.disk }
    }

    static func copy(_ source: URL, to output: URL, limit: Int, coordinate: Bool = true) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let transfer: (URL) throws -> Void = { url in
            let bytes = try size(url, max: limit)
            try requireSpace(at: output.deletingLastPathComponent(), bytes: bytes)
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: url, to: output)
            try FileManager.default.setAttributes(protection, ofItemAtPath: output.path)
            _ = try size(output, max: limit)
            try Task.checkCancellation()
        }
        if !coordinate {
            try transfer(source)
            return
        }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result { try transfer(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw KeeperError.unreadable }
        try result.get()
    }

    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

func offMain<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let job = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
}

final class AudioDraft: @unchecked Sendable, Identifiable {
    let id = UUID()
    let directory: URL
    let url: URL
    let filename: String
    let hash: String
    let format: AudioFormat
    let duration: Double
    let sourceDate: Date?
    let sourceZone: String?
    let suggestedName: String?
    let family: Person?
    let familyMessage: Message?

    init(directory: URL, url: URL, filename: String, hash: String, format: AudioFormat, duration: Double,
         sourceDate: Date?, sourceZone: String?, suggestedName: String?, family: Person?, familyMessage: Message?) {
        self.directory = directory
        self.url = url
        self.filename = filename
        self.hash = hash
        self.format = format
        self.duration = duration
        self.sourceDate = sourceDate
        self.sourceZone = sourceZone
        self.suggestedName = suggestedName
        self.family = family
        self.familyMessage = familyMessage
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum AudioImport {
    static func stage(_ source: URL, filename: String? = nil, coordinate: Bool = true, testTag: Int? = nil) throws -> URL {
        let root = try VaultFiles.temporary()
        let hint = (filename ?? source.lastPathComponent) as NSString
        let base = VaultFiles.safeName(hint.deletingPathExtension)
        let suffix = hint.pathExtension.isEmpty ? "" : "." + VaultFiles.safeName(hint.pathExtension)
        let output = root.appendingPathComponent(base + suffix)
        do {
            try VaultFiles.copy(source, to: output, limit: VaultFiles.audioLimit, coordinate: coordinate)
            #if DEBUG
            if Launch.testing, let testTag {
                var atom = Data([0, 0, 0, 16, 102, 114, 101, 101])
                var value = UInt64(testTag).bigEndian
                withUnsafeBytes(of: &value) { atom.append(contentsOf: $0) }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: atom)
            }
            #endif
            return output
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func prepare(_ source: URL, testTag: Int? = nil) async throws -> AudioDraft {
        do {
            let staged = try stage(source, testTag: testTag)
            return try await validate(staged)
        } catch {
            throw KeeperError.map(error, fallback: .unreadable)
        }
    }

    static func validate(_ staged: URL, family: Person? = nil, message: Message? = nil) async throws -> AudioDraft {
        let root = staged.deletingLastPathComponent()
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: root) } }
        let format = try detect(staged)
        let name = message?.filename ?? staged.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if let claimed = AudioFormat(rawValue: ext), claimed != format { throw KeeperError.corrupt }
        let base = (name as NSString).deletingPathExtension
        let filename = VaultFiles.safeName(base.isEmpty ? name : base) + "." + format.rawValue
        let url = root.appendingPathComponent(filename)
        if staged != url { try FileManager.default.moveItem(at: staged, to: url) }

        let duration = try verify(url, format: format)
        let hash = try VaultFiles.hash(url)
        var date = message?.sourceDate
        var zone = message?.sourceZone
        var suggestion: String?
        if family == nil && format != .amr {
            let asset = AVURLAsset(url: url)
            if format == .m4a {
                guard let videos = try? await asset.loadTracks(withMediaType: .video), videos.isEmpty else {
                    throw KeeperError.unsupported
                }
            }
            if let dateItem = try? await asset.load(.creationDate) {
                date = try? await dateItem.load(.dateValue)
                if date != nil, let text = try? await dateItem.load(.stringValue) {
                    zone = sourceTimeZone(text)
                }
            }
            if let metadata = try? await asset.load(.commonMetadata),
               let artist = metadata.first(where: { $0.commonKey == .commonKeyArtist }),
               let value = try? await artist.load(.stringValue) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { suggestion = String(trimmed.prefix(80)) }
            }
        }
        try Task.checkCancellation()
        retained = true
        return AudioDraft(directory: root, url: url, filename: filename, hash: hash, format: format,
                          duration: duration, sourceDate: date, sourceZone: zone, suggestedName: suggestion,
                          family: family, familyMessage: message)
    }

    static func sourceTimeZone(_ text: String) -> String? {
        if text.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)?.identifier }
        guard let match = text.range(of: "[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) else { return nil }
        let parts = Array(text[match].filter { $0 != ":" })
        guard parts.count == 5, let hours = Int(String(parts[1...2])), let minutes = Int(String(parts[3...4])),
              hours <= 18, minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (parts[0] == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))?.identifier
    }

    static func detect(_ url: URL) throws -> AudioFormat {
        _ = try VaultFiles.size(url, max: VaultFiles.audioLimit)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard let prefix = try input.read(upToCount: 16), let format = AudioFormat.identify(prefix) else {
            throw KeeperError.unsupported
        }
        return format
    }

    static func verify(_ url: URL, format: AudioFormat) throws -> Double {
        if format == .amr { return try AMR.decode(url, to: nil) }
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate.isFinite, sampleRate > 0, file.length > 0, file.length <= Int64(sampleRate * 86_400),
                  file.processingFormat.channelCount > 0, file.processingFormat.channelCount <= 32,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
                throw KeeperError.corrupt
            }
            var decoded: AVAudioFramePosition = 0
            while decoded < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                decoded += AVAudioFramePosition(buffer.frameLength)
            }
            guard decoded > 0, Double(file.length - decoded) / sampleRate < 0.08 else { throw KeeperError.corrupt }
            return Double(decoded) / sampleRate
        } catch {
            throw KeeperError.map(error, fallback: .corrupt)
        }
    }
}

enum AMR {
    private static let narrowSizes = [12, 13, 15, 17, 19, 20, 26, 31, 5, -1, -1, -1, -1, -1, -1, 0]
    private static let wideSizes = [17, 23, 32, 36, 40, 46, 50, 58, 60, 5, -1, -1, -1, -1, 0, 0]

    static func decode(_ url: URL, to pcm: URL?) throws -> Double {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let wide = data.starts(with: "#!AMR-WB\n".utf8)
        guard wide || data.starts(with: "#!AMR\n".utf8) else { throw KeeperError.corrupt }
        let sizes = wide ? wideSizes : narrowSizes
        let sampleRate = wide ? 16_000 : 8_000
        let sampleCount = sampleRate / 50
        let file: AVAudioFile?
        let buffer: AVAudioPCMBuffer?
        if let pcm {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                             channels: 1, interleaved: true),
                  let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount * 50)) else {
                throw KeeperError.playback
            }
            file = try AVAudioFile(forWriting: pcm, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            buffer = block
        } else {
            file = nil
            buffer = nil
        }
        guard let decoder = wide ? D_IF_init() : Decoder_Interface_init() else { throw KeeperError.corrupt }
        defer {
            if wide { D_IF_exit(decoder) } else { Decoder_Interface_exit(decoder) }
        }
        var samples = [Int16](repeating: 0, count: sampleCount)
        var padded = [UInt8](repeating: 0, count: 64)
        var start = wide ? 9 : 6
        var frames = 0
        var voiceFrame = false
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            while start < bytes.count {
                if frames % 50 == 0 { try Task.checkCancellation() }
                let header = bytes[start]
                let mode = Int((header >> 3) & 15)
                let count = sizes[mode]
                guard header & 0x83 == 0, count >= 0, start + 1 + count <= bytes.count,
                      frames < 86_400 * 50 else {
                    throw KeeperError.corrupt
                }
                let usable = header & 4 != 0 && count > 0
                voiceFrame = voiceFrame || usable
                for index in 0...count { padded[index] = bytes[start + index] }
                padded.withUnsafeBufferPointer { input in
                    samples.withUnsafeMutableBufferPointer { output in
                        if wide { D_IF_decode(decoder, input.baseAddress, output.baseAddress, usable ? 0 : 1) }
                        else { Decoder_Interface_Decode(decoder, input.baseAddress, output.baseAddress, usable ? 0 : 1) }
                    }
                }
                if let file, let buffer, let channel = buffer.int16ChannelData?[0] {
                    samples.withUnsafeBufferPointer { source in
                        if let address = source.baseAddress {
                            channel.advanced(by: Int(buffer.frameLength)).update(from: address, count: sampleCount)
                        }
                    }
                    buffer.frameLength += AVAudioFrameCount(sampleCount)
                    if buffer.frameLength == buffer.frameCapacity {
                        try file.write(from: buffer)
                        buffer.frameLength = 0
                    }
                }
                frames += 1
                start += 1 + count
            }
        }
        if let file, let buffer, buffer.frameLength > 0 { try file.write(from: buffer) }
        guard voiceFrame else { throw KeeperError.corrupt }
        return Double(frames) / 50
    }
}
