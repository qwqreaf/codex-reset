import Foundation

struct StoredLogEntry: Codable {
    let timestamp: Date
    let zh: String
    let en: String
}

/// Local JSON Lines archive. All calls are made on the app's main actor.
final class ActivityLogStore {
    let directory: URL
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CodexReset", isDirectory: true)) {
        self.directory = directory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ entry: StoredLogEntry, now: Date = Date()) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try prune(now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let url = directory.appendingPathComponent("activity-\(formatter.string(from: now)).jsonl")
        var data = try encoder.encode(entry)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    func recent(limit: Int, now: Date = Date()) throws -> [StoredLogEntry] {
        try prune(now: now)
        var entries: [StoredLogEntry] = []
        for file in try files().reversed() {
            let data = try Data(contentsOf: file)
            entries = data.split(separator: 0x0A).compactMap {
                try? decoder.decode(StoredLogEntry.self, from: Data($0))
            } + entries
            if entries.count >= limit { break }
        }
        return Array(entries.sorted { $0.timestamp < $1.timestamp }.suffix(max(0, limit)))
    }

    func prune(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-retention)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        for file in try files() {
            let name = file.deletingPathExtension().lastPathComponent
            guard let day = formatter.date(from: String(name.dropFirst("activity-".count))) else { continue }
            if day.addingTimeInterval(24 * 60 * 60) <= cutoff {
                try fileManager.removeItem(at: file)
            } else if day < cutoff {
                let data = try Data(contentsOf: file)
                let lines = data.split(separator: 0x0A)
                let kept = lines.filter { line in
                    // Keep an unreadable line rather than silently deleting diagnostic evidence.
                    guard let entry = try? decoder.decode(StoredLogEntry.self, from: Data(line)) else { return true }
                    return entry.timestamp >= cutoff
                }
                if kept.count != lines.count {
                    var output = Data()
                    for line in kept { output.append(contentsOf: line); output.append(0x0A) }
                    try output.write(to: file, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }
        }
    }

    private func files() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("activity-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
