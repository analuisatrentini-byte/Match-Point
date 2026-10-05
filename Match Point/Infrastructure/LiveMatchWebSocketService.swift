import Combine
import Foundation
import OSLog
import SwiftData

@MainActor
final class LiveMatchWebSocketService: ObservableObject {
    // MARK: - State

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:
                return "Live Off"
            case .connecting:
                return "Connecting"
            case .connected:
                return "Live On"
            case .failed:
                return "Live Error"
            }
        }

        var isActive: Bool {
            switch self {
            case .connecting, .connected:
                return true
            case .disconnected, .failed:
                return false
            }
        }
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var retryAttempt = 0
    @Published private(set) var lastMessageAt: Date?
    @Published private(set) var lastRESTFallbackAt: Date?
    @Published private(set) var fallbackNotice: String?
    @Published private(set) var lastCrossCheckAt: Date?
    @Published private(set) var crossCheckNotice: String?
    @Published private(set) var qualityByMatchKey: [String: LiveDataConfidence] = [:]

    private let context: ModelContext
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var inactivityTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var fallbackPollingTask: Task<Void, Never>?
    private var startupFallbackTask: Task<Void, Never>?
    private var crossCheckTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?
    private var shouldAutoReconnect = false
    private var connectionRequest = ConnectionRequest()

    private let maxRetryAttempts = 6
    private let inactivityTimeout: TimeInterval = 30
    private let startupFallbackDelay: TimeInterval = 8
    private let restFallbackPollingInterval: TimeInterval = 20
    private let crossCheckInterval: TimeInterval = 20
    private let maxPayloadDepth = 32
    private let maxFrameBytes = 256_000
    /// Per-frame notification rescheduling is wasteful — bursts of WebSocket frames
    /// would otherwise pile up dozens of pending Tasks. Throttle to once per minute.
    private let notificationRefreshInterval: TimeInterval = 60
    private var lastNotificationRefreshAt: Date = .distantPast
    private let saveDebounceInterval: TimeInterval = 2
    private let saveFrameThreshold = 5
    private var unsavedFrameCount = 0
    private var lastFrameSaveAt = Date()

    // Per-frame N+1 buster. Each frame used to fetch player1, player2, tournament,
    // match and rankings; on a busy live session that's tens of fetches per second.
    // The cache is keyed by normalizedIdentity so it survives small whitespace/case
    // variations between providers. Refreshed on a TTL since players come and go
    // (new entrants when the user pulls fresh sync).
    private var playerCache: [String: Player] = [:]
    private var tournamentCache: [String: Tournament] = [:]
    private var matchCache: [String: TennisMatch] = [:]
    private var cachedRankings: [RankingEntry] = []
    private var lastCacheRebuildAt: Date = .distantPast
    private let cacheTTL: TimeInterval = 120

    private struct ConnectionRequest {
        var tournamentKey: String?
        var matchKey: String?
        var playerKey: String?
    }

    init(context: ModelContext, session: URLSession = .shared) {
        self.context = context
        self.session = session
    }

    // MARK: - Connection Lifecycle

    func connect(
        tournamentKey: String? = nil,
        matchKey: String? = nil,
        playerKey: String? = nil
    ) {
        connectionRequest = ConnectionRequest(
            tournamentKey: tournamentKey,
            matchKey: matchKey,
            playerKey: playerKey
        )
        retryAttempt = 0
        fallbackNotice = nil
        shouldAutoReconnect = true
        openSocket()
    }

    func reconnect() {
        retryAttempt = 0
        fallbackNotice = nil
        shouldAutoReconnect = true
        openSocket()
    }

    private func openSocket() {
        if TennisAPIConfiguration.backendWebSocketBaseURL == nil {
            state = .failed("Atualizações ao vivo indisponíveis no momento")
            Task { [weak self] in await self?.performRESTFallback(reason: "missing-backend-websocket") }
            return
        }

        closeSocket(markDisconnected: false)
        state = .connecting

        guard let url = makeURL(
            tournamentKey: connectionRequest.tournamentKey,
            matchKey: connectionRequest.matchKey,
            playerKey: connectionRequest.playerKey
        ) else {
            AppLogger.live.error("WebSocket URL construction failed for current ConnectionRequest")
            AppLogger.recordFailure(
                category: "live",
                operation: "openSocket.makeURL",
                error: APIError(message: "Invalid WebSocket URL")
            )
            state = .failed("URL inválida para WebSocket")
            Task { [weak self] in await self?.performRESTFallback(reason: "invalid-websocket-url") }
            return
        }

        // Track whether setup ran to completion. If anything between the
        // socket task creation and the inactivity monitor blows up (Obj-C
        // exception bridged into Swift, future throwing setup added by
        // someone, etc.), the deferred guard tears down everything so we
        // don't leave inactivityTask spinning in the background reading from
        // a webSocketTask nobody owns anymore.
        var setupCompleted = false
        defer {
            if !setupCompleted {
                closeSocket(markDisconnected: true)
                LiveMatchActivityFlag.setActive(false)
            }
        }

        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maxFrameBytes
        webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startInactivityMonitor()
        startStartupFallbackTimer()
        setupCompleted = true

        // Stay in .connecting until the receive loop confirms a frame arrived.
        // Otherwise the UI shows "Live On" even when the handshake silently fails.
    }

    func disconnect() {
        shouldAutoReconnect = false
        retryTask?.cancel()
        retryTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackPollingTask?.cancel()
        fallbackPollingTask = nil
        startupFallbackTask?.cancel()
        startupFallbackTask = nil
        crossCheckTask?.cancel()
        crossCheckTask = nil
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        saveContext("websocket disconnect")
        closeSocket(markDisconnected: true)
        LiveMatchActivityFlag.setActive(false)
    }

    private func closeSocket(markDisconnected: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        inactivityTask?.cancel()
        inactivityTask = nil
        startupFallbackTask?.cancel()
        startupFallbackTask = nil
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        if markDisconnected {
            state = .disconnected
            LiveMatchActivityFlag.setActive(false)
        }
    }

    /// Returns nil if the base URL can't be decomposed (shouldn't happen with our
    /// constants) or if user-supplied keys produce an unencodable URL. Caller
    /// surfaces a failure state instead of crashing.
    private func makeURL(
        tournamentKey: String?,
        matchKey: String?,
        playerKey: String?
    ) -> URL? {
        guard var components = URLComponents(url: TennisAPIConfiguration.webSocketBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = [
            URLQueryItem(name: "timezone", value: TennisAPIConfiguration.timeZone)
        ]

        if let tournamentKey, !tournamentKey.isEmpty {
            queryItems.append(URLQueryItem(name: "tournament_key", value: tournamentKey))
        }
        if let matchKey, !matchKey.isEmpty {
            queryItems.append(URLQueryItem(name: "match_key", value: matchKey))
        }
        if let playerKey, !playerKey.isEmpty {
            queryItems.append(URLQueryItem(name: "player_key", value: playerKey))
        }

        components.queryItems = queryItems
        return components.url
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        do {
            while !Task.isCancelled, webSocketTask.closeCode == .invalid {
                let message = try await webSocketTask.receive()
                lastMessageAt = .now
                retryAttempt = 0
                state = .connected
                startupFallbackTask?.cancel()
                startupFallbackTask = nil
                fallbackPollingTask?.cancel()
                fallbackPollingTask = nil
                LiveMatchActivityFlag.setActive(true)
                ProviderHealthTracker.shared.recordWebSocketFrame()
                ProviderHealthTracker.shared.recordWebSocketState("connected")
                try handle(message: message)
            }

            if !Task.isCancelled, webSocketTask.closeCode != .normalClosure {
                handleSocketFailure(Self.describe(closeCode: webSocketTask.closeCode))
            }
        } catch {
            if !Task.isCancelled {
                handleSocketFailure(error.localizedDescription)
            }
        }
    }

    /// Human-readable, user-safe label for each WebSocket close code. Helps both
    /// the logs and the user-facing "Live Error" pill explain what happened.
    private static func describe(closeCode: URLSessionWebSocketTask.CloseCode) -> String {
        switch closeCode {
        case .invalid: return "Conexão encerrada sem código"
        case .normalClosure: return "Encerramento normal"
        case .goingAway: return "Servidor reiniciando"
        case .protocolError: return "Erro de protocolo WebSocket"
        case .unsupportedData: return "Servidor enviou dado não suportado"
        case .noStatusReceived: return "Sem código de fechamento"
        case .abnormalClosure: return "Conexão caiu sem aviso"
        case .invalidFramePayloadData: return "Frame inválido"
        case .policyViolation: return "Servidor recusou (policy violation)"
        case .messageTooBig: return "Mensagem maior que o limite"
        case .mandatoryExtensionMissing: return "Extensão obrigatória ausente"
        case .internalServerError: return "Erro interno do servidor"
        case .tlsHandshakeFailure: return "Falha no TLS handshake"
        @unknown default: return "Código de fechamento desconhecido"
        }
    }

    // MARK: - Reconnect and Fallback

    private func startInactivityMonitor() {
        inactivityTask?.cancel()
        lastMessageAt = .now
        // Service is @MainActor; pin the Task to MainActor so sync calls don't need
        // an explicit `await` and the compiler stops warning about "no async ops".
        inactivityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                self?.checkInactivity()
            }
        }
    }

    private func checkInactivity() {
        guard case .connected = state else { return }
        let lastMessageAt = lastMessageAt ?? .distantPast
        guard Date().timeIntervalSince(lastMessageAt) > inactivityTimeout else { return }
        let stallReason = "Sem frames live por \(Int(inactivityTimeout))s"
        ProviderHealthTracker.shared.recordWebSocketStall(reason: stallReason)
        handleSocketFailure(stallReason)
    }

    private func startStartupFallbackTimer() {
        startupFallbackTask?.cancel()
        startupFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.startupFallbackDelay ?? 8))
            } catch {
                return
            }
            guard let self, case .connecting = self.state else { return }
            await self.performRESTFallback(reason: "startup-timeout")
        }
    }

    private func startRESTFallbackPolling() {
        guard fallbackPollingTask == nil else { return }
        fallbackPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.performRESTFallback(reason: "rest-polling")
                do {
                    try await Task.sleep(for: .seconds(self?.restFallbackPollingInterval ?? 20))
                } catch {
                    return
                }
            }
        }
    }

    private func handleSocketFailure(_ message: String) {
        AppLogger.live.error("WebSocket failed: \(message, privacy: .private)")
        // Persisted for the internal failure dashboard so an ops user can
        // quickly diff "how many disconnects in the last 30d" without needing
        // Instruments.
        AppLogger.recordFailure(
            category: "live",
            operation: "webSocket.disconnect",
            error: APIError(message: message)
        )
        state = .failed(message)
        LiveMatchActivityFlag.setActive(false)
        fallbackNotice = "WebSocket indisponível: \(message). Atualizando placares via REST enquanto tenta reconectar."
        ProviderHealthTracker.shared.recordWebSocketState("failed", reason: message)
        ProviderHealthTracker.shared.recordFailure(scope: .webSocket, error: APIError(message: message))
        ProviderHealthTracker.shared.recordWebSocketFallback(reason: message)
        closeSocket(markDisconnected: false)
        Task { [weak self] in await self?.performRESTFallback(reason: "websocket-failure") }
        startRESTFallbackPolling()
        scheduleReconnect(after: message)
    }

    private func scheduleReconnect(after message: String) {
        guard shouldAutoReconnect else { return }
        guard retryAttempt < maxRetryAttempts else {
            AppLogger.live.error("WebSocket retry limit reached after: \(message, privacy: .private)")
            // Exhausted retries — switch permanently to REST polling so scores
            // stay fresh even when the WebSocket backend is unavailable.
            Task { [weak self] in await self?.performRESTFallback(reason: "retry-exhausted") }
            return
        }

        retryAttempt += 1
        ProviderHealthTracker.shared.recordWebSocketReconnect()
        let delay = Self.reconnectDelay(forAttempt: retryAttempt)
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.openSocket()
        }
    }

    nonisolated static func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        min(pow(2.0, Double(max(0, attempt))), 60)
    }

    private func performRESTFallback(reason: String) async {
        guard fallbackTask == nil else { return }
        let context = self.context
        fallbackTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.fallbackTask = nil } }
            do {
                let restMatches = try await TennisAPI().liveMatches()
                await MainActor.run { [weak self] in
                    self?.reconcileRESTLiveMatches(restMatches)
                }
                try await SyncCoordinator.shared.runMainActor {
                    let service = DataSyncService(context: context)
                    try await service.syncLiveMatches(using: restMatches)
                }
                await MainActor.run { [weak self] in
                    let now = Date()
                    self?.lastRESTFallbackAt = now
                    self?.lastCrossCheckAt = now
                    self?.fallbackNotice = "WebSocket sem confiança total; placares conferidos por REST \(now.formatted(date: .omitted, time: .shortened))."
                }
            } catch {
                AppLogger.live.error("REST fallback failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "live", operation: "restFallback.\(reason)", error: error)
                await MainActor.run { [weak self] in
                    self?.fallbackNotice = "A conexão ao vivo caiu e a atualização alternativa também falhou. Verifique sua conexão e tente reconectar."
                }
            }
        }
        await fallbackTask?.value
    }

    private func reconcileRESTLiveMatches(_ restMatches: [MatchDTO]) {
        let now = Date()
        refreshCachesIfStale()
        var verified = 0
        var conflicts = 0

        for dto in restMatches {
            let key = dto.id
            let remote = LiveScoreSnapshot(dto: dto)
            let localMatch = matchCache["external:\(key)"]
            guard let localMatch else {
                qualityByMatchKey[key] = LiveDataConfidence(
                    status: .estimated,
                    checkedAt: now,
                    message: "REST encontrou esta partida antes do WebSocket."
                )
                continue
            }

            let local = LiveScoreSnapshot(match: localMatch)
            if local.materiallyMatches(remote) {
                verified += 1
                qualityByMatchKey[key] = .verified(at: now)
            } else {
                conflicts += 1
                qualityByMatchKey[key] = .conflicted(local: local, remote: remote, at: now)
            }
        }

        lastCrossCheckAt = now
        if conflicts > 0 {
            crossCheckNotice = "\(conflicts) placar(es) divergiram entre WebSocket e REST; exibindo REST como correção rápida."
        } else if verified > 0 {
            crossCheckNotice = "\(verified) placar(es) conferidos entre WebSocket e REST."
        }
    }

    private func scheduleCrossCheckIfNeeded() {
        guard crossCheckTask == nil else { return }
        if let lastCrossCheckAt, Date().timeIntervalSince(lastCrossCheckAt) < crossCheckInterval {
            return
        }
        crossCheckTask = Task { @MainActor [weak self] in
            await self?.performRESTFallback(reason: "cross-check")
            self?.crossCheckTask = nil
        }
    }

    private func markEstimatedQuality(for match: TennisMatch) {
        guard let key = match.externalID, !key.isEmpty else { return }
        qualityByMatchKey[key] = .realtimeUpdated(at: match.lastUpdatedAt ?? .now)
    }

    private func handle(message: URLSessionWebSocketTask.Message) throws {
        switch message {
        case .string(let text):
            try process(text: text)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw APIError(message: "Invalid WebSocket payload")
            }
            try process(text: text)
        @unknown default:
            throw APIError(message: "Unsupported WebSocket message")
        }
    }

    // MARK: - Frame Parsing

    private func process(text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw APIError(message: "Invalid payload encoding")
        }

        let json = try JSONSerialization.jsonObject(with: data)
        let dictionaries = Self.extractMatchDictionaries(from: json, maxDepth: maxPayloadDepth)

        for dictionary in dictionaries {
            applyLiveUpdate(from: dictionary)
        }

        saveFrameIfNeeded()
    }

    private func saveFrameIfNeeded() {
        unsavedFrameCount += 1
        let now = Date()
        guard unsavedFrameCount >= saveFrameThreshold || now.timeIntervalSince(lastFrameSaveAt) >= saveDebounceInterval else {
            scheduleDebouncedSave()
            return
        }
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        unsavedFrameCount = 0
        lastFrameSaveAt = now
        saveContext("websocket frame batch")
    }

    private func scheduleDebouncedSave() {
        guard debouncedSaveTask == nil else { return }
        debouncedSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.saveDebounceInterval ?? 2))
            } catch {
                return
            }
            guard let self else { return }
            guard self.unsavedFrameCount > 0 else {
                self.debouncedSaveTask = nil
                return
            }
            self.unsavedFrameCount = 0
            self.lastFrameSaveAt = .now
            self.debouncedSaveTask = nil
            self.saveContext("websocket debounced frame batch")
        }
    }

    nonisolated static func matchDictionaries(fromFrameData data: Data, maxDepth: Int = 32) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        return extractMatchDictionaries(from: json, maxDepth: maxDepth)
    }

    /// Hard cap on the number of sibling keys / array elements traversed at a
    /// single nesting level. The 16 KB frame limit already shapes the worst
    /// case, but a payload that packs 10k single-character keys at depth 1
    /// would still produce 10k recursive calls — bound it explicitly.
    nonisolated static let maxPayloadBreadth = 1_000

    /// Walks a freshly-parsed `JSONSerialization` tree looking for objects
    /// shaped like match payloads (keys such as `match_key`, `event_key`,
    /// `event_first_player`, `first_player_key`).
    ///
    /// # Stack budget
    ///
    /// Swift does not optimize tail calls, so each level of nesting adds a
    /// frame to the call stack. Bounded by `maxDepth` (default 32), the worst
    /// case is **32 frames deep at any moment** — `flatMap` iterates synchronously
    /// at level N+1 and the parent's frame is reused as each child returns.
    /// Empirical frame size for this function is ~100-300 bytes, so the
    /// maximum live stack usage is ≈10 KB — comfortably under the iOS main
    /// thread limit (512 KB on 64-bit, 4 KB on a Task worker but we run on
    /// `nonisolated` from `URLSession`'s queue, not a Task).
    ///
    /// `maxPayloadBreadth` (1 000) prevents `flatMap` over a hostile object
    /// with 10k siblings at depth 1 from producing 10k irmãs in a single
    /// frame — the eager `.values.flatMap` would still allocate an
    /// O(siblings) array even though it doesn't push 10k stack frames.
    ///
    /// # If this ever needs to grow
    ///
    /// Should `maxDepth` need to exceed ~256 (4× current), convert to an
    /// iterative walk with an explicit `[(Any, Int)]` work-stack. The
    /// recursive form is kept for readability while the depth cap fits the
    /// stack budget with two orders of magnitude of headroom.
    nonisolated private static func extractMatchDictionaries(from json: Any, maxDepth: Int, depth: Int = 0) -> [[String: Any]] {
        // Hard-cap traversal so an adversarial frame can't blow the stack.
        guard depth < maxDepth else {
            return []
        }

        if let dictionary = json as? [String: Any] {
            if looksLikeMatchPayload(dictionary) {
                return [dictionary]
            }

            if let result = dictionary["result"] {
                return extractMatchDictionaries(from: result, maxDepth: maxDepth, depth: depth + 1)
            }

            // Refuse to walk obviously hostile fan-outs at a single level.
            // Real provider payloads stay well under a few hundred keys per
            // object; anything past `maxPayloadBreadth` looks like fuzzing.
            guard dictionary.count <= maxPayloadBreadth else { return [] }
            return dictionary.values.flatMap { extractMatchDictionaries(from: $0, maxDepth: maxDepth, depth: depth + 1) }
        }

        if let array = json as? [Any] {
            guard array.count <= maxPayloadBreadth else { return [] }
            return array.flatMap { extractMatchDictionaries(from: $0, maxDepth: maxDepth, depth: depth + 1) }
        }

        return []
    }

    nonisolated private static func looksLikeMatchPayload(_ dictionary: [String: Any]) -> Bool {
        dictionary["match_key"] != nil ||
        dictionary["event_key"] != nil ||
        dictionary["event_first_player"] != nil ||
        dictionary["first_player_key"] != nil
    }

    private func applyLiveUpdate(from payload: [String: Any]) {
        let externalID = stringValue(forAnyOf: ["match_key", "event_key"], in: payload)
        let firstPlayerName = stringValue(forAnyOf: ["event_first_player", "first_player", "player1_name"], in: payload) ?? "Player 1"
        let secondPlayerName = stringValue(forAnyOf: ["event_second_player", "second_player", "player2_name"], in: payload) ?? "Player 2"
        let tournamentName = stringValue(forAnyOf: ["tournament_name", "league_name"], in: payload) ?? "Live Tournament"
        let status = stringValue(forAnyOf: ["event_status", "match_status"], in: payload) ?? "Live"
        let score = stringValue(forAnyOf: ["event_final_result", "event_game_result", "score"], in: payload) ?? ""
        let gameScore = stringValue(forAnyOf: ["event_game_result", "game_score", "gamescore"], in: payload) ?? ""
        let pointScore = pointScore(from: payload)
        let serverName = serverName(from: payload, player1Name: firstPlayerName, player2Name: secondPlayerName)
        let pointWinner = pointWinnerName(from: payload, player1Name: firstPlayerName, player2Name: secondPlayerName)
        let advancedStats = advancedStatsSnapshot(from: payload)
        let orderOfPlay = orderOfPlaySnapshot(from: payload)
        let parsedDate = Self.parseDate(
            dateString: stringValue(forAnyOf: ["event_date", "match_date"], in: payload),
            timeString: stringValue(forAnyOf: ["event_time", "match_time"], in: payload)
        )

        let player1 = fetchOrCreatePlayer(named: firstPlayerName)
        let player2 = fetchOrCreatePlayer(named: secondPlayerName)
        // Only new tournaments and matches need a synthesized date; updates keep their existing one.
        let referenceDate = parsedDate ?? .now
        let tournament = fetchOrCreateTournament(named: tournamentName, on: referenceDate)
        let match = fetchOrCreateMatch(externalID: externalID, player1: player1, player2: player2, on: referenceDate)
        let previousSnapshot = AlertEventEngine.shared.snapshotForStoredMatch(match)

        match.externalID = externalID
        match.player1 = player1
        match.player2 = player2
        match.tournament = tournament
        if let parsedDate {
            match.date = parsedDate
        }
        match.status = status
        match.isLive = true
        match.lastUpdatedAt = .now
        match.serverName = serverName
        match.pointScore = pointScore
        match.gameScore = gameScore
        markEstimatedQuality(for: match)
        scheduleCrossCheckIfNeeded()
        if !score.isEmpty {
            match.score = score
        }
        match.registerLiveTimelineEvent(
            title: timelineTitle(from: payload, pointWinnerName: pointWinner),
            detail: timelineDetail(from: payload, fallbackMatch: match, pointWinnerName: pointWinner),
            pointWinnerName: pointWinner
        )
        match.updateAdvancedStatsSnapshot(advancedStats)
        match.updateOrderOfPlaySnapshot(orderOfPlay)

        LiveActivityController.shared.handle(match: match, rankings: cachedRankings)

        Task { [weak self] in
            await AlertEventEngine.shared.processMatchUpdate(match, previous: previousSnapshot)
            await self?.refreshScheduledNotificationsIfNeeded()
        }
    }

    // MARK: - Persistence Cache

    private func refreshScheduledNotificationsIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastNotificationRefreshAt) >= notificationRefreshInterval else {
            return
        }
        lastNotificationRefreshAt = now
        await AlertEventEngine.shared.refreshScheduledNotifications(in: context)
    }

    private func fetchOrCreatePlayer(named name: String) -> Player {
        let normalized = Self.normalizedIdentity(name)
        refreshCachesIfStale()

        if !normalized.isEmpty, let cached = playerCache[normalized] {
            return cached
        }

        // Cache miss — re-scan the table once and refresh the cache so subsequent
        // misses in this frame burst become hits.
        rebuildPlayerCache()
        if !normalized.isEmpty, let player = playerCache[normalized] {
            return player
        }

        let player = Player.insertStub(named: name, in: context)
        if !normalized.isEmpty {
            playerCache[normalized] = player
        }
        return player
    }

    private func fetchOrCreateTournament(named name: String, on date: Date) -> Tournament {
        let normalized = Self.normalizedIdentity(name)
        refreshCachesIfStale()

        if !normalized.isEmpty, let cached = tournamentCache[normalized] {
            return cached
        }

        rebuildTournamentCache()
        if !normalized.isEmpty, let tournament = tournamentCache[normalized] {
            return tournament
        }

        let tournament = Tournament.insertStub(named: name, on: date, in: context)
        if !normalized.isEmpty {
            tournamentCache[normalized] = tournament
        }
        return tournament
    }

    private func fetchOrCreateMatch(
        externalID: String?,
        player1: Player,
        player2: Player,
        on date: Date
    ) -> TennisMatch {
        let cacheKey = matchCacheKey(externalID: externalID, player1: player1, player2: player2, on: date)
        if let cached = matchCache[cacheKey] {
            return cached
        }

        if let match = TennisMatch.findLive(
            externalID: externalID,
            player1: player1,
            player2: player2,
            on: date,
            in: context
        ) {
            matchCache[cacheKey] = match
            return match
        }

        let match = TennisMatch.insertLiveStub(
            externalID: externalID,
            player1: player1,
            player2: player2,
            on: date,
            in: context
        )
        matchCache[cacheKey] = match
        return match
    }

    private func matchCacheKey(
        externalID: String?,
        player1: Player,
        player2: Player,
        on date: Date
    ) -> String {
        if let externalID, externalID.isEmpty == false {
            return "external:\(externalID)"
        }
        let day = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        return "local:\(player1.id.uuidString):\(player2.id.uuidString):\(Int(day))"
    }

    /// Rebuilds the entity caches when the TTL has expired. Per-frame fetches
    /// dominated CPU before this throttle was added — keep the TTL generous
    /// (cacheTTL = 120s) since live data churn within a session is low. Rankings
    /// barely change inside a session, but rebuilding them on the same cadence
    /// avoids stale rank labels surviving across a sync.
    private func refreshCachesIfStale() {
        guard Date().timeIntervalSince(lastCacheRebuildAt) > cacheTTL else { return }
        rebuildPlayerCache()
        rebuildTournamentCache()
        rebuildMatchCache()
        cachedRankings = fetch(FetchDescriptor<RankingEntry>(), context: "rebuild ranking cache")
        lastCacheRebuildAt = .now
    }

    private func rebuildPlayerCache() {
        let players = fetch(FetchDescriptor<Player>(), context: "rebuild player cache")
        playerCache = Dictionary(
            players.compactMap { player -> (String, Player)? in
                let normalized = Self.normalizedIdentity(player.name)
                return normalized.isEmpty ? nil : (normalized, player)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func rebuildTournamentCache() {
        let tournaments = fetch(FetchDescriptor<Tournament>(), context: "rebuild tournament cache")
        tournamentCache = Dictionary(
            tournaments.compactMap { tournament -> (String, Tournament)? in
                let normalized = Self.normalizedIdentity(tournament.name)
                return normalized.isEmpty ? nil : (normalized, tournament)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func rebuildMatchCache() {
        let matches = fetch(FetchDescriptor<TennisMatch>(), context: "rebuild match cache")
        matchCache = Dictionary(
            matches.compactMap { match -> (String, TennisMatch)? in
                guard let player1 = match.player1, let player2 = match.player2 else { return nil }
                return (matchCacheKey(externalID: match.externalID, player1: player1, player2: player2, on: match.date), match)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func stringValue(forAnyOf keys: [String], in payload: [String: Any]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
            if let value = payload[key] as? CustomStringConvertible {
                let string = value.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private func pointScore(from payload: [String: Any]) -> String {
        if let direct = stringValue(forAnyOf: ["point_score", "pointscore", "event_point_result"], in: payload) {
            return direct
        }

        let firstPoint = stringValue(forAnyOf: ["player1_point", "first_player_point", "event_first_player_point"], in: payload)
        let secondPoint = stringValue(forAnyOf: ["player2_point", "second_player_point", "event_second_player_point"], in: payload)

        if let firstPoint, let secondPoint {
            return "\(firstPoint)-\(secondPoint)"
        }

        return ""
    }

    private func advancedStatsSnapshot(from payload: [String: Any]) -> AdvancedMatchStatsSnapshot? {
        var player1 = AdvancedMatchStatsSnapshot.PlayerStats()
        var player2 = AdvancedMatchStatsSnapshot.PlayerStats()

        player1.aces = intValue(forAnyOf: ["player1_aces", "first_player_aces", "home_aces", "aces_player1"], in: payload)
        player2.aces = intValue(forAnyOf: ["player2_aces", "second_player_aces", "away_aces", "aces_player2"], in: payload)
        player1.winners = intValue(forAnyOf: ["player1_winners", "first_player_winners", "home_winners", "winners_player1"], in: payload)
        player2.winners = intValue(forAnyOf: ["player2_winners", "second_player_winners", "away_winners", "winners_player2"], in: payload)
        player1.unforcedErrors = intValue(forAnyOf: ["player1_unforced_errors", "first_player_unforced_errors", "home_unforced_errors", "unforced_errors_player1"], in: payload)
        player2.unforcedErrors = intValue(forAnyOf: ["player2_unforced_errors", "second_player_unforced_errors", "away_unforced_errors", "unforced_errors_player2"], in: payload)
        player1.doubleFaults = intValue(forAnyOf: ["player1_double_faults", "first_player_double_faults", "home_double_faults", "double_faults_player1"], in: payload)
        player2.doubleFaults = intValue(forAnyOf: ["player2_double_faults", "second_player_double_faults", "away_double_faults", "double_faults_player2"], in: payload)

        let firstNet = netPointValue(
            wonKeys: ["player1_net_points_won", "first_player_net_points_won", "home_net_points_won", "net_points_won_player1"],
            playedKeys: ["player1_net_points_played", "first_player_net_points_played", "home_net_points_played", "net_points_played_player1"],
            combinedKeys: ["player1_net_points", "first_player_net_points", "home_net_points", "net_points_player1"],
            in: payload
        )
        player1.netPointsWon = firstNet.won
        player1.netPointsPlayed = firstNet.played

        let secondNet = netPointValue(
            wonKeys: ["player2_net_points_won", "second_player_net_points_won", "away_net_points_won", "net_points_won_player2"],
            playedKeys: ["player2_net_points_played", "second_player_net_points_played", "away_net_points_played", "net_points_played_player2"],
            combinedKeys: ["player2_net_points", "second_player_net_points", "away_net_points", "net_points_player2"],
            in: payload
        )
        player2.netPointsWon = secondNet.won
        player2.netPointsPlayed = secondNet.played

        let snapshot = AdvancedMatchStatsSnapshot(player1: player1, player2: player2, source: "api-tennis-websocket", capturedAt: .now)
        return snapshot.hasAnyValue ? snapshot : nil
    }

    private func orderOfPlaySnapshot(from payload: [String: Any]) -> MatchOrderOfPlaySnapshot? {
        guard let courtName = stringValue(
            forAnyOf: [
                "event_court",
                "court_name",
                "court",
                "match_court",
                "venue",
                "stage"
            ],
            in: payload
        ) else {
            return nil
        }

        return MatchOrderOfPlaySnapshot(
            courtName: courtName,
            order: intValue(forAnyOf: ["order_of_play", "match_order", "order", "match_number"], in: payload),
            source: "api-tennis-websocket",
            capturedAt: .now
        )
    }

    private func intValue(forAnyOf keys: [String], in payload: [String: Any]) -> Int? {
        guard let value = stringValue(forAnyOf: keys, in: payload) else { return nil }
        let digits = value.prefix { $0.isNumber }
        if let parsed = Int(String(digits)) {
            return parsed
        }
        return Int(value.filter(\.isNumber))
    }

    private func netPointValue(
        wonKeys: [String],
        playedKeys: [String],
        combinedKeys: [String],
        in payload: [String: Any]
    ) -> (won: Int?, played: Int?) {
        let won = intValue(forAnyOf: wonKeys, in: payload)
        let played = intValue(forAnyOf: playedKeys, in: payload)
        if won != nil || played != nil {
            return (won, played)
        }
        guard let combined = stringValue(forAnyOf: combinedKeys, in: payload) else {
            return (nil, nil)
        }
        let parts = combined.components(separatedBy: CharacterSet(charactersIn: "/-"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (Int(parts[0].filter(\.isNumber)), Int(parts[1].filter(\.isNumber)))
        }
        return (intValue(forAnyOf: combinedKeys, in: payload), nil)
    }

    private func pointWinnerName(from payload: [String: Any], player1Name: String, player2Name: String) -> String? {
        guard let raw = stringValue(
            forAnyOf: [
                "point_winner",
                "event_point_winner",
                "winner",
                "last_point_winner",
                "scorer",
                "point_player"
            ],
            in: payload
        ) else {
            return nil
        }

        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "player1", "first", "home":
            return player1Name
        case "2", "player2", "second", "away":
            return player2Name
        default:
            if player1Name.localizedCaseInsensitiveContains(raw) || raw.localizedCaseInsensitiveContains(player1Name) {
                return player1Name
            }
            if player2Name.localizedCaseInsensitiveContains(raw) || raw.localizedCaseInsensitiveContains(player2Name) {
                return player2Name
            }
            return raw
        }
    }

    private func timelineTitle(from payload: [String: Any], pointWinnerName: String?) -> String {
        if let eventType = stringValue(forAnyOf: ["event_type", "type", "event_name"], in: payload) {
            return eventType
        }
        if let pointWinnerName {
            return "Ponto \(pointWinnerName)"
        }
        return "Atualização ponto a ponto"
    }

    private func timelineDetail(from payload: [String: Any], fallbackMatch match: TennisMatch, pointWinnerName: String?) -> String {
        if let direct = stringValue(forAnyOf: ["comment", "description", "detail", "message"], in: payload) {
            return direct
        }

        var fragments: [String] = []
        if let pointWinnerName {
            fragments.append("Ponto: \(pointWinnerName)")
        }
        if !match.serverName.isEmpty {
            fragments.append("Saque: \(match.serverName)")
        }
        if !match.pointScore.isEmpty {
            fragments.append("Pontos: \(match.pointScore)")
        }
        if !match.gameScore.isEmpty {
            fragments.append("Games: \(match.gameScore)")
        }
        if !match.score.isEmpty {
            fragments.append("Sets: \(match.score)")
        }
        return fragments.isEmpty ? "Frame live recebido" : fragments.joined(separator: " • ")
    }

    private func serverName(from payload: [String: Any], player1Name: String, player2Name: String) -> String {
        let rawServer = stringValue(forAnyOf: ["serve", "event_serve", "server", "serving_player"], in: payload) ?? ""
        let normalized = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return "" }

        switch normalized {
        case "1", "player1", "first", "home":
            return player1Name
        case "2", "player2", "second", "away":
            return player2Name
        default:
            return normalized
        }
    }

    /// Canonical form used to match Players and Tournaments across providers that
    /// report the same entity with different spacing, casing, or diacritics
    /// (e.g. "Carlos  Alcaraz" vs "Carlos Alcaraz", "Iga Świątek" vs "Iga Swiatek").
    nonisolated static func normalizedIdentity(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let collapsed = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a WebSocket frame's date/time. Returns nil so callers can keep an
    /// existing match.date intact instead of overwriting it with `.now`, which would
    /// silently shift historical matches forward to today.
    nonisolated static func parseDate(dateString: String?, timeString: String?) -> Date? {
        guard let dateString, !dateString.isEmpty else {
            return nil
        }

        if let timeString, !timeString.isEmpty {
            if let date = TennisAPIConfiguration.parseAPIDate(
                "\(dateString) \(timeString)",
                formats: ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"]
            ) {
                return date
            }
        }

        return TennisAPIConfiguration.parseAPIDate(dateString, formats: ["yyyy-MM-dd"])
    }

    private func saveContext(_ reason: String) {
        do {
            try context.save()
        } catch {
            AppLogger.persistence.error("SwiftData save failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: reason, error: error)
        }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, context reason: String) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.live.error("SwiftData fetch failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "live", operation: reason, error: error)
            return []
        }
    }
}
