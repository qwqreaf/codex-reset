import Foundation
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? fm.removeItem(at: dir) }
let store = ActivityLogStore(directory: dir)
let now = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86400
func add(_ date: Date, _ text: String) throws {
    try store.append(StoredLogEntry(timestamp: date, zh: "日本語・中文\n" + text, en: text), now: date)
}
try add(now.addingTimeInterval(-8 * day), "expired")
try add(now.addingTimeInterval(-7 * day - 10), "boundary-expired")
try add(now.addingTimeInterval(-7 * day + 3600), "boundary-kept")
for i in 0..<1200 { try add(now.addingTimeInterval(Double(i)), "message-\(i)") }
let restarted = ActivityLogStore(directory: dir)
let all = try restarted.recent(limit: 10000, now: now)
precondition(all.count == 1201)
precondition(all.first?.en == "boundary-kept")
precondition(all.last?.en == "message-1199")
precondition(all.last!.zh.contains("日本語・中文\n"))
let visible = try restarted.recent(limit: 1000, now: now)
precondition(visible.count == 1000)
try restarted.prune(now: now.addingTimeInterval(9 * day))
let expired = try restarted.recent(limit: 10, now: now.addingTimeInterval(9 * day))
precondition(expired.isEmpty)
let unrelated = dir.appendingPathComponent("notes.txt")
try Data("keep".utf8).write(to: unrelated)
try restarted.prune(now: now.addingTimeInterval(20 * day))
precondition(fm.fileExists(atPath: unrelated.path))
let invalid = dir.appendingPathComponent("not-a-directory")
try Data().write(to: invalid)
do { try ActivityLogStore(directory: invalid).append(StoredLogEntry(timestamp: now, zh: "x", en: "x"), now: now); fatalError("Expected error") }
catch { print("PASS: archive reports write errors") }
print("PASS: >1000 entries, restart, bilingual multiline, seven-day cutoff within a file, expired files, unrelated file preservation")
