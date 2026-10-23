import Foundation
import SQLite3

@main struct Tests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        var db: OpaquePointer?
        precondition(sqlite3_open(dir.appendingPathComponent("goals_1.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK) }
        sql("CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, goal_id TEXT, status TEXT)")
        sql("INSERT INTO thread_goals VALUES ('target', 'same-goal', 'paused')")
        var state = try GoalState.read(codexHome: dir.path, threadId: "target")
        precondition(state?.action == .resume)
        sql("UPDATE thread_goals SET status='usage_limited'")
        state = try GoalState.read(codexHome: dir.path, threadId: "target")
        precondition(state?.action == .resume)
        sql("UPDATE thread_goals SET status='active'")
        state = try GoalState.read(codexHome: dir.path, threadId: "target")
        precondition(state?.action == .send && state?.id == "same-goal")
        for status in ["complete", "blocked", "budget_limited", "unknown"] {
            sql("UPDATE thread_goals SET status='\(status)'")
            state = try GoalState.read(codexHome: dir.path, threadId: "target")
            precondition(state?.action == .refuse)
        }
        let absent = try GoalState.read(codexHome: dir.path, threadId: "' OR 1=1 --")
        precondition(absent == nil)
        let empty = try DesktopGoalAutomation.draftAction(value: "", command: "Continue")
        precondition(empty)
        let existing = try DesktopGoalAutomation.draftAction(value: "Continue\n", command: "Continue")
        precondition(!existing, "Existing command must be reused without duplicate paste")
        for draft in ["ContinueContinue", "My unsent draft"] {
            do { _ = try DesktopGoalAutomation.draftAction(value: draft, command: "Continue"); fatalError("Expected draft protection") }
            catch { }
        }
        precondition(DesktopGoalAutomation.resumeLabels.contains("目標を再開"))
        precondition(!DesktopGoalAutomation.resumeLabels.contains("Resume"), "Generic buttons must not match")
        print("PASS: paused/usage_limited resume, active sends, other states refuse; bound SQL; existing command reused; other drafts preserved. No live UI events executed.")
    }
}
