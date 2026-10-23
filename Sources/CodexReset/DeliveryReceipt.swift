import Foundation
import SQLite3

/// Read-only delivery evidence; this never opens a thread through app-server.
struct DeliveryReceipt {
    let historyPath: String

    init(codexHome: String) { historyPath = codexHome + "/thread_history_1.sqlite" }

    func snapshot(threadId: String) throws -> Int64 {
        try read(threadId: threadId, after: -1, command: nil).ordinal
    }

    func received(threadId: String, command: String, after ordinal: Int64) throws -> Bool {
        try read(threadId: threadId, after: ordinal, command: command).matched
    }

    private func read(threadId: String, after: Int64, command: String?) throws -> (ordinal: Int64, matched: Bool) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(historyPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw failure("Cannot read local chat history; no delivery confirmation available")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        let sql = "SELECT rollout_ordinal, item_json FROM thread_items WHERE thread_id = ? AND item_type = 'userMessage' AND rollout_ordinal > ? ORDER BY rollout_ordinal DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw failure("Chat history schema is unavailable; no delivery confirmation available")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, after)
        var maximum = after
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return (maximum, false) }
            guard rc == SQLITE_ROW else { throw failure("Chat history read failed") }
            maximum = max(maximum, sqlite3_column_int64(stmt, 0))
            if command == nil { return (maximum, false) }
            guard let raw = sqlite3_column_text(stmt, 1),
                  let data = String(cString: raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parts = obj["content"] as? [[String: Any]] else { continue }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if text == command { return (maximum, true) }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "CodexReset.DeliveryReceipt", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Deduplicate within a recovery cycle, not throughout the lifetime of the app.
struct RecoveryCycle {
    private var handled: Set<String> = []
    mutating func begin() { handled.removeAll() }
    mutating func confirm(_ threadId: String) { handled.insert(threadId) }
    func contains(_ threadId: String) -> Bool { handled.contains(threadId) }
}
