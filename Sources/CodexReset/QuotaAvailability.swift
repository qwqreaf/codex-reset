import Foundation

/// One policy for both detecting recovery and authorizing the recovery batch.
enum QuotaAvailability {
    case available, reset, limited, unknown

    var canContinue: Bool { self == .available || self == .reset }

    static func evaluate(_ limits: RateLimitSnapshot, now: Date) -> Self {
        if limits.spendControlReached == true { return .limited }
        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        let exhausted = windows.filter { $0.usedPercent >= 100 }
        // A full weekly window must still block a five-hour reset. Missing reset
        // times remain limited; missing usage information never means available.
        if exhausted.contains(where: { $0.resetsAt.map { Double($0) > now.timeIntervalSince1970 } ?? true }) {
            return .limited
        }
        let reason = limits.rateLimitReachedType
        let reached = reason != nil && reason != "none"
        // Only an ordinary quota flag can be explained by an expired window.
        // Workspace/billing/spend restrictions need an explicit fresh clearance.
        if reached && (reason != "rate_limit_reached" || exhausted.isEmpty) { return .limited }
        guard !windows.isEmpty else { return .unknown }
        return exhausted.isEmpty ? .available : .reset
    }
}
