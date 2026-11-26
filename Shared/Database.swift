import Foundation
import SQLite3

final class Database {
    private let handle: OpaquePointer

    enum Value {
        case text(String)
        case blob(Data)
    }

    init(_ url: URL) throws {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw KeeperError.storage
        }
        handle = db
        sqlite3_busy_timeout(db, 15_000)
        try run("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        try statement(sql, values) { query in
            let result = sqlite3_step(query)
            guard result == SQLITE_DONE else { throw failure(result) }
        }
    }

    func rows<T>(_ sql: String, _ values: [Value] = [], decode: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(sql, values) { query in
            var rows: [T] = []
            while true {
                let state = sqlite3_step(query)
                if state == SQLITE_DONE { return rows }
                guard state == SQLITE_ROW else { throw failure(state) }
                rows.append(try decode(query))
            }
        }
    }

    func run(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw failure(status) }
    }

    func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try run(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let output = try body()
            try run("COMMIT")
            return output
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func decode<T: Decodable>(_ query: OpaquePointer, as type: T.Type) throws -> T {
        guard let bytes = sqlite3_column_blob(query, 0) else { throw KeeperError.storage }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        return try JSONDecoder().decode(type, from: data)
    }

    static func text(_ query: OpaquePointer, at column: Int32 = 0) throws -> String {
        guard let text = sqlite3_column_text(query, column) else { throw KeeperError.storage }
        return String(cString: text)
    }

    private func statement<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &query, nil)
        guard status == SQLITE_OK, let query else { throw failure(status) }
        defer { sqlite3_finalize(query) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(query, slot, $0, -1, transient) }
            case .blob(let data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(query, slot, $0.baseAddress, Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
        return try body(query)
    }

    private func failure(_ code: Int32) -> KeeperError {
        code == SQLITE_FULL ? .disk : .storage
    }
}
