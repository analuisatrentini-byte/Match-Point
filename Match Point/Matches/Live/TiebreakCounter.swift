import SwiftUI

// MARK: - Tie-break Counter
//
// Compact banner shown above the scoreboard whenever a match is in a
// tie-break. Renders the mini-break score derived from `pointScore` and
// marks the current server side so users can read "who serves next" at a
// glance without opening the match detail sheet.

struct TiebreakCounter: View {
    let player1Name: String
    let player2Name: String
    let pointScore: String
    let serverName: String

    private var parsedPoints: (String, String) {
        let parts = pointScore
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2 else { return ("0", "0") }
        return (parts[0], parts[1])
    }

    private var isPlayer1Serving: Bool {
        !serverName.isEmpty && serverName == player1Name
    }

    private var isPlayer2Serving: Bool {
        !serverName.isEmpty && serverName == player2Name
    }

    private var subtitle: String {
        let (p1, p2) = parsedPoints
        let diff = abs((Int(p1) ?? 0) - (Int(p2) ?? 0))
        if diff >= 2 {
            let leader = (Int(p1) ?? 0) > (Int(p2) ?? 0) ? player1Name : player2Name
            return "\(leader) com dois de vantagem — a um mini-break do set."
        }
        return "Cada mini-break pesa dobrado. Ganhar 2 seguidos vira o set."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(.yellow)
                Text("TIE-BREAK")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.yellow)
                Spacer()
            }

            HStack(alignment: .center, spacing: 16) {
                sideBlock(name: player1Name, score: parsedPoints.0, isServing: isPlayer1Serving)
                Text("×")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                sideBlock(name: player2Name, score: parsedPoints.1, isServing: isPlayer2Serving)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.yellow.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tie-break \(parsedPoints.0) a \(parsedPoints.1)")
    }

    private func sideBlock(name: String, score: String, isServing: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if isServing {
                    Image(systemName: "tennisball.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Text(name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Text(score)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}
