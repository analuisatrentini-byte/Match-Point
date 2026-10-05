//
//  SettingsView.swift
//  Match Point
//
//  Hub for identity, theme, privacy commitments, data export and account erasure.
//  Lives behind the Profile tab to keep one canonical entry point for "manage me".
//

import OSLog
import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("match-point.onboarding-completed") private var onboardingCompleted: Bool = true
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \PointBet.createdAt, order: .reverse) private var bets: [PointBet]

    @State private var exportShareItem: ExportShareItem?
    @State private var exportError: String?
    @State private var deletionConfirmation = false
    @State private var deletionResult: String?
    // syncStatus + isSyncing removidos — sync é automático, sem UI manual.
    @EnvironmentObject private var cloudBackend: CloudSocialBackend

    private var profile: UserProfile? { profiles.first }
    private var predictionStats: PredictionStats {
        PredictionStats(bets: bets)
    }

    private var currentTipsterPerformance: CloudTipsterPerformance {
        CloudTipsterPerformance(
            wins: predictionStats.won,
            losses: predictionStats.lost,
            currentStreak: predictionStats.currentStreak
        )
    }

    var body: some View {
        Form {
            // Layout consistente: cada sub-área com UI complexa é um NavLink
            // pra sua própria tela. Ações one-shot ficam inline. A separação
            // de severidade continua explícita via sections:
            //   • accountSection — reversível/seguro (export apenas).
            //   • dangerSection  — destrutivo/irreversível (excluir dados).
            accountIdentitySection
            alertsSection
            responsibleGamblingSection
            accountSection
            privacySection
            dangerSection
            aboutSection
        }
        .navigationTitle("Configurações")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .accessibilityIdentifier("settings-screen")
        .onAppear {
            refreshAccountPresentationState()
        }
        .sheet(item: $exportShareItem) { item in
#if os(iOS)
            ShareSheet(items: [item.url])
                .ignoresSafeArea()
#else
            EmptyView()
#endif
        }
        .alert("Excluir todos os meus dados?", isPresented: $deletionConfirmation) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir", role: .destructive, action: performDeletion)
        } message: {
            Text("Apaga seu perfil, predições, posts, votos e desativa todos os favoritos. Ação irreversível.")
        }
        .alert("Resultado", isPresented: Binding(
            get: { deletionResult != nil },
            set: { if !$0 { deletionResult = nil } }
        )) {
            Button("OK") { deletionResult = nil }
        } message: {
            Text(deletionResult ?? "")
        }
    }

    // MARK: - Top-level sections (hub)

    private var accountIdentitySection: some View {
        Section {
            LabeledContent("iCloud") {
                Text(cloudBackend.accountLabel)
                    .foregroundStyle(cloudAccountStatusColor)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                Task {
                    await cloudBackend.refreshAccountStatus()
                    refreshAccountPresentationState()
                    if let profile {
                        await cloudBackend.syncProfile(profile, performance: currentTipsterPerformance)
                    }
                }
            } label: {
                Label("Verificar conta", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("settings-refresh-account")
        } header: {
            Text("Conta")
        } footer: {
            Text("Usado para sincronizar avaliações, favoritos e ranking social. Para trocar de iCloud, altere a conta nos Ajustes do iOS e volte para verificar.")
        }
        .accessibilityIdentifier("settings-account-identity-section")
    }

    private var accountSection: some View {
        // O botão manual "Sincronizar dados agora" foi removido. O sync agora
        // é 100% automático em segundo plano (auto-sync via `.task` polling
        // + `BackgroundSyncScheduler`). O usuário NÃO precisa fazer nada pra
        // manter os dados atualizados — e nem deveria saber que existe esse
        // conceito. Sobrou só ação que faz sentido como decisão consciente:
        // exportar pra cumprir LGPD Art. 18.
        Section {
            Button { exportData() } label: {
                Label("Exportar meus dados", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("settings-export-data")

            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Conta")
        } footer: {
            Text("O app sincroniza torneios, jogadores e rankings automaticamente. A exportação gera uma cópia dos seus dados, como perfil, favoritos, previsões e avaliações.")
        }
    }

    private var dangerSection: some View {
        // Zona de perigo isolada. Footer LGPD reforça a irreversibilidade
        // ANTES do tap; o `.alert` de confirmação no body é a segunda barreira.
        Section {
            Button(role: .destructive) {
                deletionConfirmation = true
            } label: {
                Label("Excluir todos os meus dados", systemImage: "trash")
            }
            .accessibilityIdentifier("settings-delete-account")
        } header: {
            Text("Zona de perigo")
        } footer: {
            Text("Apaga perfil, previsões, avaliações, votos e desfavorita todos os jogadores/torneios/partidas. Ação irreversível — atende ao Art. 18 da LGPD (direito de erasure).")
        }
    }

    private var alertsSection: some View {
        Section {
            NavigationLink {
                AlertsConsolidatedView()
            } label: {
                Label("Alertas e notificações", systemImage: "bell.badge.fill")
            }
            .accessibilityIdentifier("alerts-link-consolidated")
        } header: {
            Text("Alertas e notificações")
        } footer: {
            Text("Permissão do sistema, tipos de evento, antecedência e alertas ao vivo — tudo numa tela.")
        }
    }

    // syncSection legacy removida — sync agora é 100% automático e não tem
    // mais botão manual no Settings.

    // onboardingSection legacy removida — substituída por `resetSection`
    // no topo do arquivo (header "Reset do fluxo", footer mais explícito
    // sobre o que NÃO é apagado).

    private var privacySection: some View {
        Section {
            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("Política de Privacidade", systemImage: "hand.raised.fill")
            }
            .accessibilityIdentifier("settings-privacy-link")
        } header: {
            Text("Privacidade")
        }
    }

    // Seção dedicada a uso responsável — auto-limites, cooldown por perdas e
    // auto-exclusão. Sempre visível (não gated por feature flag) porque é
    // proteção, não recurso opcional. Fica próxima do accountSection porque
    // reúne compromissos que o usuário assume consigo mesmo.
    private var responsibleGamblingSection: some View {
        Section {
            NavigationLink {
                ResponsibleGamblingSettingsView()
            } label: {
                Label("Limites e auto-exclusão", systemImage: "hand.raised.fill")
            }
            .accessibilityIdentifier("settings-responsible-gambling-link")
        } header: {
            Text("Uso responsável")
        } footer: {
            Text("Configure limites diários, semanais e pausas. As previsões usam pontos simbólicos, mas os controles ajudam a manter o uso saudável.")
        }
    }

    // dangerSection legacy removida — substituída pela nova versão no topo
    // do arquivo (com header "Zona de perigo" e footer LGPD mais explícito).

    private var cloudAccountStatusColor: Color {
        switch cloudBackend.state {
        case .ready:
            return .green
        case .loading:
            return .orange
        case .unavailable:
            return .red
        case .idle:
            return .secondary
        }
    }

    private func refreshAccountPresentationState() {
        if case .idle = cloudBackend.state {
            Task {
                await cloudBackend.refreshAccountStatus()
            }
        }
    }

    private func exportData() {
        exportError = nil
        do {
            let data = try DataExportService.makeExport(from: context)
            let url = try DataExportService.makeExportFileURL(data: data)
            exportShareItem = ExportShareItem(url: url)
        } catch {
            AppLogger.persistence.error("Data export failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "settings.exportData", error: error)
            exportError = "Não foi possível gerar o arquivo. \(AppLogger.message(for: error))"
        }
    }

    // syncNow() legacy removida — sync agora é responsabilidade exclusiva de
    // `AutoSyncTracker` + `BackgroundSyncScheduler`, sem UI manual.

    private func performDeletion() {
        Task {
            do {
                let summary = try await AccountDeletionService.deleteAllUserData(context: context, cloudBackend: cloudBackend)
                let remoteMessage = summary.backendAccountDeleted ? " Sua conta online também foi removida." : ""
                deletionResult = "Seus dados foram removidos deste aparelho e do iCloud. Favoritos desativados: \(summary.totalUnfavorited).\(remoteMessage)"
                onboardingCompleted = false
            } catch {
                AppLogger.persistence.error("Account deletion failed: \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "persistence", operation: "settings.deleteAccount", error: error)
                deletionResult = "Falha ao excluir: \(AppLogger.message(for: error))"
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Label("Versão", systemImage: "info.circle")
                Spacer()
                Text(Self.shortVersionString)
                    .foregroundStyle(Color.readableSecondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .accessibilityIdentifier("settings-version-row")
        } header: {
            Text("Sobre")
        }
    }

    private static var shortVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

}

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Editor sub-screens

struct IdentityEditorView: View {
    @Binding var draftName: String
    @Binding var draftAvatar: String
    let avatarOptions: [String]
    let onSave: () -> Void
    @State private var showSavedToast = false

    static let defaultAvatarOptions: [String] = [
        "person.crop.circle.fill",
        "tennisball.fill",
        "trophy.fill",
        "star.fill",
        "flag.fill",
        "bolt.fill"
    ]

    var body: some View {
        List {
            Section("Nome exibido") {
                TextField("Nome", text: $draftName)
#if os(iOS)
                    .textInputAutocapitalization(.words)
#endif
                    .accessibilityIdentifier("settings-display-name-field")
                    .appListCardRow()
            }

            Section("Avatar") {
                HStack {
                    Image(systemName: draftAvatar)
                        .font(.title2)
                        .foregroundStyle(.green)
                    Picker("Avatar", selection: $draftAvatar) {
                        ForEach(avatarOptions, id: \.self) { symbol in
                            Image(systemName: symbol).tag(symbol)
                        }
                    }
                }
                .appListCardRow()
            }

            Section {
                Button("Salvar") {
                    onSave()
                    withAnimation { showSavedToast = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { showSavedToast = false }
                    }
                }
                .accessibilityIdentifier("settings-save-identity")
                .appListCardRow()
            } footer: {
                Text("Seu nome e avatar aparecem no perfil, avaliações e rankings. Use a aba Perfil para criar conta, entrar ou recuperar acesso.")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Nome e avatar")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .appleSportsBackground(.royal)
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Label("Identidade salva", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSavedToast)
    }
}

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(CloudSocialBackend.previewStub())
            .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
                if case .success(let container) = result {
                    MatchPointPreviewData.seed(container)
                }
            }
    }
}
