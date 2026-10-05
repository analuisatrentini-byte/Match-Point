//
//  MatchPointTodayWidgets.swift
//  MatchPointLiveActivity
//
//  Editorial Home Screen widget for today's tennis briefing and schedule.
//

import SwiftUI
import WidgetKit

private enum TodayWidgetSharedStorage {
    static let appGroupID = "group.ALTB.Match-Point"
    static let matchSnapshotKey = "match-point.widget.match-snapshots"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}

private struct TodayMatchSnapshot: Codable, Identifiable {
    struct SetScore: Codable, Hashable {
        var player1Games: String
        var player2Games: String
    }

    var id: String
    var tournamentName: String
    var roundLabel: String
    var surface: String
    var player1Name: String
    var player2Name: String
    var player1Flag: String
    var player2Flag: String
    var player1Rank: Int?
    var player2Rank: Int?
    var player1SetsWon: Int
    var player2SetsWon: Int
    var setScores: [SetScore]
    var pointScore: String
    var gameScore: String
    var serverName: String
    var status: String
    var isLive: Bool
    var isFavorite: Bool
    var courtName: String?
    var orderOfPlay: Int?
    var criticalMomentKind: String?
    var criticalMomentHeadline: String?
    var matchDate: Date?
    var lastUpdated: Date
}

private struct TodayBriefingEntry: TimelineEntry {
    var date: Date
    var matches: [TodayMatchSnapshot]

    var featured: TodayMatchSnapshot? {
        matches.first
    }
}

private struct TodayBriefingProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayBriefingEntry {
        TodayBriefingEntry(date: .now, matches: [.previewLive, .previewUpcoming, .previewWTA])
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayBriefingEntry) -> Void) {
        let matches = loadMatches()
        completion(TodayBriefingEntry(date: .now, matches: matches.isEmpty ? [.previewLive, .previewUpcoming, .previewWTA] : matches))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayBriefingEntry>) -> Void) {
        let entry = TodayBriefingEntry(date: .now, matches: loadMatches())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadMatches() -> [TodayMatchSnapshot] {
        guard let data = TodayWidgetSharedStorage.defaults.data(forKey: TodayWidgetSharedStorage.matchSnapshotKey) else {
            return []
        }
        return ((try? JSONDecoder().decode([TodayMatchSnapshot].self, from: data)) ?? [])
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
                return (lhs.matchDate ?? lhs.lastUpdated) < (rhs.matchDate ?? rhs.lastUpdated)
            }
    }
}

struct MatchPointTodayBriefingWidget: Widget {
    let kind = "MatchPointTodayBriefingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayBriefingProvider()) { entry in
            TodayBriefingWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    TodayWidgetBackground(surface: entry.featured?.surface ?? "hard")
                }
                .widgetURL(URL(string: "matchpoint://today"))
        }
        .configurationDisplayName("Match Point Today")
        .description("Briefing premium com live, próxima partida, torneio e agenda dos favoritos.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct TodayBriefingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayBriefingEntry

    var body: some View {
        switch family {
        case .systemSmall:
            small
        case .systemLarge:
            large
        default:
            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("TODAY")
            Spacer(minLength: 0)
            if let match = entry.featured {
                Text(match.tournamentName.uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(matchTitle(match))
                    .font(.title3.weight(.heavy))
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                Text(primaryDetail(match))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
            } else {
                Text("Abra o app para sincronizar a agenda.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                header(entry.matches.contains(where: \.isLive) ? "LIVE BRIEFING" : "NEXT MATCH")
                if let match = entry.featured {
                    Text(match.tournamentName.uppercased())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text(matchTitle(match))
                        .font(.title2.weight(.heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)
                    Text(primaryDetail(match))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 7) {
                Text("\(entry.matches.count)")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("matches")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.54))
                if let court = entry.featured?.courtName, !court.isEmpty {
                    Label(court, systemImage: "sportscourt")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                header("TODAY IN TENNIS")
                Spacer()
                Text("\(liveCount) LIVE • \(topTenCount) TOP-10")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.56))
            }

            if let match = entry.featured {
                VStack(alignment: .leading, spacing: 7) {
                    Text(match.tournamentName.uppercased())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.68))
                    HStack(alignment: .firstTextBaseline) {
                        Text(matchTitle(match))
                            .font(.title2.weight(.heavy))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(scoreOrTime(match))
                            .font(.title.weight(.heavy))
                            .monospacedDigit()
                    }
                    Text(primaryDetail(match))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .padding(.bottom, 4)
            }

            VStack(spacing: 9) {
                ForEach(Array(entry.matches.prefix(5))) { match in
                    ScheduleLine(match: match)
                }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private var liveCount: Int {
        entry.matches.filter(\.isLive).count
    }

    private var topTenCount: Int {
        entry.matches.filter { ($0.player1Rank ?? 999) <= 10 || ($0.player2Rank ?? 999) <= 10 }.count
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            if entry.matches.contains(where: \.isLive) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.25, blue: 0.22))
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.64))
        }
    }

    private func matchTitle(_ match: TodayMatchSnapshot) -> String {
        "\(shortName(match.player1Name)) × \(shortName(match.player2Name))"
    }

    private func primaryDetail(_ match: TodayMatchSnapshot) -> String {
        if let critical = match.criticalMomentHeadline, !critical.isEmpty { return critical }
        if match.isLive { return scoreOrTime(match) }
        let parts = [match.roundLabel, match.courtName ?? "", matchTime(match) ?? ""]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " • ")
    }

    private func scoreOrTime(_ match: TodayMatchSnapshot) -> String {
        if match.isLive, !match.pointScore.isEmpty { return match.pointScore.replacingOccurrences(of: "-", with: "–") }
        if match.isLive, !match.gameScore.isEmpty { return match.gameScore.replacingOccurrences(of: "-", with: "–") }
        if match.isLive { return "\(match.player1SetsWon)–\(match.player2SetsWon)" }
        return matchTime(match) ?? "TBD"
    }

    private func matchTime(_ match: TodayMatchSnapshot) -> String? {
        match.matchDate?.formatted(date: .omitted, time: .shortened)
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1, let first = parts.first?.first, let last = parts.last else { return name }
        return "\(first). \(last)"
    }
}

private struct ScheduleLine: View {
    let match: TodayMatchSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Text(timeText)
                .font(.caption.monospacedDigit().weight(.heavy))
                .frame(width: 44, alignment: .leading)
                .foregroundStyle(match.isLive ? Color(red: 1.0, green: 0.34, blue: 0.28) : .white.opacity(0.62))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shortName(match.player1Name)) × \(shortName(match.player2Name))")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text([match.roundLabel, match.courtName].compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.joined(separator: " • "))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if match.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.94, green: 0.82, blue: 0.25))
            }
        }
    }

    private var timeText: String {
        if match.isLive { return "LIVE" }
        return match.matchDate?.formatted(date: .omitted, time: .shortened) ?? "TBD"
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1, let first = parts.first?.first, let last = parts.last else { return name }
        return "\(first). \(last)"
    }
}

private struct TodayWidgetBackground: View {
    let surface: String

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(colors.last?.opacity(0.24) ?? .white.opacity(0.16))
                    .frame(width: 180, height: 180)
                    .blur(radius: 30)
                    .offset(x: 54, y: 64)
            }
    }

    private var colors: [Color] {
        let lower = surface.lowercased()
        if lower.contains("clay") || lower.contains("saibro") {
            return [Color(red: 0.16, green: 0.07, blue: 0.05), Color(red: 0.60, green: 0.26, blue: 0.16)]
        }
        if lower.contains("grass") || lower.contains("grama") {
            return [Color(red: 0.03, green: 0.08, blue: 0.05), Color(red: 0.16, green: 0.38, blue: 0.19)]
        }
        return [Color(red: 0.02, green: 0.04, blue: 0.07), Color(red: 0.08, green: 0.20, blue: 0.34)]
    }
}

private extension TodayMatchSnapshot {
    static let previewLive = TodayMatchSnapshot(
        id: "today-live",
        tournamentName: "US Open",
        roundLabel: "Semifinal",
        surface: "Hard",
        player1Name: "Jannik Sinner",
        player2Name: "Carlos Alcaraz",
        player1Flag: "🇮🇹",
        player2Flag: "🇪🇸",
        player1Rank: 1,
        player2Rank: 2,
        player1SetsWon: 1,
        player2SetsWon: 1,
        setScores: [.init(player1Games: "6", player2Games: "4"), .init(player1Games: "4", player2Games: "6")],
        pointScore: "40-30",
        gameScore: "2-1",
        serverName: "Jannik Sinner",
        status: "Live",
        isLive: true,
        isFavorite: true,
        courtName: "Arthur Ashe Stadium",
        orderOfPlay: 4,
        criticalMomentKind: nil,
        criticalMomentHeadline: "Sinner sacando em game crítico",
        matchDate: .now,
        lastUpdated: .now
    )

    static let previewUpcoming = TodayMatchSnapshot(
        id: "today-upcoming",
        tournamentName: "US Open",
        roundLabel: "Quarterfinal",
        surface: "Hard",
        player1Name: "Novak Djokovic",
        player2Name: "Holger Rune",
        player1Flag: "🇷🇸",
        player2Flag: "🇩🇰",
        player1Rank: 4,
        player2Rank: 12,
        player1SetsWon: 0,
        player2SetsWon: 0,
        setScores: [],
        pointScore: "",
        gameScore: "",
        serverName: "",
        status: "Scheduled",
        isLive: false,
        isFavorite: false,
        courtName: "Louis Armstrong",
        orderOfPlay: 2,
        criticalMomentKind: nil,
        criticalMomentHeadline: nil,
        matchDate: .now.addingTimeInterval(7_200),
        lastUpdated: .now
    )

    static let previewWTA = TodayMatchSnapshot(
        id: "today-wta",
        tournamentName: "US Open",
        roundLabel: "Semifinal",
        surface: "Hard",
        player1Name: "Iga Swiatek",
        player2Name: "Coco Gauff",
        player1Flag: "🇵🇱",
        player2Flag: "🇺🇸",
        player1Rank: 1,
        player2Rank: 3,
        player1SetsWon: 0,
        player2SetsWon: 0,
        setScores: [],
        pointScore: "",
        gameScore: "",
        serverName: "",
        status: "Scheduled",
        isLive: false,
        isFavorite: true,
        courtName: "Arthur Ashe Stadium",
        orderOfPlay: 5,
        criticalMomentKind: nil,
        criticalMomentHeadline: nil,
        matchDate: .now.addingTimeInterval(13_500),
        lastUpdated: .now
    )
}
