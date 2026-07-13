import Foundation

public struct PrivacySafeLogger: Sendable {
    public typealias Sink = @Sendable (String) -> Void

    private let sink: Sink

    public init(sink: @escaping Sink) {
        self.sink = sink
    }

    public func log(_ event: StaticString) {
        sink(String(describing: event))
    }
}
