import SwiftUI

struct LiveCourtPointView: View {
    let player1Name: String
    let player2Name: String
    let serverName: String
    let pointScore: String
    let gameScore: String
    let momentum: [MomentumPoint]
    let moment: WhyWatchNowMoment?
    let pulse: Bool

    private var serverSide: MomentumSide {
        side(for: serverName)
    }

    private var receiverSide: MomentumSide {
        switch serverSide {
        case .player1: return .player2
        case .player2: return .player1
        case .unknown: return latestMomentumSide
        }
    }

    private var latestMomentumSide: MomentumSide {
        momentum.last(where: { $0.side != .unknown })?.side ?? .player1
    }

    private var pressureTint: Color {
        switch moment?.kind {
        case .breakPoint, .matchPoint: return .red
        case .setPoint, .tiebreak: return .yellow
        case .comeback: return .purple
        case .highPressure: return .orange
        case nil: return .green
        }
    }

    private var currentPointText: String {
        if !pointScore.isEmpty { return pointScore }
        if !gameScore.isEmpty { return "Games \(gameScore)" }
        return "Ao vivo"
    }

    private var rallyTargetSide: MomentumSide {
        pulse ? receiverSide : serverSide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tennisball.fill")
                    .foregroundStyle(pressureTint)
                Text("QUADRA AO VIVO")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(pressureTint)
                Spacer()
                Text(currentPointText)
                    .font(.caption.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white)
            }

            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    courtSurface
                    courtLines
                    playerMarker(side: .player1, name: shortName(player1Name), isServing: serverSide == .player1)
                    playerMarker(side: .player2, name: shortName(player2Name), isServing: serverSide == .player2)
                    ball(in: size)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .aspectRatio(1.58, contentMode: .fit)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Label(serverName.isEmpty ? "Saque indefinido" : "Saque: \(serverName)", systemImage: "figure.tennis")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let moment {
                    Label(moment.headline, systemImage: moment.icon)
                        .lineLimit(1)
                        .foregroundStyle(pressureTint)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.readableSecondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.green.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(pressureTint.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var courtSurface: some View {
        LinearGradient(
            colors: [Color.green.opacity(0.55), Color.green.opacity(0.22)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var courtLines: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let line = Color.white.opacity(0.64)

            Path { path in
                let outer = CGRect(x: width * 0.08, y: height * 0.10, width: width * 0.84, height: height * 0.80)
                let singles = CGRect(x: width * 0.18, y: height * 0.10, width: width * 0.64, height: height * 0.80)
                path.addRect(outer)
                path.addRect(singles)
                path.move(to: CGPoint(x: width * 0.50, y: height * 0.10))
                path.addLine(to: CGPoint(x: width * 0.50, y: height * 0.90))
                path.move(to: CGPoint(x: width * 0.18, y: height * 0.36))
                path.addLine(to: CGPoint(x: width * 0.82, y: height * 0.36))
                path.move(to: CGPoint(x: width * 0.18, y: height * 0.64))
                path.addLine(to: CGPoint(x: width * 0.82, y: height * 0.64))
                path.move(to: CGPoint(x: width * 0.08, y: height * 0.50))
                path.addLine(to: CGPoint(x: width * 0.92, y: height * 0.50))
            }
            .stroke(line, lineWidth: 1.4)

            Rectangle()
                .fill(Color.white.opacity(0.82))
                .frame(width: width * 0.84, height: 2)
                .position(x: width * 0.50, y: height * 0.50)
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
        }
    }

    private func playerMarker(side: MomentumSide, name: String, isServing: Bool) -> some View {
        GeometryReader { proxy in
            let point = coordinate(for: side, in: proxy.size, isBall: false)
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(isServing ? Color.green : Color.white.opacity(0.20))
                        .frame(width: isServing ? 18 : 14, height: isServing ? 18 : 14)
                    if isServing {
                        Circle()
                            .stroke(Color.white.opacity(0.85), lineWidth: 1)
                            .frame(width: 24, height: 24)
                            .scaleEffect(pulse ? 1.12 : 0.94)
                            .opacity(pulse ? 0.28 : 0.70)
                    }
                }
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .position(point)
            .animation(.easeInOut(duration: 0.65), value: pulse)
        }
    }

    private func ball(in size: CGSize) -> some View {
        let point = coordinate(for: rallyTargetSide, in: size, isBall: true)
        return ZStack {
            Circle()
                .fill(pressureTint.opacity(0.22))
                .frame(width: 34, height: 34)
                .scaleEffect(pulse ? 1.18 : 0.82)
            Circle()
                .fill(Color.yellow)
                .frame(width: 12, height: 12)
                .shadow(color: pressureTint.opacity(0.8), radius: pulse ? 10 : 5)
        }
        .position(point)
        .animation(.easeInOut(duration: 0.65), value: pulse)
    }

    private func coordinate(for side: MomentumSide, in size: CGSize, isBall: Bool) -> CGPoint {
        let x: CGFloat
        switch side {
        case .player1: x = isBall ? 0.34 : 0.18
        case .player2: x = isBall ? 0.66 : 0.82
        case .unknown: x = 0.50
        }

        let y: CGFloat
        if isBall {
            y = side == .unknown ? 0.50 : (pulse ? 0.42 : 0.58)
        } else {
            y = side == .player1 ? 0.50 : 0.50
        }

        return CGPoint(x: size.width * x, y: size.height * y)
    }

    private func side(for value: String) -> MomentumSide {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let player1 = player1Name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let player2 = player2Name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unknown }
        if !player1.isEmpty && (player1.contains(normalized) || normalized.contains(player1)) {
            return .player1
        }
        if !player2.isEmpty && (player2.contains(normalized) || normalized.contains(player2)) {
            return .player2
        }
        return .unknown
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return name }
        return parts.last ?? name
    }

    private var accessibilityLabel: String {
        var parts = ["Quadra ao vivo", "ponto \(currentPointText)"]
        if !serverName.isEmpty { parts.append("saque de \(serverName)") }
        if let moment { parts.append(moment.headline) }
        return parts.joined(separator: ", ")
    }
}
