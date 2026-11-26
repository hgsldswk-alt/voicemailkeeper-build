import Foundation

enum ZipArchive {
    struct Entry {
        let name: String
        let payload: Payload

        enum Payload {
            case bytes(Data)
            case file(URL)
        }

        func data() throws -> Data {
            switch payload {
            case .bytes(let bytes): return bytes
            case .file(let url):
                _ = try VaultFiles.size(url, max: VaultFiles.audioLimit)
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }
        }

        func length() throws -> Int {
            switch payload {
            case .bytes(let bytes): return bytes.count
            case .file(let url): return try VaultFiles.size(url, max: VaultFiles.audioLimit)
            }
        }
    }

    private static let endSignature: UInt32 = 0x06054b50
    private static let localSignature: UInt32 = 0x04034b50
    private static let centralSignature: UInt32 = 0x02014b50
    private static let utf8: UInt16 = 0x800
    static let maxEntries = 10_002

    static func safePath(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1024 && !name.contains("\\") && !name.contains(":")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt32(crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count)))
        }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        guard !entries.isEmpty, entries.count <= maxEntries, Set(entries.map(\.name)).count == entries.count,
              entries.allSatisfy({ safePath($0.name) }) else { throw KeeperError.badPackage }
        var estimated = 22
        for entry in entries {
            let length = try entry.length()
            guard (1...VaultFiles.audioLimit).contains(length) else { throw KeeperError.tooLarge }
            estimated += length + 76 + 2 * entry.name.utf8.count
        }
        guard estimated <= VaultFiles.packageLimit else { throw KeeperError.tooLarge }
        try VaultFiles.requireSpace(at: url.deletingLastPathComponent(), bytes: estimated)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: VaultFiles.protection) else {
            throw KeeperError.storage
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var table = Data()
        var offset = 0
        for entry in entries {
            try Task.checkCancellation()
            let name = Data(entry.name.utf8)
            let bytes = try entry.data()
            let crc = checksum(bytes)
            let length = UInt32(bytes.count)
            var local = Data()
            local.le(localSignature)
            local.le(UInt16(20)); local.le(utf8); local.le(UInt16(0))
            local.le(UInt16(0)); local.le(UInt16(33))
            local.le(crc); local.le(length); local.le(length)
            local.le(UInt16(name.count)); local.le(UInt16(0))
            local.append(name)
            try handle.write(contentsOf: local)
            try handle.write(contentsOf: bytes)

            table.le(centralSignature)
            table.le(UInt16(20)); table.le(UInt16(20)); table.le(utf8); table.le(UInt16(0))
            table.le(UInt16(0)); table.le(UInt16(33))
            table.le(crc); table.le(length); table.le(length)
            table.le(UInt16(name.count)); table.le(UInt16(0)); table.le(UInt16(0))
            table.le(UInt16(0)); table.le(UInt16(0)); table.le(UInt32(0)); table.le(UInt32(offset))
            table.append(name)
            offset += local.count + bytes.count
        }
        var end = Data()
        end.le(endSignature)
        end.le(UInt16(0)); end.le(UInt16(0))
        end.le(UInt16(entries.count)); end.le(UInt16(entries.count))
        end.le(UInt32(table.count)); end.le(UInt32(offset)); end.le(UInt16(0))
        try handle.write(contentsOf: table)
        try handle.write(contentsOf: end)
        try handle.synchronize()
    }

    struct Reader {
        let data: Data
        let entries: [String: Range<Int>]

        init(_ url: URL) throws {
            _ = try VaultFiles.size(url, max: VaultFiles.packageLimit)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count >= 22 else { throw KeeperError.badPackage }
            let end = data.count - 22
            let count = data.u16(end + 10)
            let centralStart = data.u32(end + 16)
            guard data.u32(end) == Int(endSignature), data.u16(end + 20) == 0,
                  data.u16(end + 4) == 0, data.u16(end + 6) == 0, data.u16(end + 8) == count,
                  (1...maxEntries).contains(count), centralStart <= end,
                  centralStart + data.u32(end + 12) == end else { throw KeeperError.badPackage }
            var entries: [String: Range<Int>] = [:]
            var occupied: [Range<Int>] = []
            var cursor = centralStart
            for _ in 0..<count {
                try Task.checkCancellation()
                guard cursor + 46 <= end, data.u32(cursor) == Int(centralSignature),
                      data.u16(cursor + 8) == Int(utf8), data.u16(cursor + 10) == 0,
                      data.u16(cursor + 34) == 0, data.u16(cursor + 30) == 0, data.u16(cursor + 32) == 0 else {
                    throw KeeperError.badPackage
                }
                let crc = data.u32(cursor + 16)
                let size = data.u32(cursor + 24)
                let length = data.u16(cursor + 28)
                let local = data.u32(cursor + 42)
                guard size > 0, size <= VaultFiles.audioLimit, size == data.u32(cursor + 20),
                      cursor + 46 + length <= end, local + 30 + length <= centralStart,
                      data.u32(local) == Int(localSignature), data.u16(local + 6) == Int(utf8), data.u16(local + 8) == 0,
                      data.u32(local + 14) == crc, data.u32(local + 18) == size, data.u32(local + 22) == size,
                      data.u16(local + 26) == length, data.u16(local + 28) == 0 else { throw KeeperError.badPackage }
                let named = data[(cursor + 46)..<(cursor + 46 + length)]
                let body = local + 30 + length
                guard named == data[(local + 30)..<body], let name = String(data: named, encoding: .utf8),
                      safePath(name), entries[name] == nil, body + size <= centralStart else { throw KeeperError.badPackage }
                let range = body..<(body + size)
                guard Int(checksum(data[range])) == crc else { throw KeeperError.badPackage }
                entries[name] = range
                occupied.append(local..<range.upperBound)
                cursor += 46 + length
            }
            var next = 0
            for range in occupied.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard range.lowerBound == next else { throw KeeperError.badPackage }
                next = range.upperBound
            }
            guard cursor == end, next == centralStart else { throw KeeperError.badPackage }
            self.data = data
            self.entries = entries
        }

        func bytes(_ name: String) throws -> Data {
            guard let range = entries[name] else { throw KeeperError.badPackage }
            return data[range]
        }
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ input: T) {
        var value = input.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func u16(_ start: Int) -> Int {
        Int(self[start]) | (Int(self[start + 1]) << 8)
    }

    func u32(_ start: Int) -> Int {
        u16(start) | (u16(start + 2) << 16)
    }
}
