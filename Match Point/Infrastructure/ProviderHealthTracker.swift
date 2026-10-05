import Combine
import Foundation
import SwiftUI

/// Centralised live-data reliability telemetry for the single API Tennis
/// provider used by Match Point.
///
/// Every REST call, WebSocket event, and fallback path records here so the
/// Diagnostics UI can show one authoritative view — success/failure counts,
/// last error, latency, and derived health state (`healthy`, `degraded`,
/// `failing`, `idle`) — instead of the ad-hoc "Idle / OK / error string"
/// scattered across screens.
///
/// The tracker is `@MainActor` because the SwiftUI Diagnostics view observes
/// it directly. Non-`@MainActor` call sites (async provider code, WebSocket
/// callbacks, background tasks) use the `nonisolated` helpers, which hop to
/// MainActor via a fire-and-forget `Task`. Recording is best-effort — if the
/// tracker is contended nothing on the hot path blocks or throws.
@MainActor
final class ProviderHealthTracker: ObservableObject {
    static let shared = ProviderHealthTracker()

    /// Distinct data planes we track separately. WebSocket lives here too so
    /// diagnostics can compare "REST live" health against "WebSocket live"
    /// health side-by-side.
    enum Scope: String, CaseIterable, Identifiable, Hashable {
        case tournaments
        case rankings
        case players
        case liveMatches
        case fixtures
        case headToHead
        case playerProfile
        case odds
        case liveOdds
        case webSocket

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tournaments: return "Torneios"
            case .rankings: return "Rankings"
            case .players: return "Players"
            case .liveMatches: return "Live matches"
            case .fixtures: return "Fixtures"
            case .headToHead: return "Head-to-head"
            case .playerProfile: return "Player profile"
            case .odds: return "Odds"
            case .liveOdds: return "Live odds"
            case .webSocket: return "WebSocket"
            }
        }

        /// Whether this scope maps to a REST call. Used by the diagnostics
        /// dashboard to segment "REST providers" from "streaming".
        var isRest: Bool { self != .webSocket }
    }

    /// Derived health state consumed by the diagnostics dashboard and any
    /// on-screen "provider healthy/degraded/failing" chips.
    enum Health: Equatable {
        case idle
        case healthy
        case degraded(reason: String)
        case failing(reason: String)

        var label: String {
            switch self {
            case .idle: return "Sem tráfego"
            case .healthy: return "Saudável"
            case .degraded: return "Degradado"
            case .failing: return "Falhando"
            }
        }

        var systemImage: String {
            switch self {
            case .idle: return "circle.dotted"
            case .healthy: return "checkmark.seal.fill"
            case .degraded: return "exclamationmark.triangle.fill"
            case .failing: return "xmark.octagon.fill"
            }
        }
    }

    struct ScopeSnapshot: Equatable, Identifiable {
        let scope: Scope
        let successCount: Int
        let failureCount: Int
        let consecutiveFailures: Int
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
        let lastErrorMessage: String?
        let lastLatencyMillis: Int?
        let averageLatencyMillis: Int?

        var id: String { scope.id }
        var totalCalls: Int { successCount + failureCount }

        var successRate: Double {
            guard totalCalls > 0 else { return 0 }
            return Double(successCount) / Double(totalCalls)
        }

        var health: Health {
            // No traffic → idle. This is deliberately not "healthy" so the
            // diagnostics view can distinguish "provider hasn't been asked
            // anything yet" from "provider answered successfully".
            if totalCalls == 0 { return .idle }

            if consecutiveFailures >= 3 {
                return .failing(reason: lastErrorMessage ?? "3+ falhas consecutivas")
            }

            // Any recent failure without a newer success is a hard failing.
            if let lastFailureAt {
                if lastSuccessAt == nil || lastSuccessAt! < lastFailureAt {
                    // Failing = last observation was a failure.
                    if consecutiveFailures >= 1 {
                        return .failing(reason: lastErrorMessage ?? "Última chamada falhou")
                    }
                }
            }

            // Any prior failure that hasn't been fully compensated → degraded.
            if failureCount > 0 && successRate < 0.9 {
                return .degraded(reason: "Sucesso em \(Int((successRate * 100).rounded()))% das chamadas")
            }

            if let average = averageLatencyMillis, average > 2_500 {
                return .degraded(reason: "Latência média \(average)ms acima de 2.5s")
            }

            return .healthy
        }
    }

    struct FallbackEvent: Identifiable, Equatable {
        let id = UUID()
        let scope: Scope
        let reason: String
        let occurredAt: Date

        static func == (lhs: FallbackEvent, rhs: FallbackEvent) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct WebSocketMonitor: Equatable {
        var framesReceived: Int = 0
        var stallEvents: Int = 0
        var reconnectAttempts: Int = 0
        var lastFrameAt: Date?
        var lastStallAt: Date?
        var lastCloseReason: String?
        var connectedSince: Date?
        var lastState: String = "disconnected"

        var isStreaming: Bool { lastState == "connected" }
    }

    // MARK: - Published state

    @Published private(set) var snapshots: [Scope: ScopeSnapshot]
    @Published private(set) var fallbackLog: [FallbackEvent]
    @Published private(set) var webSocket: WebSocketMonitor

    // MARK: - Config

    private let maxLatencySamples = 10
    private let maxFallbackEntries = 20
    private var latencySamplesByScope: [Scope: [Int]] = [:]

    // MARK: - Init / reset

    init(initialSnapshots: [Scope: ScopeSnapshot] = [:]) {
        var seeded = initialSnapshots
        for scope in Scope.allCases where seeded[scope] == nil {
            seeded[scope] = ScopeSnapshot(
                scope: scope,
                successCount: 0,
                failureCount: 0,
                consecutiveFailures: 0,
                lastSuccessAt: nil,
                lastFailureAt: nil,
                lastErrorMessage: nil,
                lastLatencyMillis: nil,
                averageLatencyMillis: nil
            )
        }
        self.snapshots = seeded
        self.fallbackLog = []
        self.webSocket = WebSocketMonitor()
    }

    func reset() {
        snapshots = Scope.allCases.reduce(into: [Scope: ScopeSnapshot]()) { partial, scope in
            partial[scope] = ScopeSnapshot(
                scope: scope,
                successCount: 0,
                failureCount: 0,
                consecutiveFailures: 0,
                lastSuccessAt: nil,
                lastFailureAt: nil,
                lastErrorMessage: nil,
                lastLatencyMillis: nil,
                averageLatencyMillis: nil
            )
        }
        latencySamplesByScope = [:]
        fallbackLog = []
        webSocket = WebSocketMonitor()
    }

    // MARK: - Recording (MainActor)

    /// Records a successful call. `latencyMillis` measured by the caller —
    /// the tracker doesn't know request start times.
    func recordSuccess(scope: Scope, latencyMillis: Int, at date: Date = .now) {
        let existing = snapshots[scope] ?? Self.empty(scope: scope)
        appendLatency(latencyMillis, for: scope)
        snapshots[scope] = ScopeSnapshot(
            scope: scope,
            successCount: existing.successCount + 1,
            failureCount: existing.failureCount,
            consecutiveFailures: 0,
            lastSuccessAt: date,
            lastFailureAt: existing.lastFailureAt,
            lastErrorMessage: existing.lastErrorMessage,
            lastLatencyMillis: latencyMillis,
            averageLatencyMillis: rollingAverageLatency(for: scope)
        )
    }

    func recordFailure(scope: Scope, error: Error, latencyMillis: Int? = nil, at date: Date = .now) {
        let existing = snapshots[scope] ?? Self.empty(scope: scope)
        if let latencyMillis {
            appendLatency(latencyMillis, for: scope)
        }
        snapshots[scope] = ScopeSnapshot(
            scope: scope,
            successCount: existing.successCount,
            failureCount: existing.failureCount + 1,
            consecutiveFailures: existing.consecutiveFailures + 1,
            lastSuccessAt: existing.lastSuccessAt,
            lastFailureAt: date,
            lastErrorMessage: Self.shortMessage(for: error),
            lastLatencyMillis: latencyMillis ?? existing.lastLatencyMillis,
            averageLatencyMillis: rollingAverageLatency(for: scope)
        )
    }

    /// Records a fallback path being exercised. `scope` is the target of the
    /// fallback (e.g. `.tournaments` when we're deriving tournaments from live
    /// matches because the tournaments endpoint failed).
    func recordFallback(scope: Scope, reason: String, at date: Date = .now) {
        let event = FallbackEvent(scope: scope, reason: reason, occurredAt: date)
        var updated = fallbackLog
        updated.insert(event, at: 0)
        if updated.count > maxFallbackEntries {
            updated = Array(updated.prefix(maxFallbackEntries))
        }
        fallbackLog = updated
    }

    // MARK: - WebSocket monitoring

    func recordWebSocketFrame(at date: Date = .now) {
        var monitor = webSocket
        monitor.framesReceived += 1
        monitor.lastFrameAt = date
        if monitor.lastState != "connected" {
            monitor.lastState = "connected"
            monitor.connectedSince = date
        }
        webSocket = monitor

        // Successful frames also flip the `webSocket` scope back to healthy.
        recordSuccess(scope: .webSocket, latencyMillis: 0, at: date)
    }

    func recordWebSocketStall(reason: String, at date: Date = .now) {
        var monitor = webSocket
        monitor.stallEvents += 1
        monitor.lastStallAt = date
        monitor.lastCloseReason = reason
        webSocket = monitor
        recordFallback(scope: .webSocket, reason: "Stall: \(reason)", at: date)
    }

    func recordWebSocketReconnect(at date: Date = .now) {
        var monitor = webSocket
        monitor.reconnectAttempts += 1
        webSocket = monitor
    }

    /// Semantic connection-state changes coming from `LiveMatchWebSocketService`.
    /// Recorded as-is so the diagnostics view can echo them.
    func recordWebSocketState(_ label: String, reason: String? = nil, at date: Date = .now) {
        var monitor = webSocket
        monitor.lastState = label
        if let reason { monitor.lastCloseReason = reason }
        if label != "connected" {
            monitor.connectedSince = nil
        }
        webSocket = monitor
    }

    /// Records that the WebSocket triggered a REST fallback poll. Emits
    /// a fallback event so diagnostics show the exact reason chain.
    func recordWebSocketFallback(reason: String, at date: Date = .now) {
        recordFallback(scope: .webSocket, reason: "REST fallback: \(reason)", at: date)
    }

    // MARK: - Query helpers

    func snapshot(for scope: Scope) -> ScopeSnapshot {
        snapshots[scope] ?? Self.empty(scope: scope)
    }

    /// Overall provider health across REST scopes. WebSocket is not part of
    /// this rollup because it has a very different failure model — it is
    /// reported separately in the WebSocketMonitor block.
    var overallRestHealth: Health {
        let restSnapshots = Scope.allCases.filter(\.isRest).map { snapshot(for: $0) }
        let touched = restSnapshots.filter { $0.totalCalls > 0 }
        if touched.isEmpty { return .idle }
        if touched.contains(where: { if case .failing = $0.health { return true } else { return false } }) {
            return .failing(reason: "Um ou mais endpoints falhando")
        }
        if touched.contains(where: { if case .degraded = $0.health { return true } else { return false } }) {
            return .degraded(reason: "Um ou mais endpoints degradados")
        }
        return .healthy
    }

    // MARK: - Non-isolated helpers

    /// Fire-and-forget recording from an `async` context outside of MainActor.
    /// Providers (`APITennisProvider`) call these directly instead of
    /// hopping actors themselves.
    nonisolated static func reportSuccess(scope: Scope, latencyMillis: Int) {
        Task { @MainActor in
            shared.recordSuccess(scope: scope, latencyMillis: latencyMillis)
        }
    }

    nonisolated static func reportFailure(scope: Scope, error: Error, latencyMillis: Int? = nil) {
        // Capture a wire-safe message on the calling actor to avoid crossing
        // isolation with an arbitrary Error graph.
        let message = shortMessage(for: error)
        Task { @MainActor in
            shared.recordFailure(scope: scope, error: SimpleError(message: message), latencyMillis: latencyMillis)
        }
    }

    nonisolated static func reportFallback(scope: Scope, reason: String) {
        Task { @MainActor in
            shared.recordFallback(scope: scope, reason: reason)
        }
    }

    nonisolated static func reportWebSocketFrame() {
        Task { @MainActor in
            shared.recordWebSocketFrame()
        }
    }

    nonisolated static func reportWebSocketStall(reason: String) {
        Task { @MainActor in
            shared.recordWebSocketStall(reason: reason)
        }
    }

    nonisolated static func reportWebSocketReconnect() {
        Task { @MainActor in
            shared.recordWebSocketReconnect()
        }
    }

    nonisolated static func reportWebSocketState(_ label: String, reason: String? = nil) {
        Task { @MainActor in
            shared.recordWebSocketState(label, reason: reason)
        }
    }

    nonisolated static func reportWebSocketFallback(reason: String) {
        Task { @MainActor in
            shared.recordWebSocketFallback(reason: reason)
        }
    }

    // MARK: - Internals

    private func appendLatency(_ millis: Int, for scope: Scope) {
        var samples = latencySamplesByScope[scope] ?? []
        samples.append(max(0, millis))
        if samples.count > maxLatencySamples {
            samples.removeFirst(samples.count - maxLatencySamples)
        }
        latencySamplesByScope[scope] = samples
    }

    private func rollingAverageLatency(for scope: Scope) -> Int? {
        let samples = latencySamplesByScope[scope] ?? []
        guard !samples.isEmpty else { return nil }
        return Int((Double(samples.reduce(0, +)) / Double(samples.count)).rounded())
    }

    private static func empty(scope: Scope) -> ScopeSnapshot {
        ScopeSnapshot(
            scope: scope,
            successCount: 0,
            failureCount: 0,
            consecutiveFailures: 0,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            lastErrorMessage: nil,
            lastLatencyMillis: nil,
            averageLatencyMillis: nil
        )
    }

    nonisolated static func shortMessage(for error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Erro desconhecido" }
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }
}

/// Lightweight `Error` used when we've already captured the wire message on
/// the source actor — avoids sending an arbitrary Error across isolation.
private struct SimpleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
