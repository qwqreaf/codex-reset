import Foundation
import SQLite3
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
var db: OpaquePointer?
precondition(sqlite3_open(dir.appendingPathComponent("thread_history_1.sqlite").path, &db) == SQLITE_OK)
defer { sqlite3_close(db) }
precondition(sqlite3_exec(db, "CREATE TABLE thread_items (thread_id TEXT, item_type TEXT, rollout_ordinal INTEGER, item_json TEXT)", nil, nil, nil) == SQLITE_OK)
func add(_ thread: String, _ ordinal: Int, _ text: String, type: String = "userMessage") throws {
    let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
    var stmt: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, "INSERT INTO thread_items VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, thread, -1, transient)
    sqlite3_bind_text(stmt, 2, type, -1, transient)
    sqlite3_bind_int64(stmt, 3, Int64(ordinal))
    sqlite3_bind_text(stmt, 4, String(data: data, encoding: .utf8), -1, transient)
    precondition(sqlite3_step(stmt) == SQLITE_DONE)
}
let receipt = DeliveryReceipt(codexHome: dir.path)
try add("target", 1, "Continue")
let baseline = try receipt.snapshot(threadId: "target")
precondition(baseline == 1)
var received = try receipt.received(threadId: "target", command: "Continue", after: baseline)
precondition(!received, "Old matching message must not count")
try add("other", 10, "Continue")
try add("target", 11, "Continue", type: "agentMessage")
try add("target", 12, "Continue later")
received = try receipt.received(threadId: "target", command: "Continue", after: baseline)
precondition(!received, "Other chat, assistant text, and substring must not count")
try add("target", 13, "Continue")
received = try receipt.received(threadId: "target", command: "Continue", after: baseline)
precondition(received)
let next = try receipt.snapshot(threadId: "target")
precondition(next == 13)
received = try receipt.received(threadId: "target", command: "Continue", after: next)
precondition(!received)
let missing = try receipt.snapshot(threadId: "'; DROP TABLE thread_items; --")
precondition(missing == -1)
do { _ = try DeliveryReceipt(codexHome: dir.appendingPathComponent("missing").path).snapshot(threadId: "target"); fatalError("Expected read error") }
catch { print("PASS: missing history reports error before sending") }
var cycle = RecoveryCycle()
cycle.confirm("target")
precondition(cycle.contains("target"))
cycle.begin()
precondition(!cycle.contains("target"), "Manual test must not poison next recovery")
cycle.confirm("target")
precondition(cycle.contains("target"), "Duplicate within same cycle must be skipped")
cycle.begin()
precondition(!cycle.contains("target"))
print("PASS: exact new message in target only, old/other/assistant/substring rejected, bound SQL, repeated recovery cycles")
