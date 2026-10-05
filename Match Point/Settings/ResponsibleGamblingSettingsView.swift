import SwiftUI
import SwiftData

// MARK: - ResponsibleGamblingSettingsView
//
// Tela dedicada onde o usuário configura seus próprios limites de uso do
// assistente de previsões. É o único ponto de configuração — nenhum limite é
// imposto por default (opt-in explícito), mas todos os avisos passivos
// (aviso de risco na primeira previsão, disclaimer de pontos simbólicos)
// continuam ativos mesmo sem nada configurado aqui.

struct ResponsibleGamblingSettingsView: View {
    @EnvironmentObject private var store: ResponsibleGamblingStore
    @Query(sort: \PointBet.createdAt, order: .reverse) private var bets: [PointBet]

    @State private var dailyStakeLimitInput: String = ""
    @State private var weeklyStakeLimitInput: String = ""
    @State private var dailyBetCountInput: String = ""
    @State private var lossCooldownThresholdInput: String = ""
    @State private var lossCooldownHoursInput: String = ""
    @State private var selfExclusionDays: Int = 7
    @State private var showSelfExclusionConfirmation = false
    @State private var showSupportSheet = false

    var body: some View {
        Form {
            introSection
            statusSection
            limitsSection
            cooldownSection
            selfExclusionSection
            helpSection
        }
        .navigationTitle("Uso responsável")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear(perform: hydrateInputs)
        .sheet(isPresented: $showSupportSheet) {
            NavigationStack {
                ResponsibleGamblingSupportView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fechar") { showSupportSheet = false }
                        }
                    }
            }
        }
        .confirmationDialog(
            "Auto-excluir por \(selfExclusionDays) dia(s)?",
            isPresented: $showSelfExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ativar auto-exclusão", role: .destructive) {
                store.triggerSelfExclusion(days: selfExclusionDays)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Enquanto o período estiver ativo, nenhuma nova previsão poderá ser criada. Não é possível desfazer antes do término.")
        }
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Uso simbólico", systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.teal)
                Text("O assistente usa pontos simbólicos que não valem dinheiro real. Mesmo assim, você pode configurar limites pessoais aqui — o app respeita a decisão e bloqueia novas previsões fora do que você estabeleceu.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            let dailyUse = dailyStakeUse
            let weeklyUse = weeklyStakeUse
            let dailyBets = betsToday

            statusRow(icon: "sun.max", title: "Usado hoje", value: "\(dailyUse) pts")
            statusRow(icon: "calendar", title: "Usado nesta semana", value: "\(weeklyUse) pts")
            statusRow(icon: "number.square", title: "Previsões hoje", value: "\(dailyBets)")

            if let until = store.preferences.selfExclusionUntil, until > .now {
                statusRow(
                    icon: "lock.shield.fill",
                    title: "Auto-exclusão ativa até",
                    value: until.formatted(date: .abbreviated, time: .shortened),
                    tint: .red
                )
            }
        } header: {
            Text("Uso recente")
        }
    }

    private func statusRow(icon: String, title: String, value: String, tint: Color = .primary) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(tint)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    // MARK: - Limits

    private var limitsSection: some View {
        Section {
            limitField(
                title: "Limite diário (pts)",
                placeholder: "Sem limite",
                text: $dailyStakeLimitInput,
                accessibilityID: "responsible-daily-stake-limit"
            ) { newValue in
                store.update { $0.dailyStakeLimit = newValue }
            }

            limitField(
                title: "Limite semanal (pts)",
                placeholder: "Sem limite",
                text: $weeklyStakeLimitInput,
                accessibilityID: "responsible-weekly-stake-limit"
            ) { newValue in
                store.update { $0.weeklyStakeLimit = newValue }
            }

            limitField(
                title: "Máx. de previsões por dia",
                placeholder: "Sem limite",
                text: $dailyBetCountInput,
                accessibilityID: "responsible-daily-bet-count"
            ) { newValue in
                store.update { $0.dailyBetCountLimit = newValue }
            }
        } header: {
            Text("Limites")
        } footer: {
            Text("Deixe em branco para não aplicar limite. Novas previsões que ultrapassem o valor configurado serão bloqueadas até o próximo período.")
        }
    }

    // MARK: - Cooldown

    private var cooldownSection: some View {
        Section {
            limitField(
                title: "Depois de N derrotas seguidas",
                placeholder: "Desativado",
                text: $lossCooldownThresholdInput,
                accessibilityID: "responsible-cooldown-threshold"
            ) { newValue in
                store.update { $0.lossCooldownThreshold = newValue }
            }

            limitField(
                title: "Pausar por quantas horas",
                placeholder: "0",
                text: $lossCooldownHoursInput,
                accessibilityID: "responsible-cooldown-hours"
            ) { newValue in
                store.update { $0.lossCooldownHours = newValue }
            }
        } header: {
            Text("Cooldown após perdas")
        } footer: {
            Text("Se ambos os campos estiverem preenchidos, o app pausa novas previsões quando você acumular a sequência de derrotas escolhida.")
        }
    }

    // MARK: - Self-exclusion

    private var selfExclusionSection: some View {
        Section {
            Stepper(value: $selfExclusionDays, in: 1...90) {
                LabeledContent("Auto-excluir por", value: "\(selfExclusionDays) dia(s)")
            }

            Button(role: .destructive) {
                showSelfExclusionConfirmation = true
            } label: {
                Label("Ativar auto-exclusão", systemImage: "lock.shield")
            }
            .accessibilityIdentifier("responsible-trigger-self-exclusion")
        } header: {
            Text("Pausa temporária")
        } footer: {
            Text("A auto-exclusão bloqueia o assistente de previsões por completo pelo período escolhido. Não é possível reverter antes do término — é essa a proteção do recurso.")
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            Button {
                showSupportSheet = true
            } label: {
                Label("Preciso de ajuda", systemImage: "hand.raised.fill")
            }
            .accessibilityIdentifier("responsible-open-support")
        } header: {
            Text("Ajuda")
        }
    }

    // MARK: - Field builder

    private func limitField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        accessibilityID: String,
        onCommit: @escaping (Int?) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: text)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .accessibilityIdentifier(accessibilityID)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        onCommit(nil)
                    } else if let parsed = Int(trimmed), parsed > 0 {
                        onCommit(parsed)
                    }
                }
        }
    }

    // MARK: - Aggregates

    private var dailyStakeUse: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return bets.filter { $0.createdAt >= start }.reduce(0) { $0 + $1.stake }
    }

    private var weeklyStakeUse: Int {
        let components = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        let start = Calendar.current.date(from: components) ?? Calendar.current.startOfDay(for: .now)
        return bets.filter { $0.createdAt >= start }.reduce(0) { $0 + $1.stake }
    }

    private var betsToday: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return bets.filter { $0.createdAt >= start }.count
    }

    private func hydrateInputs() {
        dailyStakeLimitInput = store.preferences.dailyStakeLimit.map(String.init) ?? ""
        weeklyStakeLimitInput = store.preferences.weeklyStakeLimit.map(String.init) ?? ""
        dailyBetCountInput = store.preferences.dailyBetCountLimit.map(String.init) ?? ""
        lossCooldownThresholdInput = store.preferences.lossCooldownThreshold.map(String.init) ?? ""
        lossCooldownHoursInput = store.preferences.lossCooldownHours.map(String.init) ?? ""
    }
}

// MARK: - Support sheet

private struct ResponsibleGamblingSupportView: View {
    var body: some View {
        List {
            Section {
                supportRow(
                    title: "Jogadores Anônimos Brasil",
                    detail: "jogadoresanonimos.org.br · reuniões online e presenciais em todo o país."
                )
                .appListCardRow()
                supportRow(
                    title: "CVV — Centro de Valorização da Vida",
                    detail: "Ligue 188 (24h) · cvv.org.br. Apoio emocional gratuito."
                )
                .appListCardRow()
                supportRow(
                    title: "SUS Cuida",
                    detail: "Procure uma UBS ou CAPS-AD (Centro de Atenção Psicossocial) para acompanhamento profissional gratuito."
                )
                .appListCardRow()
            } header: {
                Text("Canais de apoio no Brasil")
            } footer: {
                Text("Match Point não tem vínculo com essas organizações. Os contatos são referência pública. Se prever resultados ou apostar deixou de ser lazer, procure ajuda — não é fraqueza pedir suporte.")
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Preciso de ajuda")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func supportRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.bold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(.vertical, 2)
    }
}
