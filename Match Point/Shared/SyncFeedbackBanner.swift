//
//  Shared sync feedback UI.
//

import SwiftUI

struct SyncFeedbackBanner: View {
    let feedback: UserFacingSyncFeedback

    private var tint: Color {
        switch feedback.kind {
        case .configuration:
            return .orange
        case .rateLimited:
            return .red
        case .empty:
            return .blue
        case .generic:
            return .secondary
        }
    }

    private var icon: String {
        switch feedback.kind {
        case .configuration:
            return "key.fill"
        case .rateLimited:
            return "exclamationmark.triangle.fill"
        case .empty:
            return "tray.fill"
        case .generic:
            return "wifi.exclamationmark"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.title)
                    .font(.subheadline.weight(.semibold))
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                Text(feedback.recoverySuggestion)
                    .font(.caption)
                    .foregroundStyle(tint)
            }

            Spacer(minLength: 0)
        }
        .liquidGlassCard(cornerRadius: 18, padding: 14)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 6)
        }
        .accessibilityIdentifier("sync-feedback-banner")
    }
}

/// Indicador compacto "Atualizado há X min" para colocar nos headers das tabs
/// que sincronizam (Partidas, Torneios, Jogadores, Live Tracker). Single source
/// of truth: lê o último `markSynced` do `AutoSyncTracker` por `scope`. Atualiza
/// o label automaticamente a cada minuto via `TimelineView(.everyMinute)`.
///
/// Princípio Nielsen #1 (Visibility of system status): elimina a dúvida "será
/// que sincronizou?" — o usuário vê o estado em texto curto no header em vez
/// de precisar abrir Settings ou achar que existem 3 sincronizações paralelas.
struct SyncFreshnessLabel: View {
    let scope: AutoSyncTracker.Scope
    var isSyncing: Bool = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 4) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .imageScale(.small)
                }
                Text(label(now: context.date))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.readableSecondary)
            .accessibilityLabel("Última sincronização")
            .accessibilityValue(label(now: context.date))
        }
    }

    private func label(now: Date) -> String {
        if isSyncing { return "Sincronizando…" }
        guard let elapsed = AutoSyncTracker.timeSinceLastSync(scope, now: now) else {
            return "Não sincronizado"
        }
        switch elapsed {
        case ..<30:
            return "Agora há pouco"
        case ..<90:
            return "Há 1 min"
        case ..<3600:
            return "Há \(Int(elapsed / 60)) min"
        case ..<7200:
            return "Há 1 h"
        case ..<86_400:
            return "Há \(Int(elapsed / 3600)) h"
        default:
            return "Há \(Int(elapsed / 86_400)) d"
        }
    }
}
