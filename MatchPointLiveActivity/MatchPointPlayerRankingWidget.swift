//
//  MatchPointPlayerRankingWidget.swift
//  MatchPointLiveActivity
//
//  Small WidgetKit surface for favorite/top-ranked players.
//

import SwiftUI
import WidgetKit

private enum PlayerRankingWidgetSharedStorage {
    static let appGroupID = "group.ALTB.Match-Point"
    static let snapshotKey = "match-point.widget.player-ranking-snapshots"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}

private struct PlayerRankingWidgetSnapshot: Codable, Identifiable {
    var id: String
    var playerName: String
    var countryCode: String
    var countryFlag: String
    var rank: Int
    var points: Int
    var tourRaw: String
    var isFavorite: Bool
    var lastUpdated: Date
}

private struct PlayerRankingEntry: TimelineEntry {
    var date: Date
    var snapshots: [PlayerRankingWidgetSnapshot]

    var snapshot: PlayerRankingWidgetSnapshot? {
        snapshots.first
    }
}

private struct PlayerRankingProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlayerRankingEntry {
        PlayerRankingEntry(date: .now, snapshots: [.sinner, .swiatek])
    }

    func getSnapshot(in context: Context, completion: @escaping (PlayerRankingEntry) -> Void) {
        let snapshots = loadSnapshots()
        completion(PlayerRankingEntry(date: .now, snapshots: snapshots.isEmpty ? [.sinner, .swiatek] : snapshots))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlayerRankingEntry>) -> Void) {
        let entry = PlayerRankingEntry(date: .now, snapshots: loadSnapshots())
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 6, to: .now) ?? .now.addingTimeInterval(21_600)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadSnapshots() -> [PlayerRankingWidgetSnapshot] {
        guard let data = PlayerRankingWidgetSharedStorage.defaults.data(forKey: PlayerRankingWidgetSharedStorage.snapshotKey) else {
            return []
        }
        return ((try? JSONDecoder().decode([PlayerRankingWidgetSnapshot].self, from: data)) ?? [])
            .sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
                if lhs.tourRaw != rhs.tourRaw { return lhs.tourRaw < rhs.tourRaw }
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.playerName < rhs.playerName
            }
    }
}

struct MatchPointPlayerRankingWidget: Widget {
    let kind = "MatchPointPlayerRankingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlayerRankingProvider()) { entry in
            PlayerRankingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "matchpoint://players/\(entry.snapshot?.id ?? "ranking")"))
        }
        .configurationDisplayName("Match Point Ranking")
        .description("Veja ranking, pontos e país de um favorito ou top 50 ATP/WTA.")
        .supportedFamilies(Self.supportedFamilies)
    }

    private static var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}

private struct PlayerRankingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlayerRankingEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        #if os(watchOS)
        case .accessoryCorner:
            corner
        #endif
        case .systemMedium:
            medium
        case .systemLarge:
            large
        default:
            small
        }
    }

    @ViewBuilder
    private var circular: some View {
        if let snapshot = entry.snapshot {
            VStack(spacing: 1) {
                Text(playerCode(snapshot.playerName))
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("#\(snapshot.rank)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(compactPoints(snapshot.points))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(countryCode(snapshot))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .widgetAccentable()
        } else {
            Text("MP")
                .font(.caption.weight(.heavy))
        }
    }

    #if os(watchOS)
    @ViewBuilder
    private var corner: some View {
        if let snapshot = entry.snapshot {
            Text("\(playerCode(snapshot.playerName)) #\(snapshot.rank)")
                .widgetCurvesContent()
                .widgetAccentable()
        } else {
            Text("MP")
                .widgetCurvesContent()
        }
    }
    #endif

    @ViewBuilder
    private var rectangular: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(snapshot.tourRaw) #\(snapshot.rank) • \(countryCode(snapshot))")
                    .font(.caption2.weight(.heavy))
                Text(snapshot.playerName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text("\(snapshot.points.formatted(.number)) pts")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
        } else {
            Text("Ranking Match Point")
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let snapshot = entry.snapshot {
            Text("\(playerCode(snapshot.playerName)) \(snapshot.points.formatted(.number)) pts \(countryCode(snapshot))")
        } else {
            Text("Match Point Ranking")
        }
    }

    private var small: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.09, blue: 0.13), Color(red: 0.18, green: 0.42, blue: 0.31)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if entry.snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ranking")
                        .font(.headline.weight(.heavy))
                    Text("Sincronize ATP/WTA para ver o top 50.")
                        .font(.caption.weight(.semibold))
                        .lineLimit(3)
                }
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.snapshots.prefix(3))) { snapshot in
                        HStack(spacing: 8) {
                            Text(countryCode(snapshot))
                                .font(.caption2.weight(.heavy))
                                .frame(width: 24, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.playerName)
                                    .font(.caption.weight(.heavy))
                                    .lineLimit(1)
                                Text("#\(snapshot.rank) • \(snapshot.points.formatted(.number)) pts")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var medium: some View {
        ZStack {
            rankingBackground
            if let snapshot = entry.snapshot {
                HStack(spacing: 16) {
                    PlayerMonogram(snapshot: snapshot, size: 82)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.tourRaw)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.66))
                        Text(twoLineName(snapshot.playerName))
                            .font(.system(size: 23, weight: .heavy, design: .rounded))
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                        HStack(spacing: 14) {
                            metric("RANK", "#\(snapshot.rank)")
                            metric("PTS", compactPoints(snapshot.points))
                            metric("PAÍS", countryCode(snapshot))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(16)
            } else {
                EmptyRankingState()
            }
        }
    }

    private var large: some View {
        ZStack {
            rankingBackground
            if entry.snapshots.isEmpty {
                EmptyRankingState()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("HOME SCREEN RANKINGS")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.66))
                        Spacer()
                        Text("TOP 50 ATP/WTA")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.48))
                    }

                    if let snapshot = entry.snapshot {
                        HStack(spacing: 14) {
                            PlayerMonogram(snapshot: snapshot, size: 76)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(twoLineName(snapshot.playerName))
                                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                                    .lineLimit(2)
                                Text("\(snapshot.tourRaw) #\(snapshot.rank) • \(snapshot.points.formatted(.number)) pts • \(countryCode(snapshot))")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                        }
                    }

                    Divider()
                        .overlay(.white.opacity(0.16))

                    HStack(alignment: .top, spacing: 18) {
                        rankingColumn(title: "ATP", snapshots: snapshots(for: "ATP"))
                        rankingColumn(title: "WTA", snapshots: snapshots(for: "WTA"))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(16)
            }
        }
    }

    private var rankingBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.03, green: 0.04, blue: 0.06), Color(red: 0.10, green: 0.18, blue: 0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color(red: 0.54, green: 0.86, blue: 0.52).opacity(0.20))
                .frame(width: 150, height: 150)
                .blur(radius: 28)
                .offset(x: 40, y: -48)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.caption.monospacedDigit().weight(.heavy))
        }
    }

    private func rankingColumn(title: String, snapshots: [PlayerRankingWidgetSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title) RANKING")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white.opacity(0.62))
            ForEach(snapshots.prefix(5)) { snapshot in
                HStack(spacing: 6) {
                    Text("\(snapshot.rank)")
                        .font(.caption.monospacedDigit().weight(.heavy))
                        .frame(width: 18, alignment: .leading)
                    Text(shortRankingName(snapshot.playerName))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(compactPoints(snapshot.points))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.66))
                }
            }
        }
    }

    private func snapshots(for tour: String) -> [PlayerRankingWidgetSnapshot] {
        entry.snapshots.filter { $0.tourRaw == tour }.sorted { $0.rank < $1.rank }
    }

    private func twoLineName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return name.uppercased() }
        return "\(parts.dropLast().joined(separator: " ").uppercased())\n\(parts.last?.uppercased() ?? "")"
    }

    private func shortRankingName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1, let first = parts.first?.first, let last = parts.last else {
            return name
        }
        return "\(first). \(last)"
    }

    private func playerCode(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        let raw = parts.last ?? name
        return String(raw.prefix(6)).uppercased()
    }

    private func compactPoints(_ points: Int) -> String {
        if points >= 10_000 {
            return String(format: "%.1fk", Double(points) / 1_000).replacingOccurrences(of: ".0", with: "")
        }
        if points >= 1_000 {
            return String(format: "%.1fk", Double(points) / 1_000)
        }
        return "\(points)"
    }

    private func countryCode(_ snapshot: PlayerRankingWidgetSnapshot) -> String {
        let normalized = snapshot.countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return snapshot.countryFlag.isEmpty ? "--" : snapshot.countryFlag }
        if normalized.count <= 3 { return normalized.uppercased() }
        let lookup = [
            "italy": "ITA",
            "spain": "ESP",
            "serbia": "SRB",
            "poland": "POL",
            "belarus": "BLR",
            "united states": "USA",
            "usa": "USA",
            "germany": "GER",
            "france": "FRA",
            "brazil": "BRA",
            "czech republic": "CZE",
            "kazakhstan": "KAZ",
            "russia": "RUS",
            "ukraine": "UKR",
            "china": "CHN",
            "japan": "JPN",
            "australia": "AUS",
            "great britain": "GBR",
            "united kingdom": "GBR"
        ]
        return lookup[normalized.lowercased()] ?? String(normalized.prefix(3)).uppercased()
    }
}

private struct PlayerMonogram: View {
    let snapshot: PlayerRankingWidgetSnapshot
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.10))
            Circle()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            VStack(spacing: 2) {
                Text(monogram(snapshot.playerName))
                    .font(.system(size: size * 0.27, weight: .heavy, design: .rounded))
                Text(country)
                    .font(.system(size: size * 0.12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .frame(width: size, height: size)
    }

    private var country: String {
        let normalized = snapshot.countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return snapshot.countryFlag.isEmpty ? "--" : snapshot.countryFlag }
        return normalized.count <= 3 ? normalized.uppercased() : String(normalized.prefix(3)).uppercased()
    }

    private func monogram(_ name: String) -> String {
        let initials = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return initials.isEmpty ? "MP" : initials.uppercased()
    }
}

private struct EmptyRankingState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ranking")
                .font(.headline.weight(.heavy))
            Text("Sincronize ATP/WTA para ver favoritos e top 50.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(3)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension PlayerRankingWidgetSnapshot {
    static let sinner = PlayerRankingWidgetSnapshot(
        id: "ATP-preview-sinner",
        playerName: "Jannik Sinner",
        countryCode: "ITA",
        countryFlag: "🇮🇹",
        rank: 1,
        points: 11_830,
        tourRaw: "ATP",
        isFavorite: true,
        lastUpdated: .now
    )

    static let swiatek = PlayerRankingWidgetSnapshot(
        id: "WTA-preview-swiatek",
        playerName: "Iga Swiatek",
        countryCode: "POL",
        countryFlag: "🇵🇱",
        rank: 1,
        points: 9_100,
        tourRaw: "WTA",
        isFavorite: false,
        lastUpdated: .now
    )
}
