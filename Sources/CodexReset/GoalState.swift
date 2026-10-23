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

    static func read(codexHome: String, threadId: String) throws -> GoalState? {
        let path = codexHome + "/goals_1.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw desktopError("Cannot read Goal state")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT goal_id, status FROM thread_goals WHERE thread_id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw desktopError("Goal schema unavailable")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0), let status = sqlite3_column_text(stmt, 1) else {
            throw desktopError("Goal state read failed")
        }
        return GoalState(id: String(cString: id), status: String(cString: status))
    }
}

func desktopError(_ text: String) -> NSError {
    NSError(domain: "CodexReset.Desktop", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}
