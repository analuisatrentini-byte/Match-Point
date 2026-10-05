import SwiftUI

// MARK: - Why Watch Now Card
//
// Compact card that only appears when the match is actually dramatic
// (break/set/match point, tie-break, swing in progress, or high overall
// pressure). Tapping it opens the full `MatchBrainDetailSheet` — the old
// dense narrative used to live inline; the sheet keeps the info reachable
// without cluttering the scoreboard on quieter moments.

struct WhyWatchNowCard: View {
    let moment: WhyWatchNowMoment
    let onOpenDetail: () -> Void

    private var tint: Color {
        switch moment.tintName {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        default: return .orange
        }
    }

    var body: some View {
        Button(action: onOpenDetail) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: moment.icon)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.16), in: Circle())
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ASSISTENTE DA PARTIDA")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(tint)
                        Text(moment.headline)
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(.white)
                        Text(moment.detail)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                }

                Text("Abrir leitura completa")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.16), in: Capsule())
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Abre análise completa da partida")
    }
}

// MARK: - Match Brain Detail Sheet

struct MatchBrainDetailSheet: View {
    let narrative: MatchBrainNarrative
    let liveContext: PremiumLiveContext
    let pressureLabel: String
    let pressureScore: Double

    private var pressureTint: Color {
        switch pressureScore {
        case 0.80...: return .red
        case 0.55..<0.80: return .orange
        case 0.35..<0.55: return .yellow
        default: return .green
        }
    }

    private var pressurePercent: Int {
        Int((pressureScore * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroBlock
                    decisionPath
                    impactGrid
                    signalsBlock
                    glossaryBlock
                    actionBlock
                }
                .padding()
            }
            .appleSportsBackground(.clay)
            .navigationTitle("Assistente da partida")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(pressureTint.opacity(0.16))
                        .frame(width: 56, height: 56)
                    Image(systemName: "brain.head.profile")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(pressureTint)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(pressureLabel.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(pressureTint)
                    Text(liveContext.headline)
                        .font(.title3.weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(liveContext.detail)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 0) {
                    Text("\(pressurePercent)")
                        .font(.system(.title, design: .rounded, weight: .heavy))
                        .monospacedDigit()
                    Text("PRESSÃO")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.readableSecondary)
                }
                .foregroundStyle(pressureTint)
                .accessibilityLabel("Pressão \(pressurePercent) de 100")
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(pressureTint)
                        .frame(width: max(8, proxy.size.width * pressureScore))
                }
            }
            .frame(height: 8)

            if !liveContext.chips.isEmpty {
                FlowTagRow(items: liveContext.chips)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(pressureTint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(pressureTint.opacity(0.28), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }

    private var decisionPath: some View {
        section(title: "Leitura da IA") {
            VStack(spacing: 10) {
                storyStep(number: "1", title: "Agora", body: narrative.headline, tint: pressureTint)
                storyStep(number: "2", title: "Ponto de virada", body: narrative.turningPoint, tint: .orange)
                storyStep(number: "3", title: "Por que importa", body: narrative.whyItMatters, tint: .green)
            }
        }
    }

    @ViewBuilder
    private var impactGrid: some View {
        let impacts = impactItems
        if !impacts.isEmpty || !narrative.keyStats.isEmpty {
            section(title: "Impacto") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(impacts) { item in
                        insightCard(icon: item.icon, title: item.title, body: item.body, tint: item.tint)
                    }
                    if !narrative.keyStats.isEmpty {
                        FlowTagRow(items: narrative.keyStats)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var signalsBlock: some View {
        if !narrative.advancedSignals.isEmpty {
            section(title: "Sinais avançados") {
                VStack(spacing: 8) {
                    ForEach(Array(narrative.advancedSignals.enumerated()), id: \.offset) { _, signal in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.blue)
                                .frame(width: 18)
                            Text(signal)
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var glossaryBlock: some View {
        if !narrative.glossaryInsights.isEmpty {
            section(title: "Glossário do momento") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(narrative.glossaryInsights) { insight in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(insight.term)
                                .font(.caption.weight(.bold))
                            Text(insight.explanation)
                                .font(.caption2)
                                .foregroundStyle(Color.readableSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private var actionBlock: some View {
        Label(liveContext.nextBestAction, systemImage: "sparkles")
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pressureTint.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("match-brain-next-action")
    }

    private func storyStep(number: String, title: String, body: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(tint, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(tint)
                Text(body)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func insightCard(icon: String, title: String, body: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(tint)
                Text(body)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var impactItems: [MatchBrainImpactItem] {
        var items: [MatchBrainImpactItem] = []
        if let rankingImpact = narrative.rankingImpact {
            items.append(MatchBrainImpactItem(icon: "chart.line.uptrend.xyaxis", title: "Ranking", body: rankingImpact, tint: .green))
        }
        if let projection = narrative.liveRankingProjection {
            items.append(MatchBrainImpactItem(icon: "number.circle.fill", title: "Projeção", body: projection, tint: .blue))
        }
        return items
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color.readableSecondary)
            content()
        }
    }
}

private struct MatchBrainImpactItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
    let tint: Color
}
