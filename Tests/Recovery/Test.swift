import Foundation

final class RecordingEngine: ContinuationEngine {
    var onLog: ((String, String) -> Void)?
    var onNeedRestartCodex: (() -> Void)?
    var onNeedAccessibility: (() -> Void)?
    var lastFailureReason: String?
    var lastDesktopSummary: String?
    var sends: [String] = []
    var cycles = 0
    var handled = Set<String>()
    func alreadyHandled(_ threadId: String) -> Bool { handled.contains(threadId) }
    func beginRecoveryCycle() { cycles += 1; handled.removeAll() }
    func continueThread(client: AppServerClient?, threadId: String, command: String,
                        fallbackToGUI: Bool, allowAppServer: Bool, resumeGoalBeforeSending: Bool) async -> Bool {
        precondition(fallbackToGUI && !allowAppServer, "Recovery must use desktop delivery")
        sends.append(threadId + ":" + command)
        handled.insert(threadId)
        return true
    }
}

@main struct RecoveryTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CodexReset.RecoveryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        var time = Date(timeIntervalSince1970: 2_000_000_000)
        let engine = RecordingEngine()
        let model = AppModel(codexHome: directory.path, engine: engine, defaults: defaults,
                             activityLogStore: ActivityLogStore(directory: directory),
                             now: { time }, notification: { _, _ in })
        model.autoContinue = true
        model.continueCommand = "繼續"
        model.selectedThreadIds = ["target"]
        model.allThreads = [PausedThread(threadId: "target", title: "Target", cwd: "/tmp", recoveryHint: nil, failedAt: 0)]
        let exhausted = try JSONDecoder().decode(AccountRateLimits.self, from: Data("""
        {"rateLimits":{"primary":{"usedPercent":100,"resetsAt":2000000060,"windowDurationMins":300},"rateLimitReachedType":"rate_limit_reached"}}
        """.utf8))
        await model.applyRateLimits(exhausted)
        precondition(engine.sends.isEmpty, "Must wait before reset")
        time.addTimeInterval(60)
        // App-server can retain the exhausted snapshot until the next turn.
        await model.applyRateLimits(exhausted)
        guard engine.sends == ["target:繼續"] else {
            print("FAIL: reset deadline passed, but desktop continuation was never requested (sends=\(engine.sends))")
            exit(1)
        }
        await model.applyRateLimits(exhausted)
        precondition(engine.sends.count == 1, "Same reset must not send twice")
        print("PASS: selected chat reaches desktop delivery once after reset, even with stale 100% quota")

        func limits(primary: Int? = 100, secondary: Int? = nil, reset: Int? = 2_000_000_060,
                    weeklyReset: Int? = 2_000_001_000, reason: String? = nil, spend: Bool = false) throws -> AccountRateLimits {
            var snapshot: [String: Any] = ["spendControlReached": spend]
            if let primary {
                var window: [String: Any] = ["usedPercent": primary]
                if let reset { window["resetsAt"] = reset }
                snapshot["primary"] = window
            }
            if let secondary {
                var window: [String: Any] = ["usedPercent": secondary]
                if let weeklyReset { window["resetsAt"] = weeklyReset }
                snapshot["secondary"] = window
            }
            if let reason { snapshot["rateLimitReachedType"] = reason }
            return try JSONDecoder().decode(AccountRateLimits.self, from: JSONSerialization.data(withJSONObject: ["rateLimits": snapshot]))
        }
        let afterReset = time
        // Use the real orchestration path with a selected chat in every case.
        func check(_ label: String, sequence: [(Date, AccountRateLimits)], sends expected: Int) async {
            let engine = RecordingEngine()
            let candidate = AppModel(codexHome: directory.path, engine: engine, defaults: defaults,
                                     activityLogStore: ActivityLogStore(directory: directory),
                                     now: { time }, notification: { _, _ in })
            candidate.selectedThreadIds = ["target"]
            candidate.allThreads = model.allThreads
            for (date, snapshot) in sequence {
                time = date
                await candidate.applyRateLimits(snapshot)
            }
            precondition(engine.sends.count == expected, label)
            print("PASS: \(label)")
        }
        let beforeReset = afterReset.addingTimeInterval(-60)
        try await check("fresh available response recovers once", sequence: [
            (beforeReset, exhausted), (beforeReset, limits(primary: 10)), (beforeReset, limits(primary: 10))
        ], sends: 1)
        try await check("weekly exhaustion blocks primary reset until weekly deadline", sequence: [
            (beforeReset, limits(secondary: 100)), (afterReset, limits(secondary: 100)),
            (Date(timeIntervalSince1970: 2_000_001_000), limits(secondary: 100))
        ], sends: 1)
        try await check("spend and workspace restrictions block expired windows", sequence: [
            (beforeReset, exhausted), (afterReset, limits(spend: true)),
            (afterReset, limits(reason: "workspace_owner_usage_limit_reached"))
        ], sends: 0)
        try await check("missing reset deadline does not imply recovery", sequence: [
            (beforeReset, limits(reset: nil)), (afterReset, limits(reset: nil))
        ], sends: 0)
        try await check("unknown quota preserves pending recovery", sequence: [
            (beforeReset, exhausted), (afterReset, limits(primary: nil)), (afterReset, limits(primary: 10))
        ], sends: 1)
        try await check("ordinary startup with available quota sends nothing", sequence: [
            (afterReset, limits(primary: 10))
        ], sends: 0)
        await check("startup after an expired exhausted window recovers once", sequence: [
            (afterReset, exhausted), (afterReset, exhausted)
        ], sends: 1)
        try await check("new limit cycle allows another continuation", sequence: [
            (beforeReset, exhausted), (afterReset, exhausted),
            (afterReset, limits(reset: 2_000_000_120)),
            (Date(timeIntervalSince1970: 2_000_000_120), limits(reset: 2_000_000_120))
        ], sends: 2)

        let restarted = AppModel(codexHome: directory.path, engine: RecordingEngine(), defaults: defaults,
                                 activityLogStore: ActivityLogStore(directory: directory), notification: { _, _ in })
        precondition(restarted.selectedThreadIds == ["target"], "Selected chats must survive restart")
        restarted.selectedThreadIds = []
        let deselected = AppModel(codexHome: directory.path, engine: RecordingEngine(), defaults: defaults,
                                  activityLogStore: ActivityLogStore(directory: directory), notification: { _, _ in })
        precondition(deselected.selectedThreadIds.isEmpty, "Explicit deselection must survive restart")
        print("PASS: selected chats and explicit deselection survive restart")

        var launchCalls: [String] = []
        var polls = 0
        let opened = try await DesktopAppLauncher.open(url: URL(string: "codex://threads/target")!, openURL: { url in
            precondition(url.absoluteString == "codex://threads/target")
            launchCalls.append("open")
            return true
        }, runningApplication: { () -> String? in
            launchCalls.append("resolve")
            polls += 1
            return polls >= 2 ? "launched-app" : nil
        }, activate: { app in launchCalls.append("activate:" + app) }, wait: {})
        precondition(opened == "launched-app" && launchCalls == ["open", "resolve", "resolve", "activate:launched-app"])
        var activated = false
        do {
            let _: String = try await DesktopAppLauncher.open(url: URL(string: "codex://threads/target")!,
                openURL: { _ in false }, runningApplication: { "app" }, activate: { _ in activated = true }, wait: {})
            fatalError("Failed URL open must throw")
        } catch { precondition(!activated) }
        do {
            let _: String = try await DesktopAppLauncher.open(url: URL(string: "codex://threads/target")!,
                openURL: { _ in true }, runningApplication: { nil }, activate: { _ in activated = true }, wait: {})
            fatalError("Launch timeout must throw")
        } catch { precondition(!activated) }
        print("PASS: deep link launches a stopped app before process lookup; failed opens and timeouts stop input")
    }
}
