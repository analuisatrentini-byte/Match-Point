import SwiftUI
import SwiftData

// MARK: - Weekly Recap
//
// Multi-metric weekly summary sheet. Surfaces the "você leu melhor que X%"
// headline as a full card plus a scrollable stack of insight cards (streak,
// points, best pick, favorite tournament) and the badges the user earned in
// the window. Shareable as text so users can post the recap directly.

struct WeeklyRecapView: View {
    let profile: UserProfile
    let bets: [PointBet]
    let matches: [TennisMatch]
    let rank: Int
    let cloudLeaderboardCount: Int

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Player.name) private var players: [Player]

    private var favoritePlayers: [Player] {
        players.filter(\.isFavorite)
    }

    private var stats: PredictionStats {
        PredictionStats(bets: bets)
    }

    private var summary: WeeklySocialSummary {
        WeeklySocialSummary(
            season: SocialSeason.weekly(),
            rank: rank,
            localLeaderboardCount: max(cloudLeaderboardCount, 1),
            stats: stats
        )
    }

    private var insights: [WeeklyInsight] {
        WeeklyInsightsBuilder.insights(
            summary: summary,
            bets: bets,
            matches: matches,
            favoritePlayers: favoritePlayers
        )
    }

    private var badges: [SocialBadge] {
        BadgeCatalog.badges(
            bets: bets,
            favoritePlayers: favoritePlayers,
            matches: matches,
            profile: profile,
            stats: stats
        )
    }

    private var earnedBadges: [SocialBadge] {
        badges.filter(\.isUnlocked)
    }

    private var nextBadges: [SocialBadge] {
        badges.filter { !$0.isUnlocked }
            .sorted { $0.progress > $1.progress }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        List {
            Section {
                headerCard
                    .appListCardRow(cornerRadius: 22, padding: 18)
            }

            Section("Sua leitura") {
                ForEach(insights) { insight in
                    insightRow(insight)
                        .appListCardRow()
                }
            }

            if !earnedBadges.isEmpty {
                Section("Conquistas ativas") {
                    LazyVGrid(columns: badgeColumns, spacing: 10) {
                        ForEach(earnedBadges.prefix(6)) { badge in
                            BadgeChip(badge: badge)
                        }
                    }
                    .padding(.vertical, 4)
                    .appListCardRow()
                }
            }

            if !nextBadges.isEmpty {
                Section {
                    ForEach(nextBadges) { badge in
                        BadgeProgressRow(badge: badge)
                            .appListCardRow()
                    }
                } header: {
                    Text("Próximas conquistas")
                } footer: {
                    Text("Continue prevendo para completar essas metas.")
                }
            }

            Section {
                shareButton
                    .appListCardRow()
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.midnight)
        .navigationTitle("Resumo semanal")
        .accessibilityIdentifier("weekly-recap-screen")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fechar") { dismiss() }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary.season.title.uppercased())
                .font(.caption.weight(.black))
                .foregroundStyle(Color.readableSecondary)
            Text(summary.weeklyReadLine)
                .font(.title2.weight(.heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text(summary.season.subtitle)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            HStack(spacing: 10) {
                metricPill(title: "#\(rank)", subtitle: "Ranking", tint: .green)
                metricPill(title: "\(stats.currentStreak)", subtitle: "Streak", tint: .orange)
                metricPill(title: signed(stats.weeklyNetPoints), subtitle: "Semana", tint: .blue)
            }
        }
        .padding(.vertical, 8)
    }

    private func metricPill(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(subtitle.uppercased())
                .font(.caption2.weight(.black))
                .foregroundStyle(Color.readableSecondary)
            Text(title)
                .font(.headline.monospacedDigit().weight(.heavy))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func insightRow(_ insight: WeeklyInsight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.systemImage)
                .font(.title3)
                .foregroundStyle(insight.tint.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.subheadline.weight(.semibold))
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            Spacer()
            Text(insight.value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(insight.tint.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.title). \(insight.value). \(insight.detail)")
        .accessibilityIdentifier("weekly-recap-insight-\(insight.id)")
    }

    private var badgeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 120), spacing: 10)]
    }

    private var shareButton: some View {
        let text = """
        \(summary.season.title)
        \(summary.weeklyReadLine)
        Ranking: #\(rank) • Streak: \(stats.currentStreak) • Acerto: \(stats.accuracyText)
        \(signed(stats.weeklyNetPoints)) pts na semana.
        """
        return ShareLink(item: text) {
            Label("Compartilhar resumo", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("weekly-recap-share")
    }

    private func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }
}

struct BadgeChip: View {
    let badge: SocialBadge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: badge.systemImage)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(badge.tier.color)
                Text(badge.tier.label.uppercased())
                    .font(.caption2.weight(.black))
                    .foregroundStyle(badge.tier.color)
            }
            Text(badge.title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(badge.description)
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(badge.tier.color.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityLabel)
    }
}

struct BadgeProgressRow: View {
    let badge: SocialBadge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: badge.systemImage)
                    .foregroundStyle(badge.tier.color)
                Text(badge.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(badge.progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
            }
            ProgressView(value: badge.progress)
                .tint(badge.tier.color)
            Text(badge.description)
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(badge.accessibilityLabel)
    }
}
