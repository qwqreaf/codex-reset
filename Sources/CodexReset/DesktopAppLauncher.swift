import AppKit

@MainActor
enum DesktopAppLauncher {
    static func open(threadId: String) async throws -> NSRunningApplication {
        guard let url = URL(string: "codex://threads/\(threadId)") else {
            throw desktopError("Invalid target chat URL")
        }
        return try await open(url: url, openURL: { NSWorkspace.shared.open($0) },
                              runningApplication: {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        }, activate: { $0.activate(options: []) },
                              wait: { try await Task.sleep(nanoseconds: 500_000_000) })
    }

    /// Opening the URL launches a stopped app. Resolve its process afterwards,
    /// allowing time for Launch Services before creating the accessibility root.
    static func open<Application>(url: URL, openURL: (URL) -> Bool,
                                  runningApplication: () -> Application?,
                                  activate: (Application) -> Void,
                                  wait: () async throws -> Void) async throws -> Application {
        guard openURL(url) else { throw desktopError("Cannot open target chat in Codex") }
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let app = runningApplication() { activate(app); return app }
            try await wait()
        }
        throw desktopError("Codex did not launch within 10s after opening the target chat")
    }
}
