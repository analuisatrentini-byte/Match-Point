import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "ALTB.Match-Point"
    static let failureMetricsKey = "match-point.failure-metrics"
    /// Cap on persisted failure metrics. Without a cap a long-running install with
    /// a flaky network can accumulate hundreds of stale entries, bloating
    /// UserDefaults and slowing down every app launch that reads it.
    static let failureMetricsMaxEntries = 50
    /// Drop metrics not seen in this window so the diagnostics view always reflects
    /// "what's broken right now" instead of historical noise.
    static let failureMetricsRetention: TimeInterval = 60 * 60 * 24 * 30 // 30 days
    /// Cap for the persisted error description. localizedDescription can be
    /// arbitrarily long (URLSession errors splat the failing URL plus headers);
    /// truncating keeps UserDefaults small and bounds any single PII leak.
    static let failureMetricsMessageMaxLength = 200

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let live = Logger(subsystem: subsystem, category: "live")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let product = Logger(subsystem: subsystem, category: "product")

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func recordFailure(category: String, operation: String, error: Error) {
        let key = "\(category).\(operation)"
        var metrics = loadFailureMetrics()
        var metric = metrics[key] ?? FailureMetric(category: category, operation: operation)
        metric.count += 1
        metric.lastMessage = sanitizedFailureMessage(message(for: error))
        metric.lastOccurredAt = .now
        metrics[key] = metric

        let pruned = pruneFailureMetrics(metrics)

        do {
            let data = try JSONEncoder().encode(pruned)
            UserDefaults.standard.set(data, forKey: failureMetricsKey)
        } catch {
            persistence.error("Failed to persist failure metric for \(key, privacy: .public): \(message(for: error), privacy: .private)")
        }
    }

    /// Exposed so tests can verify the pruning policy without going through
    /// UserDefaults.
    static func pruneFailureMetrics(_ metrics: [String: FailureMetric]) -> [String: FailureMetric] {
        let cutoff = Date().addingTimeInterval(-failureMetricsRetention)
        let fresh = metrics.filter { $0.value.lastOccurredAt >= cutoff }
        guard fresh.count > failureMetricsMaxEntries else { return fresh }

        let sortedRecent = fresh
            .sorted { $0.value.lastOccurredAt > $1.value.lastOccurredAt }
            .prefix(failureMetricsMaxEntries)
        return Dictionary(uniqueKeysWithValues: sortedRecent.map { ($0.key, $0.value) })
    }

    static func failureMetrics() -> [FailureMetric] {
        loadFailureMetrics()
            .values
            .sorted { $0.lastOccurredAt > $1.lastOccurredAt }
    }

    /// Strips identifiers that often leak into NSError descriptions (URLs,
    /// filesystem paths, emails, UUIDs) and truncates to a bounded length.
    /// Exposed so tests can verify the redaction policy.
    static func sanitizedFailureMessage(_ raw: String) -> String {
        var result = raw as NSString
        for (regex, replacement) in compiledRedactionPatterns {
            result = regex.stringByReplacingMatches(
                in: result as String,
                range: NSRange(result.length == 0 ? 0..<0 : 0..<result.length),
                withTemplate: replacement
            ) as NSString
        }
        let sanitized = result as String

        let collapsed = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > failureMetricsMessageMaxLength else { return collapsed }
        let head = collapsed.prefix(failureMetricsMessageMaxLength)
        return "\(head)…"
    }

    /// Pre-compiled regex patterns for log sanitization — compiled once at
    /// class-load time instead of re-compiling on every log write.
    /// Order matters: URL/token patterns run before the bare-path pattern to
    /// avoid overmatch; JWT before the generic hex-blob secret pattern.
    private static let compiledRedactionPatterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            (#"(?i)Bearer\s+[A-Za-z0-9._\-]+"#, "<token>"),
            // Redact API key in query strings: ?APIkey=abc123 or &APIkey=abc123
            (#"(?i)([?&]APIkey=)[A-Za-z0-9._\-]+"#, "$1<key>"),
            (#"eyJ[A-Za-z0-9_\-]+=*\.[A-Za-z0-9_\-]+=*\.[A-Za-z0-9_\-]+=*"#, "<jwt>"),
            (#"\b[A-Fa-f0-9]{40,}\b"#, "<secret>"),
            (#"(https?|wss?|ftp)://\S+"#, "<url>"),
            (#"file:///\S+"#, "<path>"),
            (#"/(Users|var|private|tmp|System|Applications|Library)/\S+"#, "<path>"),
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, "<uuid>"),
            (#"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, "<ip>"),
            (#"\+?[0-9][0-9\s\-().]{8,}[0-9]"#, "<phone>")
        ]
        return raw.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    private static func loadFailureMetrics() -> [String: FailureMetric] {
        guard let data = UserDefaults.standard.data(forKey: failureMetricsKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: FailureMetric].self, from: data)
        } catch {
            persistence.error("Failed to decode failure metrics: \(message(for: error), privacy: .private)")
            return [:]
        }
    }
}

nonisolated struct FailureMetric: Codable, Identifiable, Equatable {
    let category: String
    let operation: String
    var count: Int
    var lastMessage: String
    var lastOccurredAt: Date

    var id: String {
        "\(category).\(operation)"
    }

    init(
        category: String,
        operation: String,
        count: Int = 0,
        lastMessage: String = "",
        lastOccurredAt: Date = .distantPast
    ) {
        self.category = category
        self.operation = operation
        self.count = count
        self.lastMessage = lastMessage
        self.lastOccurredAt = lastOccurredAt
    }
}
