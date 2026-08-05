import Foundation

@main
struct UsageAlertGateTests {
    static func main() {
        assert(
            UsageAlertGate.evaluate(remaining: nil, isLatched: false)
                == UsageAlertGateDecision(shouldAlert: false, isLatched: false)
        )
        assert(
            UsageAlertGate.evaluate(remaining: 11, isLatched: false)
                == UsageAlertGateDecision(shouldAlert: false, isLatched: false)
        )
        assert(
            UsageAlertGate.evaluate(remaining: 10, isLatched: false)
                == UsageAlertGateDecision(shouldAlert: true, isLatched: true)
        )
        assert(
            UsageAlertGate.evaluate(remaining: 9, isLatched: true)
                == UsageAlertGateDecision(shouldAlert: false, isLatched: true)
        )
        assert(
            UsageAlertGate.evaluate(remaining: 0, isLatched: true)
                == UsageAlertGateDecision(shouldAlert: false, isLatched: true)
        )
        assert(
            UsageAlertGate.evaluate(remaining: 100, isLatched: true)
                == UsageAlertGateDecision(shouldAlert: false, isLatched: false)
        )
        assert(
            UsageAlertGate.evaluate(remaining: 10, isLatched: false)
                == UsageAlertGateDecision(shouldAlert: true, isLatched: true)
        )
        print("UsageAlertGate tests passed")
    }
}
