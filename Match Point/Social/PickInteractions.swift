import Foundation
import SwiftData

// MARK: - Pick interaction analyzer
//
// Reactions and pick-scoped comments are encoded in `eventKey` (see
// `PickInteractionEncoding`) so we don't need a schema migration. This
// analyzer walks both local `SocialPost` and cloud `CloudSocialPost`
// sources and produces per-pick summaries + threaded comment lists that
// UI can render directly.

enum PickInteractionAnalyzer {
    /// Returns a summary of reactions + comment count for a single pick.
    ///
    /// `viewer` is the current user's display name — used to derive
    /// `viewerReactions` so we can highlight the emoji chips the current
    /// user already toggled. Falls back to author-name matching because we
    /// don't have a stable per-device auth id today.
    static func summary(
        for betID: UUID,
        localPosts: [SocialPost],
        cloudPosts: [CloudSocialPost],
        viewer: String
    ) -> PickInteractionSummary {
        var counts: [PickReactionKind: Int] = [:]
        var viewerReactions: Set<PickReactionKind> = []
        var commentCount = 0

        for post in localPosts {
            guard !post.isHidden else { continue }
            guard let decoded = PickInteractionEncoding.decode(post.eventKey),
                  decoded.betID == betID else { continue }
            switch decoded.kind {
            case .comment:
                commentCount += 1
            case .reaction(let kind):
                counts[kind, default: 0] += 1
                if post.authorName == viewer {
                    viewerReactions.insert(kind)
                }
            }
        }

        for post in cloudPosts {
            guard !post.isHidden else { continue }
            guard let decoded = PickInteractionEncoding.decode(post.eventKey),
                  decoded.betID == betID else { continue }
            switch decoded.kind {
            case .comment:
                commentCount += 1
            case .reaction(let kind):
                counts[kind, default: 0] += 1
                if post.authorName == viewer {
                    viewerReactions.insert(kind)
                }
            }
        }

        return PickInteractionSummary(
            betID: betID,
            reactionCounts: counts,
            commentCount: commentCount,
            viewerReactions: viewerReactions
        )
    }

    /// Returns the ordered comment thread for a pick, most recent last.
    static func comments(
        for betID: UUID,
        localPosts: [SocialPost],
        cloudPosts: [CloudSocialPost]
    ) -> [PickCommentEntry] {
        var entries: [PickCommentEntry] = []

        for post in localPosts {
            guard !post.isHidden else { continue }
            guard let decoded = PickInteractionEncoding.decode(post.eventKey),
                  decoded.betID == betID,
                  case .comment = decoded.kind else { continue }
            entries.append(PickCommentEntry(
                id: "local:\(post.id.uuidString)",
                authorName: post.authorName,
                body: post.body,
                createdAt: post.createdAt,
                source: .local
            ))
        }

        for post in cloudPosts {
            guard !post.isHidden else { continue }
            guard let decoded = PickInteractionEncoding.decode(post.eventKey),
                  decoded.betID == betID,
                  case .comment = decoded.kind else { continue }
            entries.append(PickCommentEntry(
                id: "cloud:\(post.id)",
                authorName: post.authorName,
                body: post.body,
                createdAt: post.createdAt,
                source: .cloud
            ))
        }

        return entries.sorted { $0.createdAt < $1.createdAt }
    }
}

struct PickCommentEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case local
        case cloud
    }

    let id: String
    let authorName: String
    let body: String
    let createdAt: Date
    let source: Source
}

// MARK: - Public-profile pick highlights

/// A single "signature moment" surfaced on the public profile: the pick that
/// won the most points, the longest streak the user ever assembled, the pick
/// that hurt the most, etc.
struct PickHighlight: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: WeeklyInsight.InsightTint
}

/// Public-profile-facing highlights derived from a user's full pick history.
enum PickHighlightBuilder {
    static func highlights(
        bets: [PointBet],
        matches: [TennisMatch],
        favoritePlayers: [Player]
    ) -> [PickHighlight] {
        var items: [PickHighlight] = []

        let wonBets = bets.filter { $0.status == .won }
        if let bestWin = wonBets.max(by: { $0.payout < $1.payout }), let match = bestWin.match {
            items.append(PickHighlight(
                id: "best-pick",
                title: "Pick assinado",
                value: "+\(bestWin.payout) pts",
                detail: "\(bestWin.selection) em \(match.player1TeamName) vs \(match.player2TeamName)",
                systemImage: "star.circle.fill",
                tint: .green
            ))
        }

        let longest = longestStreak(bets: bets)
        if longest > 0 {
            items.append(PickHighlight(
                id: "longest-streak",
                title: "Maior streak",
                value: "\(longest) acertos",
                detail: longest >= 5 ? "Sequência de leitura fria." : "Boas ondas quando engrena.",
                systemImage: "flame.circle.fill",
                tint: longest >= 5 ? .orange : .blue
            ))
        }

        if let bestKind = mostFrequentKind(in: bets) {
            items.append(PickHighlight(
                id: "favorite-kind",
                title: "Categoria assinatura",
                value: bestKind.rawValue,
                detail: "É onde você mais aposta.",
                systemImage: "square.stack.3d.up.fill",
                tint: .purple
            ))
        }

        if let favoriteTournament = mostFrequentTournament(in: bets) {
            items.append(PickHighlight(
                id: "favorite-tournament",
                title: "Torneio da casa",
                value: favoriteTournament.name,
                detail: "\(favoriteTournament.count) picks colocados aqui.",
                systemImage: "trophy.circle.fill",
                tint: .orange
            ))
        }

        let surfaceStats = surfaceWinRates(bets: bets)
        if let best = surfaceStats.max(by: { $0.value.winRate < $1.value.winRate }) {
            let percent = Int((best.value.winRate * 100).rounded())
            items.append(PickHighlight(
                id: "best-surface",
                title: "Superfície forte",
                value: "\(percent)% em \(best.key)",
                detail: "\(best.value.wins)V \(best.value.losses)D em \(best.key.lowercased()).",
                systemImage: "circle.grid.2x2.fill",
                tint: percent >= 55 ? .green : .secondary
            ))
        }

        if !favoritePlayers.isEmpty {
            let favoriteBets = bets.filter { bet in
                favoritePlayers.contains { $0.id == bet.player?.id }
            }
            if !favoriteBets.isEmpty {
                let wonForFavorite = favoriteBets.filter { $0.status == .won }.count
                let settledForFavorite = favoriteBets.filter { $0.status == .won || $0.status == .lost }.count
                let rate = settledForFavorite == 0
                    ? "—"
                    : "\(Int((Double(wonForFavorite) / Double(settledForFavorite) * 100).rounded()))%"
                items.append(PickHighlight(
                    id: "favorite-trust",
                    title: "Confiança nos favoritos",
                    value: rate,
                    detail: "\(favoriteBets.count) picks apoiando jogadores do coração.",
                    systemImage: "heart.circle.fill",
                    tint: .red
                ))
            }
        }

        return items
    }

    private static func longestStreak(bets: [PointBet]) -> Int {
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

    private static func mostFrequentKind(in bets: [PointBet]) -> BetKind? {
        var counts: [BetKind: Int] = [:]
        for bet in bets { counts[bet.kind, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    private struct TournamentTally {
        let name: String
        let count: Int
    }

    private static func mostFrequentTournament(in bets: [PointBet]) -> TournamentTally? {
        var counts: [String: Int] = [:]
        for bet in bets {
            if let name = bet.match?.tournament?.name, !name.isEmpty {
                counts[name, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }.map { TournamentTally(name: $0.key, count: $0.value) }
    }

    struct SurfaceWinRate {
        let wins: Int
        let losses: Int

        var settled: Int { wins + losses }

        var winRate: Double {
            guard settled > 0 else { return 0 }
            return Double(wins) / Double(settled)
        }
    }

    static func surfaceWinRates(bets: [PointBet]) -> [String: SurfaceWinRate] {
        var wins: [String: Int] = [:]
        var losses: [String: Int] = [:]
        for bet in bets {
            let raw = bet.match?.tournament?.surface ?? ""
            let key = normalizedSurface(raw)
            switch bet.status {
            case .won: wins[key, default: 0] += 1
            case .lost: losses[key, default: 0] += 1
            default: continue
            }
        }
        let keys = Set(wins.keys).union(losses.keys)
        var results: [String: SurfaceWinRate] = [:]
        for key in keys {
            results[key] = SurfaceWinRate(wins: wins[key] ?? 0, losses: losses[key] ?? 0)
        }
        return results
    }

    static func normalizedSurface(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("clay") || lower.contains("saibro") { return "Saibro" }
        if lower.contains("grass") || lower.contains("grama") { return "Grama" }
        if lower.contains("hard") || lower.contains("dura") { return "Dura" }
        if lower.contains("carpet") { return "Carpete" }
        if raw.isEmpty { return "Outras" }
        return raw.capitalized
    }
}

// MARK: - Activity heatmap

struct PickActivityHeatmap: Equatable {
    /// One cell per day of history, most recent day last. Empty when no bets.
    let cells: [Cell]

    struct Cell: Identifiable, Equatable {
        let id: String
        let date: Date
        let bets: Int
        let wins: Int
        let losses: Int
        let netPoints: Int

        /// 0..1 intensity used by the heatmap fill.
        var intensity: Double {
            let capped = min(bets, 5)
            return Double(capped) / 5.0
        }
    }

    static func build(from bets: [PointBet], days: Int = 28, now: Date = .now, calendar: Calendar = .current) -> PickActivityHeatmap {
        var cells: [Cell] = []
        let startOfToday = calendar.startOfDay(for: now)
        for offset in (0..<days).reversed() {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let bucket = bets.filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd }
            let wins = bucket.filter { $0.status == .won }.count
            let losses = bucket.filter { $0.status == .lost }.count
            let netPoints = bucket.reduce(0) { partial, bet in
                switch bet.status {
                case .won: return partial + bet.payout - bet.stake
                case .lost: return partial - bet.stake
                case .open, .void: return partial
                }
            }
            cells.append(Cell(
                id: dayStart.timeIntervalSince1970.description,
                date: dayStart,
                bets: bucket.count,
                wins: wins,
                losses: losses,
                netPoints: netPoints
            ))
        }
        return PickActivityHeatmap(cells: cells)
    }
}

// MARK: - Leaderboard position tracking (week-over-week deltas)

/// Persists the previous week's leaderboard rank so we can show ↑/↓ arrows on
/// the current view. Stored in UserDefaults as a small snapshot keyed by
/// season kind + leaderboard source so backend and CloudKit sources don't
/// clobber each other.
enum LeaderboardHistoryStore {
    private static let defaults = UserDefaults.standard
    private static let key = "match-point.leaderboard.history.v1"

    struct Snapshot: Codable, Equatable {
        var seasonKind: String
        var source: String
        var rank: Int
        var capturedAt: Date
    }

    static func recordCurrent(seasonKind: SocialSeasonKind, source: String, rank: Int, now: Date = .now) {
        var snapshots = loadAll()
        let identifier = key(seasonKind: seasonKind, source: source)
        // Only overwrite if the current snapshot is at least a day old — so
        // we can compute deltas across sessions in the same day without
        // flapping.
        if let existing = snapshots[identifier],
           now.timeIntervalSince(existing.capturedAt) < 60 * 60 * 20 {
            return
        }
        snapshots[identifier] = Snapshot(
            seasonKind: seasonKind.rawValue,
            source: source,
            rank: rank,
            capturedAt: now
        )
        persist(snapshots)
    }

    static func previousRank(seasonKind: SocialSeasonKind, source: String) -> Int? {
        loadAll()[key(seasonKind: seasonKind, source: source)]?.rank
    }

    static func clearAll() {
        defaults.removeObject(forKey: key)
    }

    private static func key(seasonKind: SocialSeasonKind, source: String) -> String {
        "\(seasonKind.rawValue)|\(source)"
    }

    private static func loadAll() -> [String: Snapshot] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Snapshot].self, from: data)) ?? [:]
    }

    private static func persist(_ snapshots: [String: Snapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: key)
    }
}
