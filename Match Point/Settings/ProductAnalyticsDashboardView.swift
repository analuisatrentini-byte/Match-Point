import SwiftUI

struct ProductAnalyticsDashboardView: View {
    let snapshot: ProductAnalyticsSnapshot

    private var funnelRows: [(String, Bool, String)] {
        [
            ("Onboarding concluído", snapshot.completedOnboarding, ProductAnalyticsEventName.onboardingCompleted),
            ("Jogador favorito escolhido", snapshot.pickedFavoritePlayer, ProductAnalyticsEventName.favoritePlayerChosen),
            ("Home do jogador aberta", snapshot.openedPlayerHome, ProductAnalyticsEventName.playerHomeViewed),
            ("Alertas aceitos", snapshot.acceptedAlerts, ProductAnalyticsEventName.alertPermissionAccepted),
            ("Widget instalado", snapshot.installedWidget, ProductAnalyticsEventName.widgetInstalled),
            ("Live Activity iniciada", snapshot.startedLiveActivity, ProductAnalyticsEventName.liveActivityStarted),
            ("Partida aberta via push", snapshot.openedMatchFromPush, ProductAnalyticsEventName.matchOpenedFromPush)
        ]
    }

    var body: some View {
        List {
            Section("Funil") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Etapas concluídas")
                        Spacer()
                        Text("\(snapshot.funnelCompletionCount)/\(snapshot.funnelStepCount)")
                            .font(.headline.monospacedDigit())
                    }
                    ForEach(funnelRows, id: \.2) { row in
                        LabeledContent {
                            Text(row.1 ? "OK" : "Pendente")
                                .foregroundStyle(row.1 ? .green : Color.readableSecondary)
                        } label: {
                            Label(row.0, systemImage: row.1 ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
                .appListCardRow()
            }

            Section("Retenção") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Primeiro uso", value: snapshot.firstSeenAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Último uso", value: snapshot.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Dias ativos", value: "\(snapshot.launchDays.count)")
                    LabeledContent("Sessões", value: "\(snapshot.sessionCount)")
                    LabeledContent("D1", value: snapshot.retainedD1 ? "Retido" : "Pendente")
                    LabeledContent("D7", value: snapshot.retainedD7 ? "Retido" : "Pendente")
                    LabeledContent("D30", value: snapshot.retainedD30 ? "Retido" : "Pendente")
                }
                .appListCardRow()
            }

            Section("Drivers de retorno") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Voltas por widget", value: "\(snapshot.widgetReturnCount)")
                    LabeledContent("Voltas por alerta", value: "\(snapshot.alertReturnCount)")
                    LabeledContent("Calendário aberto", value: "\(snapshot.calendarOpenCount)")
                    LabeledContent("Partidas via calendário", value: "\(snapshot.calendarMatchOpenCount)")
                    LabeledContent("Match Brain aberto", value: "\(snapshot.matchBrainOpenCount)")
                    LabeledContent("Partidas via Match Brain", value: "\(snapshot.matchBrainMatchOpenCount)")
                }
                .appListCardRow()
            }

            Section("Contadores") {
                ForEach(snapshot.counters.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(key, value: "\(value)")
                        .appListCardRow()
                }
            }

            Section("Eventos recentes") {
                ForEach(snapshot.events.sorted { $0.occurredAt > $1.occurredAt }.prefix(20)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.name)
                            .font(.headline)
                        Text(event.occurredAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                        if !event.properties.isEmpty {
                            Text(event.properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(Color.readableSecondary)
                                .lineLimit(2)
                        }
                    }
                    .appListCardRow()
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Observabilidade")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
