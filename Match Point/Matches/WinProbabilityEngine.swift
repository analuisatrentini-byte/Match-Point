import Foundation

// MARK: - WinProbabilityEstimate
//
// Estima probabilidade ao vivo de vitória de cada jogador a partir do estado
// atual da partida — placar de sets, games do set corrente, servidor atual e
// momentum recente. É um modelo heurístico transparente, não um ML treinado:
// prioriza interpretabilidade a acurácia máxima. Cada componente é isolado
// para que o card na UI possa mostrar o "porquê" da probabilidade.
//
// Referências de calibração (probabilidades ATP/WTA reais aproximadas):
//  - Best of 3, 1-0 em sets → líder ~75%.
//  - Best of 5, 2-0 em sets → líder ~88%.
//  - Servidor confirmando saque no tour masculino → ~80% de hold rate.
//
// Escolhas de design:
//  - Nunca extrapola pra 0% ou 100%. Uma partida ao vivo sempre tem incerteza
//    (lesão, tiebreak, etc). Clamp em [5%, 95%].
//  - Só computa quando há dados suficientes (`match.isLive` + `hasSets` OU
//    ao menos game score do set corrente).
//  - `momentumComponent` é isolado pra o card mostrar direção da tendência
//    (arrow up/down).

struct WinProbabilityEstimate {
    /// Probabilidade absoluta de vitória do jogador 1 (0.0 a 1.0).
    let player1Probability: Double
    /// Probabilidade absoluta de vitória do jogador 2 (soma com player1 = 1.0).
    let player2Probability: Double
    /// Componente do modelo que vem do placar de sets — dominante quando um
    /// jogador está à frente por sets.
    let baselineComponent: Double
    /// Contribuição do momentum recente (positivo = favorece player1).
    let momentumComponent: Double
    /// Rótulo curto explicando o principal driver ("Vencendo por sets", "Break
    /// de vantagem no 2º set", "Momentum recente").
    let primaryDriver: String
    /// True quando a partida é melhor de 5 sets (Grand Slam masculino).
    let bestOfFive: Bool

    var player1Percent: Int { Int((player1Probability * 100).rounded()) }
    var player2Percent: Int { Int((player2Probability * 100).rounded()) }

    static func compute(from match: TennisMatch) -> WinProbabilityEstimate? {
        // Só mostra probabilidade quando faz sentido — durante o jogo.
        guard match.isLive else { return nil }

        let bestOfFive = match.tournament?.isMajor == true
        let scoreboard = MatchScoreboardData(score: match.score)
        let setsWon = scoreboard.setsWonByPlayer

        // Sem sets nem game score, o modelo não tem sinal — retorna nil pra
        // UI mostrar placeholder em vez de 50/50 sem contexto.
        let hasCurrentSetData = !match.gameScore.isEmpty
        guard scoreboard.hasSets || hasCurrentSetData else { return nil }

        // 1. Baseline vem do placar de sets já disputados (lookup exato pros
        //    combos comuns; fórmula aproximada pra placares raros).
        let baseline = baselineFromSets(
            player1: setsWon.player1,
            player2: setsWon.player2,
            bestOfFive: bestOfFive
        )

        // 2. Ajuste pelo set corrente — os games ainda não decidiram nada, mas
        //    dão sinal proporcional. Espaço restante = 25% (deixando 5% pra
        //    momentum e mantendo baseline dominante).
        let currentSetAdjustment = currentSetAdjustment(
            gameScore: match.gameScore,
            serverName: match.serverName,
            player1Name: match.player1?.name ?? "",
            player2Name: match.player2?.name ?? "",
            pointScore: match.pointScore
        )

        // 3. Momentum dos últimos ~6 pontos — swing pequeno mas visível.
        let momentum = momentumFromTimeline(
            events: match.timelineEvents,
            player1Name: match.player1?.name ?? "",
            player2Name: match.player2?.name ?? ""
        )

        let raw = baseline + currentSetAdjustment + momentum
        let clamped = min(0.95, max(0.05, raw))

        let driver = describeDriver(
            baseline: baseline,
            setsWon: setsWon,
            currentSetAdjustment: currentSetAdjustment,
            momentum: momentum,
            gameScore: match.gameScore,
            serverName: match.serverName
        )

        return WinProbabilityEstimate(
            player1Probability: clamped,
            player2Probability: 1.0 - clamped,
            baselineComponent: baseline,
            momentumComponent: momentum,
            primaryDriver: driver,
            bestOfFive: bestOfFive
        )
    }

    // MARK: - Baseline por placar de sets

    private static func baselineFromSets(player1: Int, player2: Int, bestOfFive: Bool) -> Double {
        // Tabela calibrada informalmente contra probabilidades observadas em
        // partidas ATP/WTA. Diferenças de 1 set são valiosas mas não decisivas
        // (~76% no BO3, ~66% no BO5 porque restam mais sets pra virada).
        if bestOfFive {
            switch (player1, player2) {
            case (0, 0): return 0.50
            case (1, 0): return 0.66
            case (0, 1): return 0.34
            case (2, 0): return 0.88
            case (0, 2): return 0.12
            case (1, 1): return 0.50
            case (2, 1): return 0.74
            case (1, 2): return 0.26
            case (2, 2): return 0.50
            default: return 0.50
            }
        } else {
            switch (player1, player2) {
            case (0, 0): return 0.50
            case (1, 0): return 0.76
            case (0, 1): return 0.24
            case (1, 1): return 0.50
            default: return 0.50
            }
        }
    }

    // MARK: - Ajuste do set corrente

    private static func currentSetAdjustment(
        gameScore: String,
        serverName: String,
        player1Name: String,
        player2Name: String,
        pointScore: String
    ) -> Double {
        guard let (p1Games, p2Games) = parseGamePair(gameScore) else { return 0 }
        let margin = p1Games - p2Games

        // Cada game de vantagem no set corrente vale ~4% na probabilidade final.
        // Cap em ±16% pra não sobrepor totalmente o baseline.
        var adjustment = Double(margin) * 0.04
        adjustment = max(-0.16, min(0.16, adjustment))

        // Servidor tem vantagem estatística nos próximos pontos (~+3%).
        let serverBonus = serverBonusValue(
            serverName: serverName,
            player1Name: player1Name,
            player2Name: player2Name
        )
        adjustment += serverBonus

        // Break point situation: se o servidor está enfrentando break point,
        // o receiver ganha um empurrão temporário.
        adjustment += breakPointModifier(
            pointScore: pointScore,
            serverName: serverName,
            player1Name: player1Name,
            player2Name: player2Name
        )

        return adjustment
    }

    private static func parseGamePair(_ raw: String) -> (Int, Int)? {
        let parts = raw
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    private static func serverBonusValue(
        serverName: String,
        player1Name: String,
        player2Name: String
    ) -> Double {
        let trimmed = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if matchesName(trimmed, target: player1Name) { return 0.03 }
        if matchesName(trimmed, target: player2Name) { return -0.03 }
        return 0
    }

    private static func breakPointModifier(
        pointScore: String,
        serverName: String,
        player1Name: String,
        player2Name: String
    ) -> Double {
        // Detecta "0-40", "15-40", "30-40" ou vantagem do receiver.
        let parts = pointScore
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard parts.count == 2 else { return 0 }
        let order = ["0", "15", "30", "40", "A", "AD"]
        guard let serverIdx = order.firstIndex(of: parts[0]),
              let receiverIdx = order.firstIndex(of: parts[1]) else { return 0 }
        // Break point = receiver ≥ 40 (index 3) e à frente do servidor.
        guard receiverIdx >= 3, receiverIdx > serverIdx else { return 0 }

        // O receiver ganha um empurrão de +5% na direção dele.
        let trimmed = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if matchesName(trimmed, target: player1Name) { return -0.05 }
        if matchesName(trimmed, target: player2Name) { return 0.05 }
        return 0
    }

    // MARK: - Momentum

    private static func momentumFromTimeline(
        events: [MatchTimelineEvent],
        player1Name: String,
        player2Name: String
    ) -> Double {
        let recent = events
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
        guard !recent.isEmpty else { return 0 }

        var p1 = 0
        var p2 = 0
        for event in recent {
            guard let winner = event.pointWinnerName else { continue }
            if matchesName(winner, target: player1Name) { p1 += 1 }
            else if matchesName(winner, target: player2Name) { p2 += 1 }
        }
        let total = p1 + p2
        guard total > 0 else { return 0 }

        // Ratio -1..+1 do lado do p1, escalado pra ±5% na probabilidade.
        let ratio = Double(p1 - p2) / Double(total)
        return ratio * 0.05
    }

    // MARK: - Descrição do driver principal

    private static func describeDriver(
        baseline: Double,
        setsWon: MatchScoreboardData.PlayerPair,
        currentSetAdjustment: Double,
        momentum: Double,
        gameScore: String,
        serverName: String
    ) -> String {
        // Prioriza o driver de maior magnitude — o card mostra "o que está
        // pesando mais agora" pro leitor entender o número.
        let baselineWeight = abs(baseline - 0.5)
        let currentWeight = abs(currentSetAdjustment)
        let momentumWeight = abs(momentum)

        if baselineWeight >= currentWeight, baselineWeight >= momentumWeight, baselineWeight > 0.02 {
            let diff = setsWon.player1 - setsWon.player2
            if diff > 0 { return "Vencendo por sets (\(setsWon.player1)-\(setsWon.player2))" }
            if diff < 0 { return "Vencendo por sets (\(setsWon.player2)-\(setsWon.player1))" }
            return "Sets empatados"
        }
        if currentWeight >= momentumWeight, currentWeight > 0.02 {
            if !gameScore.isEmpty { return "Vantagem no set corrente (\(gameScore))" }
            if !serverName.isEmpty { return "Saque de \(serverName)" }
            return "Ajuste do set corrente"
        }
        if momentumWeight > 0.01 {
            return momentum > 0 ? "Momentum recente favorável ao jogador 1"
                                : "Momentum recente favorável ao jogador 2"
        }
        return "Partida equilibrada"
    }

    // MARK: - Name matching

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

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
