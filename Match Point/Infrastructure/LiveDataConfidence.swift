import Foundation

struct LiveDataConfidence: Equatable {
    enum Status: Equatable {
        case verified
        case estimated
        case stale
        case conflicted
    }

    let status: Status
    let checkedAt: Date?
    let message: String

    var label: String {
        switch status {
        case .verified:
            return "Verificado"
        case .estimated:
            return "Estimado"
        case .stale:
            return "Atrasado"
        case .conflicted:
            return "Conflito"
        }
    }

    var systemImage: String {
        switch status {
        case .verified:
            return "checkmark.seal.fill"
        case .estimated:
            return "waveform.path.ecg"
        case .stale:
            return "clock.badge.exclamationmark"
        case .conflicted:
            return "exclamationmark.triangle.fill"
        }
    }

    static func realtimeUpdated(at date: Date) -> LiveDataConfidence {
        LiveDataConfidence(
            status: .estimated,
            checkedAt: date,
            message: "Recebido via WebSocket; aguardando conferência REST."
        )
    }

    static func verified(at date: Date) -> LiveDataConfidence {
        LiveDataConfidence(
            status: .verified,
            checkedAt: date,
            message: "WebSocket e REST concordam no placar atual."
        )
    }

    static func stale(lastUpdatedAt: Date?, now: Date = .now) -> LiveDataConfidence {
        let age = lastUpdatedAt.map { Int(now.timeIntervalSince($0)) }
        let ageText = age.map { "há \($0)s" } ?? "sem horário recente"
        return LiveDataConfidence(
            status: .stale,
            checkedAt: now,
            message: "Sem atualização live \(ageText); exibindo último placar conhecido."
        )
    }

    static func conflicted(local: LiveScoreSnapshot, remote: LiveScoreSnapshot, at date: Date) -> LiveDataConfidence {
        LiveDataConfidence(
            status: .conflicted,
            checkedAt: date,
            message: "REST diverge do WebSocket: \(local.summary) vs \(remote.summary)."
        )
    }

    static func bestEffort(for match: TennisMatch, serviceConfidence: LiveDataConfidence?, now: Date = .now) -> LiveDataConfidence {
        if let serviceConfidence {
            return serviceConfidence
        }
        guard match.isLive else {
            return LiveDataConfidence(status: .verified, checkedAt: match.lastUpdatedAt, message: "Partida fora do modo live.")
        }
        guard let lastUpdatedAt = match.lastUpdatedAt else {
            return LiveDataConfidence(status: .estimated, checkedAt: nil, message: "Placar ao vivo sem horário de atualização.")
        }
        if now.timeIntervalSince(lastUpdatedAt) > 30 {
            return stale(lastUpdatedAt: lastUpdatedAt, now: now)
        }
        return LiveDataConfidence(status: .estimated, checkedAt: lastUpdatedAt, message: "Placar recente, ainda sem confirmação cruzada.")
    }
}

struct LiveScoreSnapshot: Equatable {
    let score: String
    let gameScore: String
    let pointScore: String
    let serverName: String

    init(score: String, gameScore: String, pointScore: String, serverName: String) {
        self.score = Self.normalized(score)
        self.gameScore = Self.normalized(gameScore)
        self.pointScore = Self.normalized(pointScore)
        self.serverName = Self.normalized(serverName)
    }

    init(match: TennisMatch) {
        self.init(
            score: match.score,
            gameScore: match.gameScore,
            pointScore: match.pointScore,
            serverName: match.serverName
        )
    }

    init(dto: MatchDTO) {
        self.init(
            score: dto.score,
            gameScore: dto.gameScore,
            pointScore: dto.pointScore,
            serverName: dto.serverName
        )
    }

    var summary: String {
        [score, gameScore, pointScore, serverName].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    func materiallyMatches(_ other: LiveScoreSnapshot) -> Bool {
        Self.matches(score, other.score)
            && Self.matches(gameScore, other.gameScore)
            && Self.matches(pointScore, other.pointScore)
            && Self.matches(serverName, other.serverName)
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.isEmpty || rhs.isEmpty || lhs == rhs
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .lowercased()
    }
}
