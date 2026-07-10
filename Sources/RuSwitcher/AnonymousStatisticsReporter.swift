import Foundation
import RuSwitcherCore

final class AnonymousStatisticsReporter: @unchecked Sendable {
    static let shared = AnonymousStatisticsReporter()

    private let queue = DispatchQueue(label: "com.ruswitcher.anonymous-statistics", qos: .utility)
    private let fileURL: URL

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("RuSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("anonymous-usage-v1.json")
    }

    func record(
        _ event: AnonymousUsageEvent,
        languagePair: String? = nil,
        reason: String? = nil,
        tokenLength: Int? = nil
    ) {
        guard SettingsManager.shared.shareAnonymousStatistics else { return }
        queue.async {
            var statistics = self.load()
            statistics.record(event, languagePair: languagePair, reason: reason, tokenLength: tokenLength)
            self.save(statistics)
        }
    }

    func uploadIfDue() {
        guard SettingsManager.shared.shareAnonymousStatistics,
              let endpointString = Bundle.main.object(forInfoDictionaryKey: "RSStatisticsEndpoint") as? String,
              let endpoint = URL(string: endpointString), !endpointString.isEmpty else { return }
        queue.async {
            let statistics = self.load()
            guard statistics.eventCount > 0,
                  Date().timeIntervalSince(statistics.startedAt) >= 24 * 60 * 60,
                  let body = try? JSONEncoder().encode(UploadEnvelope(statistics: statistics)) else { return }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            URLSession.shared.dataTask(with: request) { _, response, _ in
                guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true else { return }
                self.queue.async {
                    var current = self.load()
                    current.removeCounters(in: statistics)
                    self.save(current)
                }
            }.resume()
        }
    }

    func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    private func load() -> AnonymousUsageStatistics {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(AnonymousUsageStatistics.self, from: data) else {
            return AnonymousUsageStatistics()
        }
        return value
    }

    private func save(_ statistics: AnonymousUsageStatistics) {
        guard let data = try? JSONEncoder().encode(statistics) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct UploadEnvelope: Encodable {
        let appVersion: String
        let modelVersion: String
        let osMajorVersion: Int
        let interfaceLanguage: String
        let statistics: AnonymousUsageStatistics

        init(statistics: AnonymousUsageStatistics) {
            appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            modelVersion = ContextualLayoutModel.bundled?.manifest.modelVersion
                ?? LanguageModelStore.bundled?.metadata.modelVersion
                ?? "fallback"
            osMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            interfaceLanguage = String((Locale.preferredLanguages.first ?? "unknown").prefix(2))
            self.statistics = statistics
        }
    }
}
