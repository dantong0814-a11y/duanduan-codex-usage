import Foundation

struct UsageAlertGateDecision: Equatable {
    let shouldAlert: Bool
    let isLatched: Bool
}

enum UsageAlertGate {
    static let latchKey = "usageLowAlertLatched"

    static func evaluate(remaining: Int?, isLatched: Bool) -> UsageAlertGateDecision {
        guard let remaining else {
            return UsageAlertGateDecision(shouldAlert: false, isLatched: isLatched)
        }

        if remaining > 10 {
            return UsageAlertGateDecision(shouldAlert: false, isLatched: false)
        }

        return UsageAlertGateDecision(shouldAlert: !isLatched, isLatched: true)
    }
}
