import Foundation

// Lightweight debounce store for automatic syncs. Each `Scope` records the
// last successful sync and recent attempts in UserDefaults; views call
// `shouldSync(_:)` before kicking off an automatic refresh so we don't hammer
// the API on every navigation. Manual "Sync" buttons bypass this and force a
// refresh.
enum AutoSyncTracker {
    enum Scope: String {
        case tournaments
        case playersAndRankings
        case matches
        case liveMatches
        case fixtures
    }

    // Per-scope minimum interval between automatic syncs (seconds).
    //
    // Intervalos foram REDUZIDOS porque o sync agora é 100% automático — o
    // usuário não tem mais botão manual pra puxar dados. Pra compensar a
    // ausência do "Sincronizar dados agora" no Settings, o auto-sync precisa
    // ser agressivo o bastante pra manter o feed fresco sem intervenção.
    private static func minInterval(for scope: Scope) -> TimeInterval {
        switch scope {
        case .liveMatches:
            return 30   // live é leve, mas ainda evita reescrever SwiftData sem parar
        case .matches:
            return 300  // sync completo é pesado; deixar para primeira carga/refresh
        case .fixtures:
            return 300
        case .tournaments:
            return 180  // antes 300s
        case .playersAndRankings:
            return 180  // antes 300s
        }
    }

    private static let prefix = "match_point.auto_sync."
    private static let defaults = UserDefaults.standard

    @MainActor
    static func shouldSync(_ scope: Scope) -> Bool {
        let now = Date().timeIntervalSince1970
        let lastSuccess = defaults.double(forKey: successKey(for: scope))
        let lastAttempt = defaults.double(forKey: attemptKey(for: scope))
        let last = max(lastSuccess, lastAttempt)
        guard last > 0 else { return true }
        let elapsed = now - last
        return elapsed >= minInterval(for: scope)
    }

    @MainActor
    static func markSynced(_ scope: Scope) {
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: successKey(for: scope))
        defaults.set(now, forKey: attemptKey(for: scope))
    }

    @MainActor
    static func markAttempted(_ scope: Scope) {
        defaults.set(Date().timeIntervalSince1970, forKey: attemptKey(for: scope))
    }

    @MainActor
    static func reset(_ scope: Scope) {
        defaults.removeObject(forKey: successKey(for: scope))
        defaults.removeObject(forKey: attemptKey(for: scope))
    }

    /// Timestamp do último `markSynced(scope)` bem-sucedido. Usado pelo
    /// indicador "Atualizado há X min" no header das listas — single source of
    /// truth, em vez de cada view manter seu próprio @State de last-sync.
    @MainActor
    static func lastSync(_ scope: Scope) -> Date? {
        let epoch = defaults.double(forKey: successKey(for: scope))
        guard epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Segundos desde o último sync da `scope`. `nil` se ainda nunca houve.
    @MainActor
    static func timeSinceLastSync(_ scope: Scope, now: Date = .now) -> TimeInterval? {
        guard let last = lastSync(scope) else { return nil }
        return now.timeIntervalSince(last)
    }

    private static func successKey(for scope: Scope) -> String {
        prefix + scope.rawValue
    }

    private static func attemptKey(for scope: Scope) -> String {
        prefix + scope.rawValue + ".attempt"
    }
}
