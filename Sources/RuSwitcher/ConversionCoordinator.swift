import CoreGraphics
import RuSwitcherCore

enum ConversionExecutionResult: Equatable {
    case committed
    case alreadyCommitted
    case failed
}

@MainActor
final class ConversionCoordinator {
    private unowned let eventReplacer: TextConverter
    private var executionGate = ConversionExecutionGate()

    init(eventReplacer: TextConverter) {
        self.eventReplacer = eventReplacer
    }

    func execute(
        _ transaction: ConversionTransaction,
        keyCount: Int,
        proxy: CGEventTapProxy
    ) -> ConversionExecutionResult {
        let identity = transaction.executionIdentity
        if executionGate.isDuplicate(transaction) {
            rslog("transaction: duplicate suppressed sequence=\(identity.sequence)")
            return .alreadyCommitted
        }

        // AXSelectedText is deliberately not used here. It is a two-step API
        // (select, then replace), and several WebKit/Electron controls can accept
        // the first step while deferring or rejecting the second. That leaves a
        // visible selection and makes an event fallback destructive.
        guard eventReplacer.execute(transaction, keyCount: keyCount, proxy: proxy) else {
            return .failed
        }
        executionGate.recordCommitted(transaction)
        rslog("transaction: committed strategy=event keys=\(keyCount)")
        return .committed
    }
}
