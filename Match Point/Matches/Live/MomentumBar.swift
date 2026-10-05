import SwiftUI

// MARK: - Momentum Bar
//
// Horizontal strip of the last ~10 points, each cell colored by which side
// won. Falls back to a heuristic when the provider doesn't populate
// `pointWinnerName` — the whole row is then flagged as "estimado" so the
// user knows to trust it a little less than a confirmed feed.

struct MomentumBar: View {
    let points: [MomentumPoint]
    let player1ShortName: String
    let player2ShortName: String
    var maxCells: Int = 10

    private var displayCells: [MomentumPoint] {
        Array(points.suffix(maxCells))
    }

    private var player1Wins: Int {
        displayCells.filter { $0.side == .player1 }.count
    }

    private var player2Wins: Int {
        displayCells.filter { $0.side == .player2 }.count
    }

    private var isEstimated: Bool {
        !displayCells.isEmpty && displayCells.allSatisfy(\.isEstimated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Últimos \(displayCells.count) pontos")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                Spacer()
                if !displayCells.isEmpty {
                    Text("\(player1ShortName) \(player1Wins) × \(player2Wins) \(player2ShortName)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.readableSecondary)
                }
                if isEstimated {
                    Text("ESTIMADO")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.20))
                        .foregroundStyle(.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .accessibilityLabel("Momentum estimado, provedor não confirmou o vencedor dos pontos")
                }
            }

            HStack(spacing: 3) {
                if displayCells.isEmpty {
                    ForEach(0..<maxCells, id: \.self) { _ in
                        cell(for: .unknown)
                    }
                } else {
                    ForEach(displayCells) { point in
                        cell(for: point.side)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: displayCells)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func cell(for side: MomentumSide) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color(for: side))
            .frame(height: 10)
            .frame(maxWidth: .infinity)
    }

    private func color(for side: MomentumSide) -> Color {
        switch side {
        case .player1: return .blue
        case .player2: return .orange
        case .unknown: return Color.white.opacity(0.12)
        }
    }

    private var accessibilityLabel: String {
        guard !displayCells.isEmpty else { return "Sem histórico de pontos recentes" }
        let base = "\(player1ShortName) venceu \(player1Wins) dos últimos \(displayCells.count) pontos, \(player2ShortName) venceu \(player2Wins)"
        return isEstimated ? "\(base). Valores estimados." : base
    }
}
