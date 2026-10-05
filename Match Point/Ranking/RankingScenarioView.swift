import SwiftUI
import SwiftData

/// Interactive "what if?" simulator for a tournament's remaining matches.
/// Users toggle a hypothetical winner per match; the sheet recomputes projected
/// ranking movements in real time using `RankingProjectionEngine.projectScenario`.
struct RankingScenarioView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var picks: [UUID: UUID] = [:]

    let tournament: Tournament
    let tournamentMatches: [TennisMatch]

    private var scenarioMatches: [TennisMatch] {
        tournamentMatches
            .filter { $0.player1 != nil && $0.player2 != nil }
            .filter { !$0.isCompleted }
            .sorted { $0.date < $1.date }
    }

    private var tourRankings: [RankingEntry] {
        rankings.filter { $0.tour == tournament.tour }
    }

    private var assumptions: [RankingScenarioAssumption] {
        scenarioMatches.compactMap { match -> RankingScenarioAssumption? in
            guard
                let winnerID = picks[match.id],
                let player1 = match.player1,
                let player2 = match.player2
            else { return nil }

            let winnerName: String
            let loserID: UUID
            let loserName: String
            if winnerID == player1.id {
                winnerName = player1.name
                loserID = player2.id
                loserName = player2.name
            } else if winnerID == player2.id {
                winnerName = player2.name
                loserID = player1.id
                loserName = player1.name
            } else {
                return nil
            }

            let round = MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches)
            return RankingScenarioAssumption(
                id: match.id,
                round: round,
                winnerID: winnerID,
                winnerName: winnerName,
                loserID: loserID,
                loserName: loserName,
                tournamentName: tournament.name,
                tournamentExternalKey: tournament.externalKey,
                tournamentIsMajor: tournament.isMajor
            )
        }
    }

    private var projections: [RankingScenarioProjection] {
        RankingProjectionEngine.projectScenario(
            assumptions: assumptions,
            rankings: tourRankings
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    projectionCard
                    matchesCard
                }
                .padding()
            }
            .appleSportsBackground(.clay)
            .navigationTitle(String(localized: "E se?"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Zerar") { picks.removeAll() }
                        .disabled(picks.isEmpty)
                        .accessibilityIdentifier("ranking-scenario-reset")
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Simulador de cenários", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline.weight(.bold))
                .foregroundStyle(.teal)
            Text(tournament.name)
                .font(.title3.weight(.heavy))
            Text(Self.localized("Escolha um vencedor por partida restante — projetamos como isso muda o ranking %@.", tournament.tour == .atp ? "ATP" : "WTA"))
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Projection card

    private var projectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Projeção", systemImage: "arrow.up.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.teal)
                Spacer()
                Text(Self.localized("%d suposições", picks.count))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
            }

            if projections.isEmpty {
                Text(picks.isEmpty
                     ? String(localized: "Escolha um vencedor abaixo para ver o impacto no ranking.")
                     : String(localized: "Nenhuma mudança projetada nas posições atuais."))
                    .font(.subheadline)
                    .foregroundStyle(Color.readableSecondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(projections.prefix(8).enumerated()), id: \.element.id) { index, projection in
                        projectionRow(projection)
                        if index < min(projections.count, 8) - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                        }
                    }
                }
                .accessibilityIdentifier("ranking-scenario-projection-list")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func projectionRow(_ projection: RankingScenarioProjection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(projection.playerName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("#\(projection.currentRank)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.readableSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.readableSecondary)
                    Text("#\(projection.projectedRank)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(rankTint(for: projection))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(rankDeltaLabel(for: projection))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(rankTint(for: projection))
                if projection.pointsDelta != 0 {
                    Text(pointsDeltaLabel(for: projection))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.readableSecondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func rankTint(for projection: RankingScenarioProjection) -> Color {
        if projection.rankDelta > 0 { return .green }
        if projection.rankDelta < 0 { return .orange }
        return .secondary
    }

    private func rankDeltaLabel(for projection: RankingScenarioProjection) -> String {
        if projection.rankDelta > 0 { return "▲ \(projection.rankDelta)" }
        if projection.rankDelta < 0 { return "▼ \(abs(projection.rankDelta))" }
        return "="
    }

    private func pointsDeltaLabel(for projection: RankingScenarioProjection) -> String {
        let sign = projection.pointsDelta >= 0 ? "+" : ""
        return Self.localized("%@%d pts", sign, projection.pointsDelta)
    }

    // MARK: - Matches card

    private var matchesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Partidas em aberto", systemImage: "sportscourt")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.teal)
                Spacer()
                if !scenarioMatches.isEmpty {
                    Text(Self.localized("%d jogos", scenarioMatches.count))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                }
            }

            if scenarioMatches.isEmpty {
                Text("Nenhum jogo pendente com dois jogadores definidos.")
                    .font(.subheadline)
                    .foregroundStyle(Color.readableSecondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(scenarioMatches) { match in
                        matchRow(match)
                    }
                }
                .accessibilityIdentifier("ranking-scenario-match-list")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func matchRow(_ match: TennisMatch) -> some View {
        let round = MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches)
        let selection = picks[match.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(round.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.teal)
                Text(match.date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
                Spacer(minLength: 0)
                if selection != nil {
                    Button {
                        picks[match.id] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remover suposição")
                }
            }

            HStack(spacing: 8) {
                pickButton(for: match.player1, matchID: match.id, isSelected: selection == match.player1?.id)
                pickButton(for: match.player2, matchID: match.id, isSelected: selection == match.player2?.id)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.teal.opacity(selection == nil ? 0.10 : 0.30), lineWidth: 1)
                )
        )
    }

    private static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key)), locale: .current, arguments: arguments)
    }

    private func pickButton(for player: Player?, matchID: UUID, isSelected: Bool) -> some View {
        Button {
            guard let player else { return }
            if isSelected {
                picks[matchID] = nil
            } else {
                picks[matchID] = player.id
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.heavy))
                Text(player?.name ?? String(localized: "A definir"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.black : Color.primary)
            .background(isSelected ? Color.teal : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(player == nil)
        .accessibilityIdentifier("ranking-scenario-pick-\(matchID.uuidString)-\(player?.id.uuidString ?? "tbd")")
    }
}
