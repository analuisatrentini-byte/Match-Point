import Foundation

// Lightweight debounce store for automatic syncs. Each `Scope` records the
// last successful sync in UserDefaults; views call `shouldSync(_:)` before
// kicking off an automatic refresh so we don't hammer the API on every
// navigation. Manual "Sync" buttons bypass this and force a refresh.
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
            return 10   // antes 15s — partidas live são o caso mais crítico
        case .matches:
            return 30   // antes 60s
        case .fixtures:
            return 60   // antes 120s
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
        let key = prefix + scope.rawValue
        let last = defaults.double(forKey: key)
        guard last > 0 else { return true }
        let elapsed = Date().timeIntervalSince1970 - last
        return elapsed >= minInterval(for: scope)
    }

    @MainActor
    static func markSynced(_ scope: Scope) {
        let key = prefix + scope.rawValue
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    @MainActor
    static func reset(_ scope: Scope) {
        defaults.removeObject(forKey: prefix + scope.rawValue)
    }

    /// Timestamp do último `markSynced(scope)` bem-sucedido. Usado pelo
    /// indicador "Atualizado há X min" no header das listas — single source of
    /// truth, em vez de cada view manter seu próprio @State de last-sync.
    @MainActor
    static func lastSync(_ scope: Scope) -> Date? {
        let key = prefix + scope.rawValue
        let epoch = defaults.double(forKey: key)
        guard epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Segundos desde o último sync da `scope`. `nil` se ainda nunca houve.
    @MainActor
    static func timeSinceLastSync(_ scope: Scope, now: Date = .now) -> TimeInterval? {
        guard let last = lastSync(scope) else { return nil }
        return now.timeIntervalSince(last)
    }
}
