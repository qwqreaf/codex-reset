import Foundation

enum ResumeStep: Equatable {
    case succeeded
    case skipped(String)
    case failed(String)

    var succeeded: Bool { if case .succeeded = self { return true }; return false }
    var description: String {
        switch self {
        case .succeeded: return "confirmed"
        case .skipped(let reason): return "skipped (\(reason))"
        case .failed(let reason): return "failed (\(reason))"
        }
    }
}

struct ResumeAttempts {
    let goal: ResumeStep
    let message: ResumeStep
    var anySucceeded: Bool { goal.succeeded || message.succeeded }
    var summary: String { "Goal: \(goal.description) | Continue: \(message.description)" }

    /// A Goal failure never gates the independent message attempt.
    @MainActor static func run(goal: () async throws -> ResumeStep,
                              message: () async throws -> Void) async -> ResumeAttempts {
        let goalResult: ResumeStep
        do { goalResult = try await goal() }
        catch { goalResult = .failed(error.localizedDescription) }
        let messageResult: ResumeStep
        do { try Task.checkCancellation(); try await message(); messageResult = .succeeded }
        catch { messageResult = .failed(error.localizedDescription) }
        return ResumeAttempts(goal: goalResult, message: messageResult)
    }
}
