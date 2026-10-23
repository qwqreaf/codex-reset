import Foundation
import SQLite3

struct GoalState: Equatable {
    let id: String
    let status: String

    enum Action: Equatable { case resume, send, refuse }
    var action: Action {
        switch status {
        case "paused", "usage_limited": return .resume
        case "active": return .send
        default: return .refuse
        }
    }

    static func read(codexHome: String, threadId: String, onRetry: ((String) -> Void)? = nil) throws -> GoalState? {
        for attempt in 0..<4 {
            do { return try readOnce(codexHome: codexHome, threadId: threadId) }
            catch {
                let failure = error as NSError
                let baseCode = failure.code & 0xff
                let transient = failure.domain == "CodexReset.GoalDatabase" &&
                    [Int(SQLITE_BUSY), Int(SQLITE_LOCKED), Int(SQLITE_SCHEMA), Int(SQLITE_PROTOCOL), Int(SQLITE_READONLY)].contains(baseCode)
                guard transient, attempt < 3 else { throw error }
                onRetry?("Goal DB read retry \(attempt + 1)/3: \(failure.localizedDescription)")
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        throw desktopError("Goal DB retries exhausted")
    }

    private static func readOnce(codexHome: String, threadId: String) throws -> GoalState? {
        let path = codexHome + "/goals_1.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let error = databaseError(db, stage: "open")
            if let db { sqlite3_close(db) }
            throw error
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT goal_id, status FROM thread_goals WHERE thread_id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw databaseError(db, stage: "prepare")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0), let status = sqlite3_column_text(stmt, 1) else {
            throw databaseError(db, stage: "step")
        }
        return GoalState(id: String(cString: id), status: String(cString: status))
    }
    private static func databaseError(_ db: OpaquePointer?, stage: String) -> NSError {
        let code = sqlite3_extended_errcode(db)
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        return NSError(domain: "CodexReset.GoalDatabase", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Goal database \(stage) failed (SQLite \(code)): \(message)"])
    }

}

func desktopError(_ text: String) -> NSError {
    NSError(domain: "CodexReset.Desktop", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}
