import SwiftUI

// Card estilo Sofascore mostrando probabilidade de vitória ao vivo de cada
// jogador. Consome `WinProbabilityEstimate` — se o modelo retornar nil (partida
// não-live ou sem sinal), o próprio card vira EmptyView pra não ocupar espaço.
struct WinProbabilityCard: View {
    let estimate: WinProbabilityEstimate
    let player1ShortName: String
    let player2ShortName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.teal)
                Text("Probabilidade ao vivo")
                    .font(.headline.weight(.heavy))
                Spacer()
                Text(estimate.bestOfFive ? "Melhor de 5" : "Melhor de 3")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
            }

            HStack(alignment: .center, spacing: 10) {
                probabilityColumn(
                    percent: estimate.player1Percent,
                    name: player1ShortName,
                    tint: .blue,
                    alignment: .leading
                )
                probabilityColumn(
                    percent: estimate.player2Percent,
                    name: player2ShortName,
                    tint: .orange,
                    alignment: .trailing
                )
            }

            GeometryReader { geo in
                let leftWidth = geo.size.width * CGFloat(estimate.player1Probability)
                HStack(spacing: 0) {
                    Capsule().fill(Color.blue)
                        .frame(width: leftWidth)
                    Capsule().fill(Color.orange)
                        .frame(width: geo.size.width - leftWidth)
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
                Text(estimate.primaryDriver)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(2)
            }

            Text("Modelo baseado no placar de sets, do set corrente e nos últimos pontos. Oscila conforme a partida evolui.")
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(14)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.20), lineWidth: 1)
        )
    }

    private func probabilityColumn(percent: Int, name: String, tint: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("\(percent)%")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(name)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color.readableSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}
