import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Seasons

/// Kinds of concurrent social seasons the app tracks. Weekly is the primary
/// grid (used by leaderboard + weekly recap). Monthly adds a longer horizon.
/// `slam` reflects the Grand Slam calendar overlay already used by the
/// `AppleSportsBackground` slam theming — it lets the leaderboard pin an
/// active tournament season when one is running.
enum SocialSeasonKind: String, CaseIterable, Identifiable {
    case weekly
    case monthly
    case slam

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .weekly: return "Semana"
        case .monthly: return "Mês"
        case .slam: return "Torneio"
        }
    }
}

struct SocialSeason: Equatable {
    let kind: SocialSeasonKind
    let title: String
    let subtitle: String
    let startsAt: Date
    let endsAt: Date

    static func current(now: Date = .now, calendar: Calendar = .current) -> SocialSeason {
        weekly(now: now, calendar: calendar)
    }

    static func weekly(now: Date = .now, calendar: Calendar = .current) -> SocialSeason {
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
        let startsAt = interval?.start ?? now
        let endsAt = interval?.end ?? calendar.date(byAdding: .day, value: 7, to: startsAt) ?? now
        let week = calendar.component(.weekOfYear, from: now)
        return SocialSeason(
            kind: .weekly,
            title: "Temporada semanal #\(week)",
            subtitle: "\(startsAt.formatted(date: .abbreviated, time: .omitted)) - \(endsAt.formatted(date: .abbreviated, time: .omitted))",
            startsAt: startsAt,
            endsAt: endsAt
        )
    }

    static func monthly(now: Date = .now, calendar: Calendar = .current) -> SocialSeason {
        let interval = calendar.dateInterval(of: .month, for: now)
        let startsAt = interval?.start ?? now
        let endsAt = interval?.end ?? calendar.date(byAdding: .month, value: 1, to: startsAt) ?? now
        let monthName = startsAt.formatted(.dateTime.month(.wide).year())
        return SocialSeason(
            kind: .monthly,
            title: "Temporada mensal • \(monthName.capitalized)",
            subtitle: "\(startsAt.formatted(date: .abbreviated, time: .omitted)) - \(endsAt.formatted(date: .abbreviated, time: .omitted))",
            startsAt: startsAt,
            endsAt: endsAt
        )
    }

    /// Returns the Grand Slam season if one is currently active (year-agnostic
    /// windows from `SlamSeason.current(for:)`). Falls back to a generic
    /// "Temporada aberta" placeholder when no slam is in phase.
    static func slam(now: Date = .now, calendar: Calendar = .current) -> SocialSeason {
        if let slam = SlamSeason.current(for: now, calendar: calendar) {
            let window = slam.window(around: now, calendar: calendar)
            return SocialSeason(
                kind: .slam,
                title: "Temporada \(slam.label)",
                subtitle: "\(window.startsAt.formatted(date: .abbreviated, time: .omitted)) - \(window.endsAt.formatted(date: .abbreviated, time: .omitted))",
                startsAt: window.startsAt,
                endsAt: window.endsAt
            )
        }
        let interval = calendar.dateInterval(of: .quarter, for: now)
        let startsAt = interval?.start ?? now
        let endsAt = interval?.end ?? calendar.date(byAdding: .month, value: 3, to: startsAt) ?? now
        return SocialSeason(
            kind: .slam,
            title: "Temporada aberta",
            subtitle: "\(startsAt.formatted(date: .abbreviated, time: .omitted)) - \(endsAt.formatted(date: .abbreviated, time: .omitted))",
            startsAt: startsAt,
            endsAt: endsAt
        )
    }

    static func all(now: Date = .now, calendar: Calendar = .current) -> [SocialSeason] {
        [.weekly(now: now, calendar: calendar), .monthly(now: now, calendar: calendar), .slam(now: now, calendar: calendar)]
    }

    /// Returns true if `date` falls inside this season's window.
    func contains(_ date: Date) -> Bool {
        date >= startsAt && date < endsAt
    }
}

private extension SlamSeason {
    struct Window {
        let startsAt: Date
        let endsAt: Date
    }

    /// Returns a windowed date range that maps this slam's year-agnostic phase
    /// onto the calendar year around `date`. Used for the seasonal social
    /// season label — we never persist this, so a simple derivation is fine.
    func window(around date: Date, calendar: Calendar) -> Window {
        let year = calendar.component(.year, from: date)
        var startComponents = DateComponents()
        startComponents.year = year
        startComponents.month = phaseStartMonth
        startComponents.day = phaseStartDay
        var endComponents = DateComponents()
        endComponents.year = year
        endComponents.month = phaseEndMonth
        endComponents.day = phaseEndDay
        let start = calendar.date(from: startComponents) ?? date
        let end = calendar.date(from: endComponents) ?? date
        return Window(startsAt: start, endsAt: end)
    }

    private var phaseStartMonth: Int {
        switch self {
        case .australianOpen: return 1
        case .rolandGarros: return 5
        case .wimbledon: return 6
        case .usOpen: return 8
        }
    }

    private var phaseStartDay: Int {
        switch self {
        case .australianOpen: return 10
        case .rolandGarros: return 15
        case .wimbledon: return 20
        case .usOpen: return 15
        }
    }

    private var phaseEndMonth: Int {
        switch self {
        case .australianOpen: return 2
        case .rolandGarros: return 6
        case .wimbledon: return 7
        case .usOpen: return 9
        }
    }

    private var phaseEndDay: Int {
        switch self {
        case .australianOpen: return 9
        case .rolandGarros: return 15
        case .wimbledon: return 20
        case .usOpen: return 20
        }
    }
}

// MARK: - Weekly summary + insights

struct WeeklySocialSummary: Equatable {
    let season: SocialSeason
    let rank: Int
    let totalPlayers: Int
    let weeklyNetPoints: Int
    let winRateText: String
    let currentStreak: Int
    let settledCount: Int
    let percentile: Int

    init(season: SocialSeason, rank: Int, localLeaderboardCount: Int, stats: PredictionStats) {
        self.season = season
        self.rank = max(1, rank)
        self.totalPlayers = max(localLeaderboardCount, 1)
        self.weeklyNetPoints = stats.weeklyNetPoints
        self.winRateText = stats.accuracyText
        self.currentStreak = stats.currentStreak
        self.settledCount = stats.won + stats.lost
        self.percentile = Self.percentile(rank: max(1, rank), totalPlayers: max(localLeaderboardCount, 1), stats: stats)
    }

    var weeklyReadLine: String {
        "Você leu melhor que \(percentile)% da liga esta semana."
    }

    var streakLine: String {
        if currentStreak >= 2 {
            return "Streak ativo de \(currentStreak) acertos"
        }
        if settledCount == 0 {
            return "Primeira leitura da semana ainda em aberto"
        }
        return "Streak pronto para reacender"
    }

    private static func percentile(rank: Int, totalPlayers: Int, stats: PredictionStats) -> Int {
        guard totalPlayers > 1 else {
            return stats.settled == 0 ? 50 : 82
        }
        let base = Double(totalPlayers - rank) / Double(totalPlayers - 1)
        let rankedPercentile = Int((base * 72).rounded()) + 18
        let confidenceBonus = min(10, stats.settled * 2)
        return min(99, max(18, rankedPercentile + confidenceBonus))
    }
}

/// Individual insights surfaced in the WeeklyRecapView. Each insight is a
/// caption/title/value trio with an icon and tint. Keeping them as a value
/// type means new insights can be composed anywhere (feed cards, share cards,
/// widgets in the future) without duplicating rendering logic.
struct WeeklyInsight: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: InsightTint

    enum InsightTint: String, Equatable {
        case green
        case orange
        case blue
        case purple
        case red
        case secondary

        var color: Color {
            switch self {
            case .green: return .green
            case .orange: return .orange
            case .blue: return .blue
            case .purple: return .purple
            case .red: return .red
            case .secondary: return .secondary
            }
        }
    }
}

/// Builder that turns a user's bets + summary into a set of insights to
/// display in the weekly recap card. Deterministic (no randomness) so the
/// recap can be shared and reproduced.
enum WeeklyInsightsBuilder {
    static func insights(
        summary: WeeklySocialSummary,
        bets: [PointBet],
        matches: [TennisMatch],
        favoritePlayers: [Player],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [WeeklyInsight] {
        let weeklyBets = bets.filter { summary.season.contains($0.createdAt) }
        let settledWeeklyBets = weeklyBets.filter { $0.status == .won || $0.status == .lost }
        let wonWeekly = weeklyBets.filter { $0.status == .won }
        let bestWin = wonWeekly.max { $0.payout < $1.payout }

        var insights: [WeeklyInsight] = []

        insights.append(WeeklyInsight(
            id: "read",
            title: "Leitura da liga",
            value: "\(summary.percentile)%",
            detail: summary.weeklyReadLine,
            systemImage: "brain.head.profile",
            tint: summary.percentile >= 60 ? .green : .orange
        ))

        insights.append(WeeklyInsight(
            id: "accuracy",
            title: "Acerto na semana",
            value: summary.winRateText,
            detail: "\(wonWeekly.count) acertos em \(settledWeeklyBets.count) picks liquidados",
            systemImage: "target",
            tint: settledWeeklyBets.isEmpty ? .secondary : .green
        ))

        insights.append(WeeklyInsight(
            id: "streak",
            title: "Streak atual",
            value: "\(summary.currentStreak)",
            detail: summary.streakLine,
            systemImage: summary.currentStreak >= 2 ? "flame.fill" : "flame",
            tint: summary.currentStreak >= 2 ? .orange : .secondary
        ))

        insights.append(WeeklyInsight(
            id: "points",
            title: "Pontos da semana",
            value: signed(summary.weeklyNetPoints),
            detail: summary.weeklyNetPoints >= 0
                ? "Você fechou a semana no positivo."
                : "Saldo semanal negativo — reveja o ritmo antes de arriscar mais.",
            systemImage: summary.weeklyNetPoints >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
            tint: summary.weeklyNetPoints >= 0 ? .blue : .red
        ))

        if let bestWin, let match = bestWin.match {
            insights.append(WeeklyInsight(
                id: "best",
                title: "Melhor pick",
                value: "+\(bestWin.payout) pts",
                detail: "\(bestWin.selection) em \(match.player1TeamName) vs \(match.player2TeamName)",
                systemImage: "star.fill",
                tint: .green
            ))
        }

        let favoriteBetKind = topBetKind(in: weeklyBets)
        if let favoriteBetKind {
            insights.append(WeeklyInsight(
                id: "kind",
                title: "Categoria favorita",
                value: favoriteBetKind.rawValue,
                detail: "É onde você mais gastou pontos esta semana.",
                systemImage: "square.stack.3d.up.fill",
                tint: .purple
            ))
        }

        let tournamentsPlayed = Set(weeklyBets.compactMap { $0.match?.tournament?.name }).count
        insights.append(WeeklyInsight(
            id: "tournaments",
            title: "Torneios cobertos",
            value: "\(tournamentsPlayed)",
            detail: tournamentsPlayed == 0
                ? "Nenhum torneio com pick esta semana."
                : "Palpites espalhados por \(tournamentsPlayed) evento(s).",
            systemImage: "trophy.fill",
            tint: tournamentsPlayed >= 2 ? .orange : .secondary
        ))

        if !favoritePlayers.isEmpty {
            let favoriteBets = weeklyBets.filter { bet in
                favoritePlayers.contains { $0.id == bet.player?.id }
            }
            insights.append(WeeklyInsight(
                id: "favorites",
                title: "Picks nos favoritos",
                value: "\(favoriteBets.count)",
                detail: favoriteBets.isEmpty
                    ? "Sem picks nos favoritos essa semana."
                    : "Você confiou \(favoriteBets.count) vez(es) em jogador favorito.",
                systemImage: "star.circle.fill",
                tint: favoriteBets.isEmpty ? .secondary : .green
            ))
        }

        return insights
    }

    private static func topBetKind(in bets: [PointBet]) -> BetKind? {
        var counts: [BetKind: Int] = [:]
        for bet in bets {
            counts[bet.kind, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }
}

// MARK: - Badges

/// Rarity/tier of a badge. Drives color, icon halo and copy in badge cards.
nonisolated enum SocialBadgeTier: String, CaseIterable, Codable {
    case common
    case rare
    case epic
    case legendary

    var label: String {
        switch self {
        case .common: return "Comum"
        case .rare: return "Raro"
        case .epic: return "Épico"
        case .legendary: return "Lendário"
        }
    }

    var color: Color {
        switch self {
        case .common: return .green
        case .rare: return .blue
        case .epic: return .purple
        case .legendary: return .orange
        }
    }
}

/// A single social badge. Contains presentation data + progress + unlocked
/// state. The catalog produces both earned and locked badges (with progress
/// so users can see how close they are to unlocking).
struct SocialBadge: Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let systemImage: String
    let tier: SocialBadgeTier
    let isUnlocked: Bool
    let progress: Double
    let progressLabel: String

    var accessibilityLabel: String {
        let status = isUnlocked ? "conquistada" : "em progresso, \(progressLabel)"
        return "\(title). \(tier.label). \(status). \(description)"
    }
}

/// Catalog of every badge the app awards. Adding a new badge = adding a
/// single case here — the profile / recap / share card all pick it up.
enum BadgeCatalog {
    static func badges(
        bets: [PointBet],
        favoritePlayers: [Player],
        matches: [TennisMatch],
        profile: UserProfile?,
        stats: PredictionStats
    ) -> [SocialBadge] {
        let wonBets = bets.filter { $0.status == .won }
        let longestStreak = longestWinStreak(bets: bets)
        let comebackWins = wonBets.filter { $0.performanceRule == .comebackWin }.count
        let clayFavorites = matches.filter {
            $0.tournament?.surface.localizedCaseInsensitiveContains("clay") == true && $0.isFavorite
        }.count
        let wtaFavorites = favoritePlayers.filter(\.isWTA).count
        let atpFavorites = favoritePlayers.filter { !$0.isWTA }.count
        let setWinnerWins = wonBets.filter { $0.kind == .setWinner }.count
        let matchWinnerWins = wonBets.filter { $0.kind == .matchWinner }.count
        let uniqueTournaments = Set(bets.compactMap { $0.match?.tournament?.name }).count

        var badges: [SocialBadge] = []

        badges.append(makeBadge(
            id: "first-serve",
            title: "Primeiro saque",
            description: "Você abriu conta no Match Point.",
            systemImage: "figure.tennis",
            tier: .common,
            progressCurrent: 1,
            target: 1
        ))

        badges.append(makeBadge(
            id: "scout",
            title: "Scout pessoal",
            description: "Siga pelo menos um jogador favorito.",
            systemImage: "binoculars.fill",
            tier: .common,
            progressCurrent: min(favoritePlayers.count, 1),
            target: 1
        ))

        badges.append(makeBadge(
            id: "sharp-read",
            title: "Leitura certeira",
            description: "Vença sua primeira previsão.",
            systemImage: "target",
            tier: .common,
            progressCurrent: min(wonBets.count, 1),
            target: 1
        ))

        badges.append(makeBadge(
            id: "top-seed",
            title: "Top seed",
            description: "Chegue a 1.500 pontos simbólicos.",
            systemImage: "crown.fill",
            tier: .rare,
            progressCurrent: profile?.points ?? 0,
            target: 1_500
        ))

        badges.append(makeBadge(
            id: "hot-streak",
            title: "Streak quente",
            description: "3 acertos seguidos.",
            systemImage: "flame.fill",
            tier: .rare,
            progressCurrent: longestStreak,
            target: 3
        ))

        badges.append(makeBadge(
            id: "legendary-streak",
            title: "Streak lendário",
            description: "Enfileire 7 acertos consecutivos.",
            systemImage: "flame.circle.fill",
            tier: .legendary,
            progressCurrent: longestStreak,
            target: 7
        ))

        badges.append(makeBadge(
            id: "set-reader",
            title: "Leu o set",
            description: "Acerte 3 previsões de vencedor do set.",
            systemImage: "1.square.fill",
            tier: .rare,
            progressCurrent: setWinnerWins,
            target: 3
        ))

        badges.append(makeBadge(
            id: "match-caller",
            title: "Match caller",
            description: "Acerte 5 vencedores de partida.",
            systemImage: "trophy.fill",
            tier: .epic,
            progressCurrent: matchWinnerWins,
            target: 5
        ))

        badges.append(makeBadge(
            id: "comeback",
            title: "Leu a virada",
            description: "Acerte um comeback do primeiro set perdido.",
            systemImage: "arrow.uturn.up.circle.fill",
            tier: .epic,
            progressCurrent: min(comebackWins, 1),
            target: 1
        ))

        badges.append(makeBadge(
            id: "wta-specialist",
            title: "Especialista WTA",
            description: "Siga pelo menos 2 jogadoras WTA.",
            systemImage: "star.leadinghalf.filled",
            tier: .rare,
            progressCurrent: wtaFavorites,
            target: 2
        ))

        badges.append(makeBadge(
            id: "atp-specialist",
            title: "Especialista ATP",
            description: "Siga pelo menos 2 jogadores ATP.",
            systemImage: "star.slash.fill",
            tier: .rare,
            progressCurrent: atpFavorites,
            target: 2
        ))

        badges.append(makeBadge(
            id: "clay-king",
            title: "Rei do saibro",
            description: "Marque uma partida em saibro como favorita.",
            systemImage: "circle.grid.2x2.fill",
            tier: .rare,
            progressCurrent: min(clayFavorites, 1),
            target: 1
        ))

        badges.append(makeBadge(
            id: "circuit-hopper",
            title: "Circuito completo",
            description: "Palpite em pelo menos 3 torneios diferentes.",
            systemImage: "map.fill",
            tier: .epic,
            progressCurrent: uniqueTournaments,
            target: 3
        ))

        badges.append(makeBadge(
            id: "big-week",
            title: "Semana grande",
            description: "Feche a semana com +200 pts líquidos.",
            systemImage: "chart.line.uptrend.xyaxis.circle.fill",
            tier: .legendary,
            progressCurrent: max(stats.weeklyNetPoints, 0),
            target: 200
        ))

        return badges
    }

    /// Convenience list of just the earned badge titles — kept so the existing
    /// `FlowTagRow(items:)` UI (string-based) keeps working without changes.
    static func earnedTitles(
        bets: [PointBet],
        favoritePlayers: [Player],
        matches: [TennisMatch],
        profile: UserProfile?,
        stats: PredictionStats
    ) -> [String] {
        badges(bets: bets, favoritePlayers: favoritePlayers, matches: matches, profile: profile, stats: stats)
            .filter(\.isUnlocked)
            .map(\.title)
    }

    private static func makeBadge(
        id: String,
        title: String,
        description: String,
        systemImage: String,
        tier: SocialBadgeTier,
        progressCurrent: Int,
        target: Int
    ) -> SocialBadge {
        let clampedTarget = max(target, 1)
        let clampedCurrent = max(progressCurrent, 0)
        let progress = min(1.0, Double(clampedCurrent) / Double(clampedTarget))
        let unlocked = clampedCurrent >= clampedTarget
        let label = unlocked
            ? "Conquistada"
            : "\(min(clampedCurrent, clampedTarget))/\(clampedTarget)"
        return SocialBadge(
            id: id,
            title: title,
            description: description,
            systemImage: systemImage,
            tier: tier,
            isUnlocked: unlocked,
            progress: progress,
            progressLabel: label
        )
    }

    private static func longestWinStreak(bets: [PointBet]) -> Int {
        let sorted = bets.sorted { $0.createdAt < $1.createdAt }
        var longest = 0
        var current = 0
        for bet in sorted {
            switch bet.status {
            case .won:
                current += 1
                longest = max(longest, current)
            case .lost:
                current = 0
            case .open, .void:
                continue
            }
        }
        return longest
    }
}

// MARK: - Pick reactions & interaction encoding

/// Emoji reactions available on any pick. Keeps a stable id / emoji / label
/// so counting + rendering + sharing all rely on the same source.
enum PickReactionKind: String, CaseIterable, Identifiable {
    case fire
    case bullseye
    case respect
    case shocked
    case doubtful

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .fire: return "🔥"
        case .bullseye: return "🎯"
        case .respect: return "💯"
        case .shocked: return "😱"
        case .doubtful: return "🤔"
        }
    }

    var label: String {
        switch self {
        case .fire: return "Fogo"
        case .bullseye: return "Cravou"
        case .respect: return "Respeito"
        case .shocked: return "Chocou"
        case .doubtful: return "Duvido"
        }
    }
}

/// Encoding used to tag `SocialPost.eventKey` (SwiftData) and
/// `CloudSocialPost.eventKey` (CloudKit) with a namespaced identifier
/// so we can filter posts back into a specific pick context.
///
/// Formats:
/// - Comment:  `"pick:<betID>:comment:<uuid>"`
/// - Reaction: `"pick:<betID>:reaction:<kind>:<uuid>"`
///
/// Legacy pre-namespaced posts published as `pick:<betID>:<uuid>` still
/// decode as comments (see `decode`).
enum PickInteractionEncoding {
    enum Kind: Equatable {
        case comment
        case reaction(PickReactionKind)
    }

    struct Decoded: Equatable {
        let betID: UUID
        let kind: Kind
    }

    static func comment(betID: UUID) -> String {
        "pick:\(betID.uuidString):comment:\(UUID().uuidString)"
    }

    static func reaction(betID: UUID, kind: PickReactionKind) -> String {
        "pick:\(betID.uuidString):reaction:\(kind.rawValue):\(UUID().uuidString)"
    }

    static func decode(_ eventKey: String?) -> Decoded? {
        guard let eventKey else { return nil }
        let parts = eventKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "pick" else { return nil }
        guard let uuid = UUID(uuidString: parts[1]) else { return nil }

        // Legacy: "pick:<uuid>:<random>" → comment.
        guard parts.count >= 4 else {
            return Decoded(betID: uuid, kind: .comment)
        }
        switch parts[2] {
        case "comment":
            return Decoded(betID: uuid, kind: .comment)
        case "reaction":
            guard parts.count >= 4, let kind = PickReactionKind(rawValue: parts[3]) else {
                return nil
            }
            return Decoded(betID: uuid, kind: .reaction(kind))
        default:
            return nil
        }
    }
}

/// Summary of interactions on a pick: reaction counts + comment count.
/// Filled in by scanning both local `SocialPost` and cloud `CloudSocialPost`
/// records via `PickInteractionAnalyzer`.
struct PickInteractionSummary: Equatable {
    let betID: UUID
    let reactionCounts: [PickReactionKind: Int]
    let commentCount: Int
    let viewerReactions: Set<PickReactionKind>

    static func empty(for betID: UUID) -> PickInteractionSummary {
        PickInteractionSummary(betID: betID, reactionCounts: [:], commentCount: 0, viewerReactions: [])
    }

    func count(for kind: PickReactionKind) -> Int {
        reactionCounts[kind] ?? 0
    }

    var totalReactions: Int {
        reactionCounts.values.reduce(0, +)
    }

    var totalInteractions: Int {
        totalReactions + commentCount
    }
}

// MARK: - Pick actions (agree / doubt / watching)

struct PickSocialAction: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let body: String

    static func actions(for bet: PointBet) -> [PickSocialAction] {
        let pick = bet.selection
        return [
            PickSocialAction(
                id: "agree",
                title: "Concordo",
                systemImage: "hand.thumbsup.fill",
                body: "Também estou com \(pick) nessa previsão."
            ),
            PickSocialAction(
                id: "challenge",
                title: "Duvido",
                systemImage: "bolt.fill",
                body: "Vou contra essa leitura: \(pick) precisa provar em quadra."
            ),
            PickSocialAction(
                id: "watching",
                title: "De olho",
                systemImage: "eye.fill",
                body: "Essa previsão ficou no meu radar: \(pick)."
            )
        ]
    }
}

// MARK: - Share card

struct PickShareImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { payload in
            payload.data
        }
    }
}

@MainActor
enum PickShareCardRenderer {
    static func payload(for bet: PointBet, profile: UserProfile?, weeklySummary: WeeklySocialSummary) -> PickShareImage? {
        #if canImport(UIKit)
        let card = PickShareCard(
            bet: bet,
            profileName: profile?.displayName ?? "Match Point Fan",
            weeklySummary: weeklySummary
        )
        .frame(width: 390, height: 520)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: card)
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage, let data = image.pngData() else { return nil }
        return PickShareImage(data: data)
        #else
        return nil
        #endif
    }
}

struct PickShareCard: View {
    let bet: PointBet
    let profileName: String
    let weeklySummary: WeeklySocialSummary

    private var matchTitle: String {
        bet.match.map { "\($0.player1TeamName) vs \($0.player2TeamName)" } ?? "Partida Match Point"
    }

    private var statusColor: Color {
        switch bet.status {
        case .open: return .orange
        case .won: return .green
        case .lost: return .red
        case .void: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MATCH POINT PICK")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.green)
                    Text(profileName)
                        .font(.title2.weight(.heavy))
                }
                Spacer()
                Image(systemName: "tennisball.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(matchTitle)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(bet.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(bet.selection)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label("\(bet.stake) pts", systemImage: "ticket.fill")
                    Label("retorno \(bet.payout)", systemImage: "arrow.up.forward.circle.fill")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                PickShareMetric(title: "Status", value: bet.status.rawValue, tint: statusColor)
                PickShareMetric(title: "Acerto", value: weeklySummary.winRateText, tint: .green)
                PickShareMetric(title: "Streak", value: "\(weeklySummary.currentStreak)", tint: .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(weeklySummary.season.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
                Text(weeklySummary.weeklyReadLine)
                    .font(.headline.weight(.heavy))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text("Match Point")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.12, blue: 0.10), Color(red: 0.02, green: 0.28, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct PickShareMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.black))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.heavy))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
