//
//  MatchPointLiveActivityLiveActivity.swift
//  MatchPointLiveActivity
//
//  Lock-screen + Dynamic Island presentation for tennis match Live Activities.
//  Uses MatchActivityAttributes from the main Match Point target
//  (must also be a member of this widget extension target).
//

import ActivityKit
import SwiftUI
import WidgetKit

struct MatchPointLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MatchActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DI_PlayerLabel(
                        name: context.attributes.player1Name,
                        flag: context.attributes.player1Flag,
                        rank: context.attributes.player1Rank,
                        isServing: context.state.serverIsPlayerOne == true,
                        alignTrailing: false
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DI_PlayerLabel(
                        name: context.attributes.player2Name,
                        flag: context.attributes.player2Flag,
                        rank: context.attributes.player2Rank,
                        isServing: context.state.serverIsPlayerOne == false,
                        alignTrailing: true
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    DI_CenterScore(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        SetTable(state: context.state, compact: true)
                        Text(dynamicIslandStatus(state: context.state))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Text("\(shortName(context.attributes.player1Name)) \(context.state.player1SetsWon)")
                    .font(.caption2.weight(.heavy))
                    .monospacedDigit()
                    .lineLimit(1)
            } compactTrailing: {
                Text("\(context.state.player2SetsWon) \(shortName(context.attributes.player2Name))")
                    .font(.caption2.weight(.heavy))
                    .monospacedDigit()
                    .lineLimit(1)
            } minimal: {
                Text(minimalScore(state: context.state))
                    .font(.caption2.weight(.heavy))
                    .monospacedDigit()
            }
        }
    }
}

private func dynamicIslandStatus(state: MatchActivityAttributes.MatchState) -> String {
    if !state.pointScore.isEmpty {
        return "Ponto \(state.pointScore.replacingOccurrences(of: "-", with: " - "))"
    }
    if !state.gameScore.isEmpty {
        return "Games \(state.gameScore)"
    }
    return state.status.isEmpty ? "Aguardando atualização" : state.status
}

private func minimalScore(state: MatchActivityAttributes.MatchState) -> String {
    if !state.pointScore.isEmpty {
        return state.pointScore
            .split(separator: "-")
            .last
            .map(String.init) ?? "\(state.player1SetsWon)-\(state.player2SetsWon)"
    }
    return "\(state.player1SetsWon)-\(state.player2SetsWon)"
}

private struct LockScreenView: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.MatchState

    var body: some View {
        VStack(spacing: 10) {
            header
            scoreRow
            if !state.setScores.isEmpty {
                SetTable(state: state, compact: false)
            }
        }
        .padding(14)
        .background(surfaceGradient)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if state.isLive {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
            }
            Text(headerLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var headerLine: String {
        var parts: [String] = []
        if !attributes.tournamentName.isEmpty { parts.append(attributes.tournamentName) }
        if !attributes.roundLabel.isEmpty { parts.append(attributes.roundLabel) }
        return parts.joined(separator: " · ")
    }

    private var scoreRow: some View {
        HStack(alignment: .center, spacing: 10) {
            playerSide(
                name: attributes.player1Name,
                flag: attributes.player1Flag,
                rank: attributes.player1Rank,
                sets: state.player1SetsWon,
                isServing: state.serverIsPlayerOne == true,
                trailing: false
            )

            VStack(spacing: 2) {
                if state.isLive {
                    Text("Set \(state.currentSetIndex + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                    if !state.pointScore.isEmpty {
                        Text(state.pointScore.replacingOccurrences(of: "-", with: " - "))
                            .font(.callout.weight(.heavy))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                } else {
                    Text(state.status.isEmpty ? "FINAL" : state.status.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(minWidth: 60)

            playerSide(
                name: attributes.player2Name,
                flag: attributes.player2Flag,
                rank: attributes.player2Rank,
                sets: state.player2SetsWon,
                isServing: state.serverIsPlayerOne == false,
                trailing: true
            )
        }
    }

    private func playerSide(name: String, flag: String, rank: Int?, sets: Int, isServing: Bool, trailing: Bool) -> some View {
        let info = VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            HStack(spacing: 4) {
                if !trailing, !flag.isEmpty {
                    Text(flag).font(.caption)
                }
                if let rank, !trailing {
                    Text("\(rank)").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                }
                Text(shortName(name))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let rank, trailing {
                    Text("\(rank)").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                }
                if trailing, !flag.isEmpty {
                    Text(flag).font(.caption)
                }
            }
            if isServing {
                Text("Saque")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color(red: 0.85, green: 0.95, blue: 0.30))
            }
        }

        let bigNumber = Text("\(sets)")
            .font(.system(size: 32, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)

        return HStack(spacing: 8) {
            if trailing {
                info
                bigNumber
            } else {
                bigNumber
                info
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private var surfaceGradient: LinearGradient {
        if let colors = slamGradientColors(for: attributes.slamTheme ?? "") {
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        let surface = attributes.surface.lowercased()
        let colors: [Color]
        if surface.contains("grass") || surface.contains("grama") {
            colors = [Color(red: 0.28, green: 0.58, blue: 0.30), Color(red: 0.08, green: 0.28, blue: 0.14)]
        } else if surface.contains("clay") || surface.contains("saibro") {
            colors = [Color(red: 0.78, green: 0.42, blue: 0.26), Color(red: 0.42, green: 0.18, blue: 0.10)]
        } else if surface.contains("hard") || surface.contains("dura") {
            colors = [Color(red: 0.22, green: 0.45, blue: 0.72), Color(red: 0.06, green: 0.18, blue: 0.38)]
        } else {
            colors = [Color(red: 0.20, green: 0.24, blue: 0.32), Color(red: 0.06, green: 0.09, blue: 0.16)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func slamGradientColors(for slamTheme: String) -> [Color]? {
        switch slamTheme {
        case "australianOpen":
            return [
                Color(red: 0.00, green: 0.50, blue: 0.80),
                Color(red: 0.00, green: 0.30, blue: 0.58),
                Color(red: 0.00, green: 0.17, blue: 0.36)
            ]
        case "rolandGarros":
            return [
                Color(red: 0.74, green: 0.27, blue: 0.16),
                Color(red: 0.50, green: 0.16, blue: 0.10),
                Color(red: 0.27, green: 0.09, blue: 0.06)
            ]
        case "wimbledon":
            return [
                Color(red: 0.00, green: 0.36, blue: 0.22),
                Color(red: 0.12, green: 0.17, blue: 0.32),
                Color(red: 0.22, green: 0.10, blue: 0.36)
            ]
        case "usOpen":
            return [
                Color(red: 0.16, green: 0.47, blue: 0.73),
                Color(red: 0.07, green: 0.26, blue: 0.50),
                Color(red: 0.03, green: 0.12, blue: 0.30)
            ]
        default:
            return nil
        }
    }
}

private struct SetTable: View {
    let state: MatchActivityAttributes.MatchState
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            ForEach(Array(state.setScores.enumerated()), id: \.offset) { index, set in
                VStack(spacing: 2) {
                    Text("\(index + 1)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(set.player1Games)
                        .font(.caption2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(set.player2Games)
                        .font(.caption2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(minWidth: 16)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct DI_PlayerLabel: View {
    let name: String
    let flag: String
    let rank: Int?
    let isServing: Bool
    let alignTrailing: Bool

    var body: some View {
        HStack(spacing: 4) {
            if alignTrailing {
                if isServing { servingDot }
                if let rank { rankText(rank) }
                nameText
                if !flag.isEmpty { Text(flag).font(.caption2) }
            } else {
                if !flag.isEmpty { Text(flag).font(.caption2) }
                nameText
                if let rank { rankText(rank) }
                if isServing { servingDot }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignTrailing ? .trailing : .leading)
    }

    private var nameText: some View {
        Text(shortName(name))
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func rankText(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.7))
    }

    private var servingDot: some View {
        Circle()
            .fill(Color(red: 0.85, green: 0.95, blue: 0.30))
            .frame(width: 6, height: 6)
    }
}

private struct DI_CenterScore: View {
    let attributes: MatchActivityAttributes
    let state: MatchActivityAttributes.MatchState

    var body: some View {
        VStack(spacing: 3) {
            Text(attributes.tournamentName.isEmpty ? "Match Point" : attributes.tournamentName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)

            Text(centerText)
                .font(.headline.monospacedDigit().weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(state.isLive ? "Set \(state.currentSetIndex + 1)" : state.status.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
        }
    }

    private var centerText: String {
        if !state.pointScore.isEmpty {
            return state.pointScore.replacingOccurrences(of: "-", with: " - ")
        }
        if !state.gameScore.isEmpty {
            return state.gameScore
        }
        return "\(state.player1SetsWon)-\(state.player2SetsWon)"
    }
}

private func shortName(_ name: String) -> String {
    let parts = name.split(separator: " ").map(String.init)
    guard parts.count >= 2, let firstInitial = parts.first?.first else { return name }
    return "\(firstInitial). \(parts.last ?? "")"
}
