import Foundation
import AppKit
import ApplicationServices

/// Called by the installed app, not by the development test runner.
/// Goal state and target history are read-only; all changes use the desktop UI.
@MainActor
struct DesktopGoalAutomation {
    let codexHome: String
    let threadId: String
    let resumeGoal: Bool
    let log: (String) -> Void

    static let resumeLabels: Set<String> = ["目標を再開", "Resume goal", "Resume Goal", "恢复目标", "继续目标"]

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func draftAction(value: String, command: String) throws -> Bool {
        let value = normalized(value)
        if value.isEmpty { return true } // Paste once.
        if value == normalized(command) { return false } // Reuse the existing command.
        throw desktopError("Composer contains different text. Nothing typed or sent; inspect the draft.")
    }

    func send(command: String) async throws {
        guard !Self.normalized(command).isEmpty else { throw desktopError("Command is empty") }
        let chats = SQLiteReader(codexHome: codexHome).allThreads()
        guard let title = chats.first(where: { $0.threadId == threadId })?.title,
              chats.filter({ $0.title == title }).count == 1 else {
            throw desktopError("Target chat title is missing or ambiguous. Nothing clicked or typed.")
        }
        let original = try GoalState.read(codexHome: codexHome, threadId: threadId)
        if resumeGoal, let original, original.action == .refuse {
            throw desktopError("Goal status=\(original.status); only paused/usage_limited Goals can be resumed. Nothing sent.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first,
              let url = URL(string: "codex://threads/\(threadId)") else { throw desktopError("Codex is not running") }
        guard NSWorkspace.shared.open(url) else { throw desktopError("Cannot open target chat") }
        app.activate(options: [.activateIgnoringOtherApps])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var target: AXUIElement?
        for _ in 0..<20 {
            if let window = focusedWindow(root), identifies(window, title: title) { target = window; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let window = target else {
            let title = focusedWindow(root).map { string($0, kAXTitleAttribute) } ?? "<none>"
            log("Target verification failed: focusedWindow=\(title). Nothing clicked or typed.")
            throw desktopError("Cannot verify target chat by window title or selected sidebar item")
        }
        try verifyFront(app, root: root, window: window, title: title)
        if resumeGoal, let original, original.action == .resume {
            guard try GoalState.read(codexHome: codexHome, threadId: threadId) == original else {
                throw desktopError("Goal changed before click; stopped")
            }
            let candidates = elements(window).filter { element in
                string(element, kAXRoleAttribute) == kAXButtonRole && enabled(element) &&
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains {
                    Self.resumeLabels.contains(Self.normalized(string(element, $0)))
                }
            }
            log("Goal resume preflight: thread=\(threadId), goal=\(original.id), status=\(original.status), matchingButtons=\(candidates.count)")
            guard candidates.count == 1, let button = candidates.first else {
                throw desktopError("Expected one enabled Goal resume button; found \(candidates.count). Nothing clicked or typed.")
            }
            try verifyFront(app, root: root, window: window, title: title)
            try click(button, within: window, maxDimension: 200)
            log("Goal resume button clicked once: thread=\(threadId), goal=\(original.id)")
            var active = false
            for _ in 0..<30 {
                let current = try GoalState.read(codexHome: codexHome, threadId: threadId)
                guard current?.id == original.id else { throw desktopError("Goal was replaced or removed after click; Continue withheld") }
                if current?.status == "active" { active = true; break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard active else { throw desktopError("Goal activation unconfirmed after 15s; Continue withheld. No automatic retry.") }
            log("Goal active confirmed: thread=\(threadId), goal=\(original.id)")
        } else {
            log("Goal resume click skipped: thread=\(threadId), status=\(original?.status ?? "no-goal"), enabled=\(resumeGoal)")
        }
        try verifyFront(app, root: root, window: window, title: title)
        if resumeGoal, let original {
            let current = try GoalState.read(codexHome: codexHome, threadId: threadId)
            guard current?.id == original.id, current?.status == "active" else { throw desktopError("Goal is no longer active; Continue withheld") }
        }
        // Only one visible multiline editor is accepted; never guess composer coordinates.
        let editors = elements(window).filter { string($0, kAXRoleAttribute) == kAXTextAreaRole && enabled($0) && rect($0) != nil }
        log("Composer preflight: thread=\(threadId), textAreas=\(editors.count)")
        guard editors.count == 1, let editor = editors.first,
              let value = attribute(editor, kAXValueAttribute) as? String else {
            throw desktopError("Cannot identify one readable composer; nothing typed or sent")
        }
        let shouldPaste = try Self.draftAction(value: value, command: command)
        try click(editor, within: window, maxDimension: 10000)
        try await Task.sleep(nanoseconds: 200_000_000)
        try verifyEditor(root, editor: editor)
        if shouldPaste {
            let clipboard = NSPasteboard.general
            let saved = clipboard.pasteboardItems?.map { item in
                item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    item.data(forType: type).map { (type, $0) }
                }
            } ?? []
            defer {
                clipboard.clearContents()
                let items = saved.map { contents -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in contents { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { clipboard.writeObjects(items) }
            }
            clipboard.clearContents()
            clipboard.setString(command, forType: .string)
            try key(9, flags: .maskCommand)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let actual = attribute(editor, kAXValueAttribute) as? String,
              Self.normalized(actual) == Self.normalized(command) else {
            throw desktopError("Composer text does not match command; Enter withheld")
        }
        try verifyFront(app, root: root, window: window, title: title)
        try verifyEditor(root, editor: editor)
        try key(36, flags: [])
        log("Enter sent once: thread=\(threadId), reusedDraft=\(!shouldPaste)")
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private func enabled(_ element: AXUIElement) -> Bool { (attribute(element, kAXEnabledAttribute) as? Bool) == true }
    private func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func elements(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], offset = 0
        while offset < queue.count && queue.count < 6000 {
            let node = queue[offset]; offset += 1
            let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            queue.append(contentsOf: children.prefix(6000 - queue.count))
        }
        return queue
    }
    private func identifies(_ window: AXUIElement, title: String) -> Bool {
        if Self.normalized(string(window, kAXTitleAttribute)) == title { return true }
        return elements(window).contains { item in
            guard (attribute(item, kAXSelectedAttribute) as? Bool) == true else { return false }
            return elements(item).contains { child in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
                    Self.normalized(string(child, $0)) == title
                }
            }
        }
    }
    private func verifyFront(_ app: NSRunningApplication, root: AXUIElement, window: AXUIElement, title: String) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current = focusedWindow(root), CFEqual(current, window), identifies(current, title: title) else {
            throw desktopError("Target chat or focus changed; stopped")
        }
    }
    private func verifyEditor(_ root: AXUIElement, editor: AXUIElement) throws {
        guard let focused = attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw desktopError("Composer focus cannot be verified")
        }
        var node = unsafeBitCast(focused, to: AXUIElement.self)
        for _ in 0..<6 {
            if CFEqual(node, editor) { return }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
        }
        throw desktopError("Composer is not focused; nothing sent")
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    private func click(_ element: AXUIElement, within window: AXUIElement, maxDimension: CGFloat) throws {
        guard let r = rect(element), let w = rect(window),
              r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
              r.width >= 4, r.height >= 4, r.width <= maxDimension, r.height <= maxDimension,
              w.contains(r) else { throw desktopError("UI element bounds unavailable or unsafe; nothing clicked") }
        let point = CGPoint(x: r.midX, y: r.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw desktopError("Cannot create mouse input")
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw desktopError("Cannot create keyboard input") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
