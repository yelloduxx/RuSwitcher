import ApplicationServices
import Foundation
import RuSwitcherAppSupport

private struct AXResolverProbeResult: Codable {
    let warmResolved: Bool
    let warmSource: String?
    let warmFailure: String?
    let warmLatencyMilliseconds: Double
    let hotResolved: Bool
    let hotSource: String?
    let hotFailure: String?
    let hotLatencyMilliseconds: Double
}

enum AXResolverProbe {
    static func run(processIDString: String) -> Never {
        guard let processID = Int32(processIDString), processID > 0 else {
            FileHandle.standardError.write(Data("invalid process id\n".utf8))
            exit(64)
        }
        let resolver = NativeFocusedEditableResolver()
        let warmStarted = DispatchTime.now().uptimeNanoseconds
        let warm = resolver.resolve(
            processID: processID,
            timeoutMilliseconds: 120,
            allowTreeSearch: true
        )
        let warmLatency = milliseconds(since: warmStarted)

        let hotStarted = DispatchTime.now().uptimeNanoseconds
        let hot = resolver.resolve(
            processID: processID,
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )
        let hotLatency = milliseconds(since: hotStarted)

        let result = AXResolverProbeResult(
            warmResolved: resolvedSource(warm) != nil,
            warmSource: resolvedSource(warm),
            warmFailure: failureName(warm),
            warmLatencyMilliseconds: warmLatency,
            hotResolved: resolvedSource(hot) != nil,
            hotSource: resolvedSource(hot),
            hotFailure: failureName(hot),
            hotLatencyMilliseconds: hotLatency
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(result.warmResolved && result.hotResolved ? 0 : 1)
    }

    private static func milliseconds(since started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    private static func resolvedSource(
        _ lookup: FocusedEditableLookup<AXUIElement>
    ) -> String? {
        guard case let .resolved(resolution) = lookup else { return nil }
        switch resolution.source {
        case .cached: return "cached"
        case .canonical: return "canonical"
        case .nested: return "nested"
        }
    }

    private static func failureName(
        _ lookup: FocusedEditableLookup<AXUIElement>
    ) -> String? {
        guard case let .unavailable(failure) = lookup else { return nil }
        switch failure {
        case .noFocusedElement: return "no-focused"
        case .noEditableElement: return "no-editable"
        case .ambiguousFocusedElements: return "ambiguous-focused"
        case .timedOut: return "timeout"
        case .identifierMismatch: return "identifier-mismatch"
        }
    }
}
