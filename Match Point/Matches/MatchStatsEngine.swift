import Foundation

// MARK: - MatchStatsBreakdown
//
// Deriva estatísticas agregadas por jogador a partir da timeline ao vivo
// (MatchTimelineEvent) que o app persiste em `TennisMatch.liveTimelinePayload`.
// Não depende de nenhuma API externa: parseia os campos `pointWinnerName`,
// `serverName` e o texto de título/detalhe usando heurísticas tolerantes a
// diferenças de casing, diacríticos e nomes parciais — o mesmo tratamento que
// `LiveMatchWebSocketService` faz na ingestão.
//
// O que dá pra derivar hoje da timeline:
//  - Pontos ganhos (total, no saque, no retorno)
//  - Aces / winners / duplas faltas (via keywords no título/detalhe)
//  - Break points (enfrentados, salvos, convertidos)
//
// O que só aparece quando o provider envia estatística oficial:
//  - Unforced errors
//  - Net points / net approaches
//
// O que NÃO dá pra derivar sem dado bruto extra (e por isso não é exposto):
//  - % 1º saque, % 2º saque real: precisaria de sinalização "primeiro/segundo
//    saque" nos eventos.
//  - Winners no forehand vs backhand: exige tagging avançado que o provider
//    normalmente não devolve.
//
// A intenção é ser honesto: só mostramos números quando temos amostra e
// omitimos linhas quando ambos os jogadores estão zerados.

nonisolated struct AdvancedMatchStatsSnapshot: Codable, Equatable {
    struct PlayerStats: Codable, Equatable {
        var aces: Int?
        var winners: Int?
        var unforcedErrors: Int?
        var doubleFaults: Int?
        var netPointsWon: Int?
        var netPointsPlayed: Int?

        var hasAnyValue: Bool {
            if aces != nil { return true }
            if winners != nil { return true }
            if unforcedErrors != nil { return true }
            if doubleFaults != nil { return true }
            if netPointsWon != nil { return true }
            if netPointsPlayed != nil { return true }
            return false
        }
    }

    var player1: PlayerStats
    var player2: PlayerStats
    var source: String
    var capturedAt: Date

    var hasAnyValue: Bool {
        player1.hasAnyValue || player2.hasAnyValue
    }
}

struct MatchStatsBreakdown {
    struct PlayerStats: Equatable {
        var totalPoints: Int = 0
        var pointsOnServe: Int = 0
        var pointsOnReturn: Int = 0
        var serviceAttempts: Int = 0
        var returnAttempts: Int = 0
        var aces: Int = 0
        var officialAces: Bool = false
        var winners: Int = 0
        var officialWinners: Bool = false
        var unforcedErrors: Int?
        var doubleFaults: Int = 0
        var officialDoubleFaults: Bool = false
        var netPointsWon: Int?
        var netPointsPlayed: Int?
        var breakPointsFaced: Int = 0
        var breakPointsSaved: Int = 0
        var breakPointOpportunities: Int = 0
        var breakPointsConverted: Int = 0

        var servicePointsWonRatio: Double {
            serviceAttempts > 0 ? Double(pointsOnServe) / Double(serviceAttempts) : 0
        }
        var returnPointsWonRatio: Double {
            returnAttempts > 0 ? Double(pointsOnReturn) / Double(returnAttempts) : 0
        }
        var breakPointSaveRatio: Double {
            breakPointsFaced > 0 ? Double(breakPointsSaved) / Double(breakPointsFaced) : 0
        }
        var breakPointConversionRatio: Double {
            breakPointOpportunities > 0 ? Double(breakPointsConverted) / Double(breakPointOpportunities) : 0
        }
        var netPointsWonRatio: Double {
            guard let netPointsWon, let netPointsPlayed, netPointsPlayed > 0 else { return 0 }
            return Double(netPointsWon) / Double(netPointsPlayed)
        }
        var hasOfficialStats: Bool {
            officialAces
                || officialWinners
                || unforcedErrors != nil
                || officialDoubleFaults
                || netPointsWon != nil
                || netPointsPlayed != nil
        }
    }

    let player1Name: String
    let player2Name: String
    let player1: PlayerStats
    let player2: PlayerStats
    let sampleSize: Int

    /// Abaixo deste threshold as porcentagens ficam ruidosas (ex.: 100% de
    /// break points convertidos com amostra 1). Melhor omitir a superfície
    /// que induzir a números falsamente precisos.
    var isMeaningful: Bool {
        sampleSize >= 6 || player1.hasOfficialStats || player2.hasOfficialStats
    }

    static func compute(from match: TennisMatch) -> MatchStatsBreakdown {
        let player1Name = match.player1?.name ?? "Player 1"
        let player2Name = match.player2?.name ?? "Player 2"

        var p1 = PlayerStats()
        var p2 = PlayerStats()
        var pendingBreakPointReceiver: String?

        let events = match.timelineEvents.sorted { $0.timestamp < $1.timestamp }

        for event in events {
            let title = event.title.lowercased()
            let detail = event.detail.lowercased()
            let combined = "\(title) \(detail)"

            let winnerRole = resolveWinnerRole(event: event, combined: combined, p1: player1Name, p2: player2Name)
            let serverRole = event.serverName.flatMap { identifyPlayerRole($0, p1: player1Name, p2: player2Name) } ?? .unknown

            // Novo break point sinalizado — registra oportunidade e marca o
            // ponto seguinte como potencial resolução (salvo pelo saque ou
            // convertido pelo receiver).
            if combined.contains("break point"), serverRole != .unknown {
                let receiverRole: PlayerRole = serverRole == .player1 ? .player2 : .player1
                switch receiverRole {
                case .player1:
                    p1.breakPointOpportunities += 1
                    p2.breakPointsFaced += 1
                    pendingBreakPointReceiver = player1Name
                case .player2:
                    p2.breakPointOpportunities += 1
                    p1.breakPointsFaced += 1
                    pendingBreakPointReceiver = player2Name
                case .unknown:
                    break
                }
            }

            guard winnerRole != .unknown else { continue }

            switch winnerRole {
            case .player1: p1.totalPoints += 1
            case .player2: p2.totalPoints += 1
            case .unknown: break
            }

            // Ponto no saque / no retorno — atribuído somente quando o servidor
            // é identificável no evento (ou herdado do estado atual da partida).
            if serverRole != .unknown {
                switch serverRole {
                case .player1:
                    p1.serviceAttempts += 1
                    p2.returnAttempts += 1
                    if winnerRole == .player1 { p1.pointsOnServe += 1 }
                    else if winnerRole == .player2 { p2.pointsOnReturn += 1 }
                case .player2:
                    p2.serviceAttempts += 1
                    p1.returnAttempts += 1
                    if winnerRole == .player2 { p2.pointsOnServe += 1 }
                    else if winnerRole == .player1 { p1.pointsOnReturn += 1 }
                case .unknown:
                    break
                }
            }

            // Ace: heurística por keyword. Sempre atribuído ao servidor.
            if containsAceKeyword(combined) {
                switch serverRole {
                case .player1: p1.aces += 1
                case .player2: p2.aces += 1
                case .unknown:
                    // Se não temos servidor mas temos vencedor, atribuímos ao
                    // vencedor (ace só pode ser vencido pelo próprio sacador).
                    if winnerRole == .player1 { p1.aces += 1 }
                    else if winnerRole == .player2 { p2.aces += 1 }
                }
            } else if combined.contains("winner") {
                // Ganhador do rally com bola vencedora — atribuído ao vencedor
                // do ponto, não ao servidor.
                if winnerRole == .player1 { p1.winners += 1 }
                else if winnerRole == .player2 { p2.winners += 1 }
            }

            if containsDoubleFaultKeyword(combined), serverRole != .unknown {
                switch serverRole {
                case .player1: p1.doubleFaults += 1
                case .player2: p2.doubleFaults += 1
                case .unknown: break
                }
            }

            // Resolução do break point pendente.
            if let receiver = pendingBreakPointReceiver {
                let receiverWonPoint =
                    (receiver == player1Name && winnerRole == .player1) ||
                    (receiver == player2Name && winnerRole == .player2)
                if receiverWonPoint {
                    if receiver == player1Name { p1.breakPointsConverted += 1 }
                    else { p2.breakPointsConverted += 1 }
                } else {
                    // Server salvou o break point.
                    if receiver == player1Name { p2.breakPointsSaved += 1 }
                    else { p1.breakPointsSaved += 1 }
                }
                pendingBreakPointReceiver = nil
            }
        }

        if let official = match.advancedStatsSnapshot, official.hasAnyValue {
            applyOfficialStats(official.player1, to: &p1)
            applyOfficialStats(official.player2, to: &p2)
        }

        return MatchStatsBreakdown(
            player1Name: player1Name,
            player2Name: player2Name,
            player1: p1,
            player2: p2,
            sampleSize: p1.totalPoints + p2.totalPoints
        )
    }

    // MARK: - Helpers

    enum PlayerRole {
        case player1
        case player2
        case unknown
    }

    private static func resolveWinnerRole(
        event: MatchTimelineEvent,
        combined: String,
        p1: String,
        p2: String
    ) -> PlayerRole {
        if let name = event.pointWinnerName {
            let role = identifyPlayerRole(name, p1: p1, p2: p2)
            if role != .unknown { return role }
        }
        // Fallback: procura pelo nome do jogador (ou sobrenome) no texto do
        // evento. Só devolve match quando é *inequívoco* (um dos dois nomes
        // aparece e o outro não) — evita atribuições falsas quando o evento
        // menciona os dois jogadores.
        let p1Hit = mentions(name: p1, in: combined)
        let p2Hit = mentions(name: p2, in: combined)
        if p1Hit && !p2Hit { return .player1 }
        if p2Hit && !p1Hit { return .player2 }
        return .unknown
    }

    static func identifyPlayerRole(_ name: String, p1: String, p2: String) -> PlayerRole {
        if matchesName(name, target: p1) { return .player1 }
        if matchesName(name, target: p2) { return .player2 }
        return .unknown
    }

    private static func matchesName(_ candidate: String, target: String) -> Bool {
        let normalizedCandidate = normalize(candidate)
        let normalizedTarget = normalize(target)
        guard !normalizedCandidate.isEmpty, !normalizedTarget.isEmpty else { return false }
        if normalizedCandidate == normalizedTarget { return true }
        if normalizedCandidate.contains(normalizedTarget) { return true }
        if normalizedTarget.contains(normalizedCandidate) { return true }
        let candidateLast = normalizedCandidate.split(separator: " ").last.map(String.init) ?? normalizedCandidate
        let targetLast = normalizedTarget.split(separator: " ").last.map(String.init) ?? normalizedTarget
        return candidateLast == targetLast
    }

    private static func mentions(name: String, in text: String) -> Bool {
        let normalizedName = normalize(name)
        guard !normalizedName.isEmpty else { return false }
        let normalizedText = normalize(text)
        if normalizedText.contains(normalizedName) { return true }
        if let last = normalizedName.split(separator: " ").last {
            return normalizedText.contains(String(last))
        }
        return false
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAceKeyword(_ text: String) -> Bool {
        // Match "ace" apenas como palavra isolada ou início de string —
        // evita capturar "space", "place", "raça", etc.
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if token == "ace" || token == "aces" { return true }
        }
        return false
    }

    private static func containsDoubleFaultKeyword(_ text: String) -> Bool {
        text.contains("double fault") || text.contains("dupla falta")
    }

    private static func applyOfficialStats(_ official: AdvancedMatchStatsSnapshot.PlayerStats, to stats: inout PlayerStats) {
        if let aces = official.aces {
            stats.aces = aces
            stats.officialAces = true
        }
        if let winners = official.winners {
            stats.winners = winners
            stats.officialWinners = true
        }
        if let unforcedErrors = official.unforcedErrors {
            stats.unforcedErrors = unforcedErrors
        }
        if let doubleFaults = official.doubleFaults {
            stats.doubleFaults = doubleFaults
            stats.officialDoubleFaults = true
        }
        if let netPointsWon = official.netPointsWon {
            stats.netPointsWon = netPointsWon
        }
        if let netPointsPlayed = official.netPointsPlayed {
            stats.netPointsPlayed = netPointsPlayed
        }
    }
}
