import SwiftUI
import SwiftData

// MARK: - Leaderboard Hub
//
// Standalone leaderboard screen with a visual podium, week-over-week rank
// deltas, seasonal filters and a share button. Reachable from the profile
// tab, the social feed banner and share links so the ranking is never more
// than one tap away — the previous experience buried it three sections deep
// inside the profile.

struct LeaderboardHubView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloudBackend: CloudSocialBackend
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \PointBet.createdAt, order: .reverse) private var bets: [PointBet]
    @Query(sort: \TennisMatch.date, order: .reverse) private var matches: [TennisMatch]

    @State private var selectedSeason: SocialSeasonKind = .weekly
    @State private var showRecap = false

    private var profile: UserProfile? { profiles.first }

    private var selectedSocialSeason: SocialSeason {
        switch selectedSeason {
        case .weekly: return SocialSeason.weekly()
        case .monthly: return SocialSeason.monthly()
        case .slam: return SocialSeason.slam()
        }
    }

    private var predictionStats: PredictionStats {
        PredictionStats(bets: bets)
    }

    private var currentRank: Int {
        // For the cloud leaderboard we use the server-computed position.
        // For local seasons we always place the user at #1 of a one-row list
        // (they're the only local competitor).
        if !cloudBackend.leaderboard.isEmpty,
           let index = cloudBackend.leaderboard.firstIndex(where: { $0.isCurrentUser }) {
            return index + 1
        }
        return 1
    }

    private var weeklySummary: WeeklySocialSummary {
        WeeklySocialSummary(
            season: SocialSeason.weekly(),
            rank: currentRank,
            localLeaderboardCount: max(cloudBackend.leaderboard.count, 1),
            stats: predictionStats
        )
    }

    private var seasonBets: [PointBet] {
        bets.filter { selectedSocialSeason.contains($0.createdAt) }
    }

    private var seasonScore: Int {
        seasonBets.reduce(0) { partial, bet in
            switch bet.status {
            case .won: return partial + bet.payout - bet.stake
            case .lost: return partial - bet.stake
            case .open, .void: return partial
            }
        }
    }

    private var seasonBackedRows: [LeaderboardRow] {
        // Cloud leaderboard is used for the podium and full list; season
        // filter is applied only to the personal season card at the top.
        cloudBackend.leaderboard.prefix(100).enumerated().map { index, entry in
            LeaderboardRow(
                rank: index + 1,
                id: entry.id,
                name: entry.displayName,
                avatarSymbol: entry.avatarSymbol,
                points: entry.points,
                wins: entry.wins,
                losses: entry.losses,
                streak: entry.currentStreak,
                isCurrentUser: entry.isCurrentUser,
                winRateText: entry.winRateText
            )
        }
    }

    private var localFallbackRows: [LeaderboardRow] {
        let localRows = SocialRankingBuilder.weeklyRows(
            profile: profile,
            bets: bets,
            matches: matches
        )
        return localRows.enumerated().map { index, row in
            LeaderboardRow(
                rank: index + 1,
                id: "local-\(index)-\(row.name)",
                name: row.name,
                avatarSymbol: profile?.avatarSymbol ?? "person.crop.circle",
                points: row.points,
                wins: predictionStats.won,
                losses: predictionStats.lost,
                streak: predictionStats.currentStreak,
                isCurrentUser: row.isCurrentUser,
                winRateText: predictionStats.accuracyText
            )
        }
    }

    private var rows: [LeaderboardRow] {
        seasonBackedRows.isEmpty ? localFallbackRows : seasonBackedRows
    }

    private var sourceKey: String {
        seasonBackedRows.isEmpty ? "local" : cloudBackend.leaderboardSource.label
    }

    private var previousRank: Int? {
        LeaderboardHistoryStore.previousRank(seasonKind: selectedSeason, source: sourceKey)
    }

    private var rankDelta: Int? {
        guard let previousRank else { return nil }
        return previousRank - currentRank
    }

    private var podium: [LeaderboardRow] {
        Array(rows.prefix(3))
    }

    private var tail: [LeaderboardRow] {
        rows.dropFirst(3).map { $0 }
    }

    var body: some View {
        List {
            Section {
                seasonPicker
                    .appListPlainRow()
            }

            Section {
                positionCard
                    .appListCardRow(cornerRadius: 22, padding: 18)
            }

            Section("Pódio") {
                if podium.isEmpty {
                    ContentUnavailableView(
                        "Ranking indisponível",
                        systemImage: "trophy",
                        description: Text("Crie previsões para abrir sua temporada social.")
                    )
                    .appListCardRow()
                } else {
                    podiumStrip
                        .appListCardRow(cornerRadius: 22, padding: 12)
                }
            }

            Section {
                sourceRow
                    .appListCardRow()
                if !tail.isEmpty {
                    ForEach(tail) { row in
                        leaderboardRow(row)
                            .appListCardRow()
                    }
                }
            } header: {
                Text("Ranking completo")
            }

            Section("Resumo da liga") {
                Button {
                    showRecap = true
                } label: {
                    Label("Ver resumo semanal", systemImage: "chart.bar.doc.horizontal")
                }
                .appListCardRow()
                .accessibilityIdentifier("leaderboard-open-recap")
                shareLeaderboardButton
                    .appListCardRow()
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Ranking social")
        .accessibilityIdentifier("leaderboard-hub-screen")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            await refreshCloud()
            recordCurrentSnapshot()
        }
        .refreshable {
            await refreshCloud()
            recordCurrentSnapshot()
        }
        .sheet(isPresented: $showRecap) {
            if let profile {
                NavigationStack {
                    WeeklyRecapView(
                        profile: profile,
                        bets: bets,
                        matches: matches,
                        rank: currentRank,
                        cloudLeaderboardCount: cloudBackend.leaderboard.count
                    )
                }
            }
        }
    }

    private var seasonPicker: some View {
        Picker("Temporada", selection: $selectedSeason) {
            ForEach(SocialSeasonKind.allCases) { kind in
                Text(kind.shortLabel).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("leaderboard-season-picker")
    }

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedSocialSeason.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    Text(profile?.displayName ?? "Você")
                        .font(.title3.weight(.heavy))
                    HStack(spacing: 6) {
                        Text("#\(currentRank)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.green)
                        deltaBadge
                    }
                    Text(weeklySummary.weeklyReadLine)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
                Image(systemName: currentRank <= 3 ? "trophy.fill" : "figure.tennis")
                    .font(.title.weight(.bold))
                    .foregroundStyle(currentRank <= 3 ? .yellow : .green)
            }

            HStack(spacing: 10) {
                leaderboardMetric(title: "Season", value: signed(seasonScore), tint: .blue)
                leaderboardMetric(title: "Acerto", value: predictionStats.accuracyText, tint: .green)
                leaderboardMetric(title: "Streak", value: "\(predictionStats.currentStreak)", tint: .orange)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("leaderboard-position-card")
    }

    @ViewBuilder
    private var deltaBadge: some View {
        if let delta = rankDelta {
            let (symbol, tint, text): (String, Color, String) = {
                if delta > 0 { return ("arrow.up", .green, "+\(delta)") }
                if delta < 0 { return ("arrow.down", .red, "\(delta)") }
                return ("equal", .secondary, "0")
            }()
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(text)
                    .monospacedDigit()
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityLabel(text.appending(" posições desde a última visita"))
        } else {
            Text("Primeira leitura")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func leaderboardMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var podiumStrip: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if podium.count >= 2 { podiumCard(podium[1], place: 2) }
            if podium.count >= 1 { podiumCard(podium[0], place: 1) }
            if podium.count >= 3 { podiumCard(podium[2], place: 3) }
        }
        .frame(maxWidth: .infinity)
    }

    private func podiumCard(_ row: LeaderboardRow, place: Int) -> some View {
        let tint: Color = {
            switch place {
            case 1: return .yellow
            case 2: return Color(red: 0.75, green: 0.75, blue: 0.85)
            case 3: return Color(red: 0.80, green: 0.53, blue: 0.32)
            default: return .green
            }
        }()
        let height: CGFloat = place == 1 ? 150 : place == 2 ? 130 : 115
        return VStack(spacing: 8) {
            Image(systemName: row.avatarSymbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.18))
                .clipShape(Circle())
            Text(row.name)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(row.points) pts")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(row.isCurrentUser ? .green : Color.readableSecondary)
            Spacer(minLength: 0)
            Text("#\(place)")
                .font(.title2.monospacedDigit().weight(.black))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(tint.opacity(0.15))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .padding(.top, 8)
        .background(row.isCurrentUser ? Color.green.opacity(0.12) : Color.cardSurface)
        .overlay(alignment: .top) {
            if row.isCurrentUser {
                Text("VOCÊ")
                    .font(.caption2.weight(.black))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.20), in: Capsule())
                    .padding(.top, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pódio posição \(place), \(row.name), \(row.points) pontos")
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: cloudBackend.leaderboardSource.isProductionGrade ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(cloudBackend.leaderboardSource.isProductionGrade ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(cloudBackend.leaderboardSource.label)
                    .font(.subheadline.weight(.semibold))
                Text(cloudBackend.leaderboardSource.isProductionGrade
                     ? "Ranking oficial atualizado."
                     : "Ranking temporário até a próxima atualização oficial.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    private func leaderboardRow(_ row: LeaderboardRow) -> some View {
        HStack(spacing: 10) {
            Text("#\(row.rank)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 36, alignment: .leading)
                .foregroundStyle(row.rank <= 3 ? .yellow : Color.readableSecondary)

            Image(systemName: row.avatarSymbol)
                .foregroundStyle(row.isCurrentUser ? .green : .primary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(row.isCurrentUser ? .headline : .body)
                HStack(spacing: 6) {
                    Text(row.winRateText)
                    Text("•")
                    Text("\(row.wins)V \(row.losses)D")
                    if row.streak >= 2 {
                        Text("•")
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                            Text("\(row.streak)")
                        }
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.readableSecondary)
            }

            Spacer()

            Text("\(row.points) pts")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(row.isCurrentUser ? .green : Color.readableSecondary)
        }
        .accessibilityIdentifier("leaderboard-hub-row")
    }

    @ViewBuilder
    private var shareLeaderboardButton: some View {
        let podiumSummary = podium.prefix(3)
            .map { "#\($0.rank) \($0.name) — \($0.points) pts" }
            .joined(separator: "\n")
        let text = """
        Ranking Match Point — \(selectedSocialSeason.title)
        \(podiumSummary)

        Estou em #\(currentRank) esta \(selectedSeason == .weekly ? "semana" : "temporada"). \(weeklySummary.weeklyReadLine)
        """
        ShareLink(item: text) {
            Label("Compartilhar ranking", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("leaderboard-share")
    }

    private func recordCurrentSnapshot() {
        LeaderboardHistoryStore.recordCurrent(
            seasonKind: selectedSeason,
            source: sourceKey,
            rank: currentRank
        )
    }

    private func refreshCloud() async {
        await cloudBackend.refreshAccountStatus()
        await cloudBackend.refreshAll()
        if let profile {
            let performance = CloudTipsterPerformance(
                wins: predictionStats.won,
                losses: predictionStats.lost,
                currentStreak: predictionStats.currentStreak
            )
            await cloudBackend.syncProfile(profile, performance: performance)
        }
    }

    private func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }
}

struct LeaderboardRow: Identifiable, Equatable {
    let rank: Int
    let id: String
    let name: String
    let avatarSymbol: String
    let points: Int
    let wins: Int
    let losses: Int
    let streak: Int
    let isCurrentUser: Bool
    let winRateText: String
}
