import Foundation
import OSLog

protocol TennisAPIProviding {
    func tournaments() async throws -> [TournamentDTO]
    func rankings(tour: String?) async throws -> [RankingEntryDTO]
    func players(tour: String?) async throws -> [PlayerDTO]
    func liveMatches() async throws -> [MatchDTO]
    func eventTypes() async throws -> [EventTypeDTO]
    func fixtures(from startDate: Date, to endDate: Date, tournamentKey: String?) async throws -> [MatchDTO]
    func headToHead(firstPlayerKey: String, secondPlayerKey: String) async throws -> [H2HMatchDTO]
    func playerProfile(playerKey: String, tour: String?) async throws -> PlayerProfileDTO?
    func odds(matchKey: String) async throws -> [OddsDTO]
    func liveOdds(matchKey: String?) async throws -> [LiveOddsDTO]
}

struct TennisAPI {
    private let provider: APITennisProvider

    init(
        provider: TennisAPIConfiguration.Provider = TennisAPIConfiguration.selectedProvider,
        baseURL: URL? = nil,
        session: URLSession? = nil
    ) {
        // When the caller doesn't pin a baseURL (the default in production),
        // resolve it from `TennisAPIConfiguration` per request so a runtime
        // proxy switch propagates without recreating DataSyncService.
        if let baseURL {
            self.provider = APITennisProvider(
                baseURL: baseURL,
                usesBackendProxy: TennisAPIConfiguration.usesBackendProxy,
                hasBackendProxy: true,
                session: session ?? TennisAPIConfiguration.makeProviderURLSession(for: provider)
            )
        } else {
            self.provider = APITennisProvider(
                baseURLProvider: { TennisAPIConfiguration.restBaseURL },
                usesBackendProxy: TennisAPIConfiguration.usesBackendProxy,
                hasBackendProxy: TennisAPIConfiguration.hasBackendProxy,
                session: session ?? TennisAPIConfiguration.makeProviderURLSession(for: provider)
            )
        }
    }

    func tournaments() async throws -> [TournamentDTO] {
        try await provider.tournaments()
    }

    func rankings(tour: String? = nil) async throws -> [RankingEntryDTO] {
        try await provider.rankings(tour: tour)
    }

    func players(tour: String? = nil) async throws -> [PlayerDTO] {
        try await provider.players(tour: tour)
    }

    func liveMatches() async throws -> [MatchDTO] {
        try await provider.liveMatches()
    }

    func eventTypes() async throws -> [EventTypeDTO] {
        try await provider.eventTypes()
    }

    func fixtures(
        from startDate: Date = Date(),
        to endDate: Date = Date().addingTimeInterval(7 * 24 * 60 * 60),
        tournamentKey: String? = nil
    ) async throws -> [MatchDTO] {
        try await provider.fixtures(from: startDate, to: endDate, tournamentKey: tournamentKey)
    }

    func headToHead(firstPlayerKey: String, secondPlayerKey: String) async throws -> [H2HMatchDTO] {
        try await provider.headToHead(firstPlayerKey: firstPlayerKey, secondPlayerKey: secondPlayerKey)
    }

    func playerProfile(playerKey: String, tour: String? = nil) async throws -> PlayerProfileDTO? {
        try await provider.playerProfile(playerKey: playerKey, tour: tour)
    }

    func odds(matchKey: String) async throws -> [OddsDTO] {
        try await provider.odds(matchKey: matchKey)
    }

    func liveOdds(matchKey: String? = nil) async throws -> [LiveOddsDTO] {
        try await provider.liveOdds(matchKey: matchKey)
    }

    func officialRankingProjection(
        tour: String? = nil,
        tournamentKey: String? = nil,
        playerKey: String? = nil
    ) async throws -> OfficialRankingProjectionSnapshot {
        guard let backendURL = TennisAPIConfiguration.backendServiceBaseURL else {
            throw APIError(message: "Serviço de ranking indisponível no momento.")
        }

        var query: [String: String] = [:]
        if let tour, !tour.isEmpty { query["tour"] = tour }
        if let tournamentKey, !tournamentKey.isEmpty { query["tournament_key"] = tournamentKey }
        if let playerKey, !playerKey.isEmpty { query["player_key"] = playerKey }

        return try await APIClient(
            baseURL: backendURL,
            session: TennisAPIConfiguration.makeProviderURLSession()
        ).get(
            path: "rankings/live-projection",
            query: query,
            as: OfficialRankingProjectionSnapshot.self
        )
    }
}

extension TennisAPI: TennisAPIProviding {}

struct APITennisProvider {
    private let client: APIClient
    private let usesBackendProxy: Bool

    init(
        baseURL: URL,
        usesBackendProxy: Bool,
        hasBackendProxy: Bool,
        session: URLSession = TennisAPIConfiguration.makeProviderURLSession()
    ) {
        self.client = APIClient(baseURL: baseURL, session: session)
        self.usesBackendProxy = usesBackendProxy
    }

    /// Dynamic-URL variant — the closure is re-evaluated per request so a
    /// configuration change at runtime takes effect immediately.
    init(
        baseURLProvider: @escaping () -> URL,
        usesBackendProxy: Bool,
        hasBackendProxy: Bool,
        session: URLSession = TennisAPIConfiguration.makeProviderURLSession()
    ) {
        self.client = APIClient(baseURLProvider: baseURLProvider, session: session)
        self.usesBackendProxy = usesBackendProxy
    }

    func tournaments() async throws -> [TournamentDTO] {
        try await instrumented(.tournaments) {
            let response: APIEnvelope<[APITournament]> = try await request(method: "get_tournaments")
            return (response.result ?? []).map(TournamentDTO.init)
        }
    }

    func rankings(tour: String? = nil) async throws -> [RankingEntryDTO] {
        try await instrumented(.rankings) {
            let normalizedTour = normalizeTour(tour)
            let response: APIEnvelope<[APIStanding]> = try await request(
                method: "get_standings",
                extraQuery: ["event_type": normalizedTour]
            )

            return (response.result ?? []).compactMap { standing in
                guard let rank = Int(standing.place.value), let points = Int(standing.points.value) else {
                    return nil
                }
                let playerKey = standing.playerKey.value

                return RankingEntryDTO(
                    id: "\(normalizedTour)-\(playerKey)",
                    playerId: playerKey,
                    playerName: standing.playerName,
                    nationality: standing.countryName ?? "UNK",
                    rank: rank,
                    points: points,
                    tour: normalizedTour
                )
            }
        }
    }

    func players(tour: String? = nil) async throws -> [PlayerDTO] {
        // Graceful degradation: if rankings OR live matches fails the other path
        // still feeds the aggregation. Failures must surface in logs/metrics so
        // we can spot a half-broken provider instead of an empty player list.
        let rankingPlayers: [PlayerDTO]
        do {
            rankingPlayers = try await rankings(tour: tour).map { ranking in
                PlayerDTO(
                    id: ranking.playerId,
                    name: ranking.playerName,
                    nationality: ranking.nationality,
                    tour: ranking.tour,
                    birthDate: nil
                )
            }
        } catch {
            AppLogger.api.error("players.rankings failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "api", operation: "players.rankings", error: error)
            rankingPlayers = []
        }

        let livePlayers: [PlayerDTO]
        do {
            livePlayers = try await liveMatches().flatMap { match in
                [
                    PlayerDTO(
                        id: match.player1Id,
                        name: match.player1Name,
                        nationality: match.player1Country,
                        tour: normalizeTour(tour),
                        birthDate: nil
                    ),
                    PlayerDTO(
                        id: match.player2Id,
                        name: match.player2Name,
                        nationality: match.player2Country,
                        tour: normalizeTour(tour),
                        birthDate: nil
                    )
                ]
            }
        } catch {
            AppLogger.api.error("players.liveMatches failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "api", operation: "players.liveMatches", error: error)
            livePlayers = []
        }

        let merged = mergePlayers(rankingPlayers + livePlayers)
        if merged.isEmpty {
            let error = DataSyncError.emptyResponse("jogadores")
            ProviderHealthTracker.reportFailure(scope: .players, error: error)
            throw error
        }
        ProviderHealthTracker.reportSuccess(scope: .players, latencyMillis: 0)
        return merged
    }

    func liveMatches() async throws -> [MatchDTO] {
        try await instrumented(.liveMatches) {
            let response: APIEnvelope<[APILiveMatch]> = try await request(method: "get_livescore")
            return (response.result ?? []).map(mapLiveMatch)
        }
    }

    /// Wraps a REST call with latency capture + success/failure recording on
    /// the shared health tracker AND the persistent failure dashboard.
    ///
    /// Two sinks by design:
    /// - `ProviderHealthTracker` — in-memory, real-time counters shown in the
    ///   Provider Diagnostics session.
    /// - `AppLogger.recordFailure` — 30-day rolling dashboard, sanitized and
    ///   deduped by `category.operation`. This is the "failure dashboard"
    ///   surface ops uses to spot silent regressions.
    ///
    /// Every entry-point method in `APITennisProvider` should go through
    /// this so both sinks stay populated automatically.
    func instrumented<T>(_ scope: ProviderHealthTracker.Scope, _ body: () async throws -> T) async throws -> T {
        let started = Date()
        do {
            let value = try await body()
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            ProviderHealthTracker.reportSuccess(scope: scope, latencyMillis: elapsed)
            return value
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            ProviderHealthTracker.reportFailure(scope: scope, error: error, latencyMillis: elapsed)
            AppLogger.recordFailure(category: "api", operation: scope.rawValue, error: error)
            throw error
        }
    }

    func request<Response: Decodable>(
        method: String,
        extraQuery: [String: String] = [:]
    ) async throws -> Response {
        guard usesBackendProxy else {
            throw APIError(message: "Serviço de dados indisponível no momento.")
        }

        var query = [
            "method": method
        ]
        extraQuery.forEach { query[$0.key] = $0.value }

        var lastRetryableError: Error?
        for attempt in 0..<3 {
            do {
                return try await client.get(query: query, as: Response.self)
            } catch let error as APIHTTPError where error.shouldRetry {
                lastRetryableError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
                }
            } catch {
                throw error
            }
        }
        throw lastRetryableError ?? APIError(message: "Não foi possível sincronizar os dados.")
    }

    func normalizeTour(_ tour: String?) -> String {
        switch tour?.uppercased() {
        case "WTA":
            return "WTA"
        default:
            return "ATP"
        }
    }

    func normalizeCountry(_ value: String?) -> String {
        let normalized = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "UNK" }
        return normalized.count <= 3 ? normalized.uppercased() : normalized
    }

    func normalizePlayerName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func mapLiveMatch(_ match: APILiveMatch) -> MatchDTO {
        let eventKey = match.eventKey.value
        let firstPlayerID = match.firstPlayerKey?.value ?? "p1-\(eventKey)"
        let secondPlayerID = match.secondPlayerKey?.value ?? "p2-\(eventKey)"
        let score = displayScore(finalResult: match.eventFinalResult, gameResult: match.eventGameResult, scores: match.scores)

        return MatchDTO(
            id: eventKey,
            date: parseDate(dateString: match.eventDate, timeString: match.eventTime) ?? .distantPast,
            tournamentId: match.tournamentKey?.value,
            tournamentName: match.tournamentName,
            player1Id: firstPlayerID,
            player2Id: secondPlayerID,
            player1Name: match.eventFirstPlayer,
            player2Name: match.eventSecondPlayer,
            player1Country: normalizeCountry(match.countryName),
            player2Country: normalizeCountry(match.countryName),
            score: score,
            status: match.eventStatus ?? "Live",
            isLive: match.eventLive?.value == "1" || (match.eventStatus ?? "").lowercased().contains("set"),
            serverName: serverName(from: match.eventServe, firstPlayer: match.eventFirstPlayer, secondPlayer: match.eventSecondPlayer),
            pointScore: pointScore(
                direct: match.pointScore ?? match.eventPointResult,
                first: match.eventFirstPlayerPoint?.value,
                second: match.eventSecondPlayerPoint?.value
            ),
            gameScore: match.eventGameResult ?? "",
            pointWinnerName: pointWinnerName(
                raw: match.pointWinner ?? match.eventPointWinner,
                firstPlayer: match.eventFirstPlayer,
                secondPlayer: match.eventSecondPlayer
            ),
            livePoints: livePointEvents(
                from: match.pointByPoint,
                matchDate: parseDate(dateString: match.eventDate, timeString: match.eventTime) ?? .distantPast,
                firstPlayer: match.eventFirstPlayer,
                secondPlayer: match.eventSecondPlayer
            ),
            advancedStats: mapAdvancedStats(match.statistics),
            orderOfPlay: mapOrderOfPlay(
                courtCandidates: [match.eventCourt, match.courtName, match.court, match.matchCourt, match.venue],
                orderCandidates: [match.orderOfPlay?.value, match.order?.value, match.matchOrder?.value, match.matchNumber?.value],
                source: "api-tennis"
            )
        )
    }

    func displayScore(finalResult: String?, gameResult: String?, scores: [APIScore]?) -> String {
        if let finalResult = cleaned(finalResult), finalResult != "-" {
            return finalResult
        }
        let setScores = (scores ?? []).compactMap { score -> (Int, String)? in
            let first = cleaned(score.scoreFirst?.value)
            let second = cleaned(score.scoreSecond?.value)
            guard let first, let second else { return nil }
            let setNumber = Int(score.scoreSet?.value ?? "") ?? Int.max
            return (setNumber, "\(first)-\(second)")
        }
        let line = setScores.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
        if !line.isEmpty {
            return line
        }
        return cleaned(gameResult) ?? ""
    }

    func mapAdvancedStats(_ statistics: LossyAPIMatchStatistics?) -> AdvancedMatchStatsSnapshot? {
        guard let values = statistics?.values, !values.isEmpty else { return nil }

        var player1 = AdvancedMatchStatsSnapshot.PlayerStats()
        var player2 = AdvancedMatchStatsSnapshot.PlayerStats()

        for row in values {
            let label = normalizedStatLabel(row.type)
            guard !label.isEmpty else { continue }

            switch label {
            case let value where value.contains("ace"):
                player1.aces = parseStatInt(row.firstPlayer?.value)
                player2.aces = parseStatInt(row.secondPlayer?.value)
            case let value where value.contains("winner"):
                player1.winners = parseStatInt(row.firstPlayer?.value)
                player2.winners = parseStatInt(row.secondPlayer?.value)
            case let value where value.contains("unforced") || value.contains("erro nao forcado"):
                player1.unforcedErrors = parseStatInt(row.firstPlayer?.value)
                player2.unforcedErrors = parseStatInt(row.secondPlayer?.value)
            case let value where value.contains("double fault") || value.contains("dupla falta"):
                player1.doubleFaults = parseStatInt(row.firstPlayer?.value)
                player2.doubleFaults = parseStatInt(row.secondPlayer?.value)
            case let value where value.contains("net point") || value.contains("net approach") || value.contains("rede"):
                applyNetPointStat(row, player1: &player1, player2: &player2)
            default:
                break
            }
        }

        let snapshot = AdvancedMatchStatsSnapshot(
            player1: player1,
            player2: player2,
            source: "api-tennis",
            capturedAt: .now
        )
        return snapshot.hasAnyValue ? snapshot : nil
    }

    func mapOrderOfPlay(
        courtCandidates: [String?],
        orderCandidates: [String?],
        source: String
    ) -> MatchOrderOfPlaySnapshot? {
        guard let courtName = firstCleaned(courtCandidates) else { return nil }
        return MatchOrderOfPlaySnapshot(
            courtName: courtName,
            order: firstOrderValue(orderCandidates),
            source: source,
            capturedAt: .now
        )
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstCleaned(_ values: [String?]) -> String? {
        for value in values {
            if let cleaned = cleaned(value), cleaned != "-" {
                return cleaned
            }
        }
        return nil
    }

    private func firstOrderValue(_ values: [String?]) -> Int? {
        for value in values {
            if let parsed = parseStatInt(value) {
                return parsed
            }
        }
        return nil
    }

    private func normalizedStatLabel(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseStatInt(_ raw: String?) -> Int? {
        guard let raw = cleaned(raw) else { return nil }
        let digits = raw.prefix { $0.isNumber }
        if let value = Int(String(digits)) {
            return value
        }
        return Int(raw.filter(\.isNumber))
    }

    private func parseMadeAttempt(_ raw: String?) -> (made: Int, attempts: Int?) {
        guard let raw = cleaned(raw) else { return (0, nil) }
        let separators = CharacterSet(charactersIn: "/-")
        let parts = raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.count >= 2, let made = parseStatInt(parts[0]), let attempts = parseStatInt(parts[1]) {
            return (made, attempts)
        }
        return (parseStatInt(raw) ?? 0, nil)
    }

    private func applyNetPointStat(
        _ row: APIMatchStatistic,
        player1: inout AdvancedMatchStatsSnapshot.PlayerStats,
        player2: inout AdvancedMatchStatsSnapshot.PlayerStats
    ) {
        let first = parseMadeAttempt(row.firstPlayer?.value)
        let second = parseMadeAttempt(row.secondPlayer?.value)
        player1.netPointsWon = first.made
        player2.netPointsWon = second.made
        if let attempts = first.attempts {
            player1.netPointsPlayed = attempts
        }
        if let attempts = second.attempts {
            player2.netPointsPlayed = attempts
        }
    }

    func serverName(from serve: String?, firstPlayer: String, secondPlayer: String) -> String {
        let normalized = serve?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.contains("first") || normalized == "1" {
            return firstPlayer
        }
        if normalized.contains("second") || normalized == "2" {
            return secondPlayer
        }
        return ""
    }

    func pointScore(direct: String?, first: String?, second: String?) -> String {
        if let direct = cleaned(direct), direct != "-" {
            return direct
        }
        if let first = cleaned(first), let second = cleaned(second) {
            return "\(first)-\(second)"
        }
        return ""
    }

    func pointWinnerName(raw: String?, firstPlayer: String, secondPlayer: String) -> String? {
        guard let raw = cleaned(raw) else { return nil }
        let normalized = raw.lowercased()
        if normalized == "1" || normalized.contains("first") || normalized.contains("home") {
            return firstPlayer
        }
        if normalized == "2" || normalized.contains("second") || normalized.contains("away") {
            return secondPlayer
        }
        if firstPlayer.localizedCaseInsensitiveContains(raw) || raw.localizedCaseInsensitiveContains(firstPlayer) {
            return firstPlayer
        }
        if secondPlayer.localizedCaseInsensitiveContains(raw) || raw.localizedCaseInsensitiveContains(secondPlayer) {
            return secondPlayer
        }
        return raw
    }

    func livePointEvents(
        from games: [APIPointByPointGame]?,
        matchDate: Date,
        firstPlayer: String,
        secondPlayer: String
    ) -> [LivePointDTO] {
        let flattened = (games ?? []).flatMap { game -> [LivePointDTO] in
            let server = playerName(fromRole: game.playerServed, firstPlayer: firstPlayer, secondPlayer: secondPlayer)
            let gameScore = game.score
            let gameNumber = Int(game.numberGame?.value ?? "") ?? 0
            let setNumber = numericSuffix(in: game.setNumber) ?? 0
            var previousScore = "0 - 0"

            return (game.points ?? []).compactMap { point in
                guard let pointScore = cleaned(point.score) else { return nil }
                defer { previousScore = pointScore }
                let winner = pointWinnerFromScoreChange(
                    previous: previousScore,
                    current: pointScore,
                    firstPlayer: firstPlayer,
                    secondPlayer: secondPlayer
                )
                let pointNumber = Int(point.numberPoint?.value ?? "") ?? 0
                let pressure = [point.breakPoint, point.setPoint, point.matchPoint]
                    .compactMap(cleaned)
                    .joined(separator: " • ")
                let title = winner.map { "Ponto \($0)" } ?? "Ponto registrado"
                let detailParts = [
                    winner.map { "Ponto: \($0)" },
                    server.map { "Saque: \($0)" },
                    Optional("Pontos: \(pointScore)"),
                    gameScore.map { "Games: \($0)" },
                    pressure.isEmpty ? nil : pressure
                ].compactMap { $0 }

                return LivePointDTO(
                    timestamp: matchDate.addingTimeInterval(Double(setNumber * 10_000 + gameNumber * 100 + pointNumber)),
                    title: title,
                    detail: detailParts.joined(separator: " • "),
                    pointWinnerName: winner,
                    serverName: server,
                    pointScore: pointScore,
                    gameScore: gameScore
                )
            }
        }

        return Array(flattened.suffix(24))
    }

    private func playerName(fromRole role: String?, firstPlayer: String, secondPlayer: String) -> String? {
        guard let role = cleaned(role)?.lowercased() else { return nil }
        if role.contains("first") || role == "1" {
            return firstPlayer
        }
        if role.contains("second") || role == "2" {
            return secondPlayer
        }
        return nil
    }

    private func pointWinnerFromScoreChange(
        previous: String,
        current: String,
        firstPlayer: String,
        secondPlayer: String
    ) -> String? {
        guard
            let previousPair = tennisPointPair(previous),
            let currentPair = tennisPointPair(current)
        else {
            return nil
        }

        if currentPair.0 > previousPair.0 {
            return firstPlayer
        }
        if currentPair.1 > previousPair.1 {
            return secondPlayer
        }
        if currentPair.0 < previousPair.0 && currentPair.1 == previousPair.1 {
            return secondPlayer
        }
        if currentPair.1 < previousPair.1 && currentPair.0 == previousPair.0 {
            return firstPlayer
        }
        return nil
    }

    private func tennisPointPair(_ score: String) -> (Int, Int)? {
        let parts = score
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "-")
            .map(String.init)
        guard parts.count == 2 else { return nil }
        guard let first = tennisPointValue(parts[0]), let second = tennisPointValue(parts[1]) else { return nil }
        return (first, second)
    }

    private func tennisPointValue(_ value: String) -> Int? {
        switch value.uppercased() {
        case "0":
            return 0
        case "15":
            return 1
        case "30":
            return 2
        case "40":
            return 3
        case "A", "AD":
            return 4
        default:
            return Int(value)
        }
    }

    private func numericSuffix(in value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.filter(\.isNumber))
    }

    private func mergePlayers(_ players: [PlayerDTO]) -> [PlayerDTO] {
        var byID: [String: PlayerDTO] = [:]

        for player in players {
            let normalized = PlayerDTO(
                id: player.id,
                name: normalizePlayerName(player.name),
                nationality: normalizeCountry(player.nationality),
                tour: normalizeTour(player.tour),
                birthDate: player.birthDate
            )

            if let existing = byID[normalized.id] {
                byID[normalized.id] = PlayerDTO(
                    id: existing.id,
                    name: existing.name == "Unknown" ? normalized.name : existing.name,
                    nationality: existing.nationality == "UNK" ? normalized.nationality : existing.nationality,
                    tour: existing.tour.isEmpty ? normalized.tour : existing.tour,
                    birthDate: existing.birthDate ?? normalized.birthDate
                )
            } else {
                byID[normalized.id] = normalized
            }
        }

        return byID.values.sorted { $0.name < $1.name }
    }


}
