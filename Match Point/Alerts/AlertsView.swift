import SwiftUI
import SwiftData
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Consolidated alerts screen

/// Tela única de alertas: todas as decisões de notificação em sequência lógica.
/// Substitui 3 sub-telas separadas (Status / Tipos / Alertas ao vivo) que obrigavam
/// o usuário a navegar 3 vezes para cobrir o fluxo básico "ativar + configurar".
struct AlertsConsolidatedView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var remotePushManager: RemotePushManager
    @State private var showDisableConfirmation = false
    @State private var showRebuildToast = false

    var body: some View {
        Form {
            // 1. Ghost state banner — primeiro porque bloqueia tudo abaixo.
            Section {
                SystemAlertsBlockedBanner()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            .listSectionSpacing(.compact)

            // 2. Permissão do sistema.
            Section("Permissão do sistema") {
                LabeledContent("Status") {
                    Text(statusLabel)
                        .foregroundStyle(statusColor)
                }
                if alertStore.authorizationStatus != .authorized {
                    Button("Permitir notificações") {
                        Task {
                            _ = await alertStore.requestAuthorization()
                            await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                            remotePushManager.registerForRemoteNotifications()
                        }
                    }
                    .accessibilityIdentifier("alerts-status-permitir")
                }
                if alertStore.authorizationStatus == .denied {
                    Text("Notificações bloqueadas pelo iOS. Reative em Ajustes para receber alertas.")
                        .font(.footnote)
                        .foregroundStyle(Color.readableSecondary)
                }
            }

            // 3. Toggle mestre + tipos de evento.
            Section {
                Toggle("Ativar alertas locais", isOn: masterToggleBinding)
            } footer: {
                Text("Mestre dos alertas. Quando desligado nenhum tipo abaixo dispara.")
            }
            .alert("Desativar todos os alertas?", isPresented: $showDisableConfirmation) {
                Button("Cancelar", role: .cancel) {}
                Button("Desativar", role: .destructive) {
                    Task {
                        alertStore.update { $0.notificationsEnabled = false }
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                }
            } message: {
                Text("Você não receberá lembretes antes da partida, walk-on, começo nem fim. Pode reativar a qualquer momento.")
            }

            Section("Eventos da partida") {
                Toggle("Avisar antes da partida", isOn: binding(\.notifyBeforeMatch))
                Toggle("Avisar quando entrar em quadra", isOn: binding(\.notifyMatchWalkOn))
                    .accessibilityIdentifier("alerts-walkon-toggle")
                Toggle("Avisar quando começar", isOn: binding(\.notifyMatchStarted))
                Toggle("Avisar quando terminar", isOn: binding(\.notifyMatchFinished))
            }

            Section("Antecedência") {
                Picker("Avisar com", selection: leadTimeBinding) {
                    Text("5 min antes").tag(5)
                    Text("15 min antes").tag(15)
                    Text("30 min antes").tag(30)
                    Text("60 min antes").tag(60)
                }
            }

            // 4. Quem dispara.
            Section("Quem dispara o alerta") {
                Toggle("Partidas favoritas", isOn: binding(\.followFavoriteMatches))
                Toggle("Jogadores favoritos", isOn: binding(\.followFavoritePlayers))
                Toggle("Torneios favoritos", isOn: binding(\.followFavoriteTournaments))
            }

            // 5. Reagendar.
            Section {
                Button("Recriar alertas agendados") {
                    Task {
                        await alertStore.refreshAuthorizationStatus()
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                        withAnimation { showRebuildToast = true }
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { showRebuildToast = false }
                    }
                }
                .accessibilityIdentifier("alerts-status-rebuild")
            } footer: {
                Text("Útil após mudar favoritos ou tipos — reagenda os pushs locais imediatamente.")
            }

            // 6. Alertas ao vivo.
            Section {
                LabeledContent("Notificações do aparelho") {
                    Text(remotePushManager.registrationState.label)
                        .foregroundStyle(apnsStatusColor)
                }
                Toggle("Alertas ao vivo dos favoritos", isOn: remotePushBackendBinding)
                    .accessibilityIdentifier("push-backend-toggle")
            } header: {
                Text("Alertas ao vivo")
            } footer: {
                Text("Quando ligado, o app avisa em tempo real sobre partidas e momentos importantes dos seus favoritos.")
            }
        }
        .navigationTitle("Alertas e notificações")
        .accessibilityIdentifier("alerts-screen")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .appleSportsBackground(.royal)
        .overlay(alignment: .bottom) {
            if showRebuildToast {
                Label("Alertas reagendados", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showRebuildToast)
        .task {
            await alertStore.refreshAuthorizationStatus()
            remotePushManager.refreshSystemState()
        }
        .onAppear {
            let validLeadTimes = [5, 15, 30, 60]
            if !validLeadTimes.contains(alertStore.preferences.leadTimeMinutes) {
                alertStore.update { $0.leadTimeMinutes = 15 }
            }
        }
    }

    private var statusLabel: String {
        switch alertStore.authorizationStatus {
        case .authorized: return "Ativa"
        case .denied: return "Negada"
        case .notDetermined: return "Pendente"
        case .provisional: return "Parcial"
        case .ephemeral: return "Temporária"
        @unknown default: return "Desconhecida"
        }
    }

    private var statusColor: Color {
        switch alertStore.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private var apnsStatusColor: Color {
        switch remotePushManager.registrationState {
        case .registered: return .green
        case .failed: return .red
        case .registering: return .orange
        case .idle: return .secondary
        }
    }

    private var leadTimeBinding: Binding<Int> {
        Binding(
            get: { alertStore.preferences.leadTimeMinutes },
            set: { newValue in
                alertStore.update { $0.leadTimeMinutes = newValue }
                Task { await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true) }
            }
        )
    }

    private var masterToggleBinding: Binding<Bool> {
        Binding(
            get: { alertStore.preferences.notificationsEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        if alertStore.authorizationStatus != .authorized {
                            let granted = await alertStore.requestAuthorization()
                            if !granted { return }
                        }
                        alertStore.update { $0.notificationsEnabled = true }
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                } else {
                    showDisableConfirmation = true
                }
            }
        )
    }

    private var remotePushBackendBinding: Binding<Bool> {
        Binding(
            get: { remotePushManager.backendSyncEnabled },
            set: { enabled in remotePushManager.setBackendSyncEnabled(enabled) }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<AlertPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { alertStore.preferences[keyPath: keyPath] },
            set: { newValue in
                Task {
                    alertStore.update { $0[keyPath: keyPath] = newValue }
                    await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                }
            }
        )
    }
}

// MARK: - Legacy sub-telas (mantidas para compatibilidade; Settings usa AlertsConsolidatedView)

// MARK: - Estado fantasma

/// Banner que aparece quando o usuário tem "Ativar alertas locais" ligado
/// nas preferências MAS o sistema iOS está bloqueando a entrega — estado
/// inconsistente que antes ficava invisível: usuário achava que estava
/// recebendo notificações, na verdade nada disparava.
///
/// Critério: `notificationsEnabled == true` E `authorizationStatus == .denied`.
/// Render: chamada em `AlertStatusSubView` e `AlertTypesSubView` (os 2 lugares
/// onde o usuário toma decisão sobre alertas).
struct SystemAlertsBlockedBanner: View {
    @EnvironmentObject private var alertStore: AlertPreferencesStore

    var shouldShow: Bool {
        alertStore.preferences.notificationsEnabled
            && alertStore.authorizationStatus == .denied
    }

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(.orange)
                    Text("Alertas bloqueados pelo iOS")
                        .font(.subheadline.weight(.bold))
                }
                Text("Você ativou alertas locais aqui no app, mas a permissão de notificação está negada nas Ajustes do iOS. Nenhuma notificação está sendo entregue até reativar.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
#if canImport(UIKit)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Abrir Ajustes do iOS", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .accessibilityIdentifier("alerts-blocked-open-settings")
#endif
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
            )
        }
    }
}

// MARK: - Sub-telas

/// Sub-tela "Status & Permissões" — concentra autorização do sistema, ação
/// imediata de pedir push, mensagem de bloqueio nas Ajustes do iOS, e o botão
/// "Recriar alertas agendados" que antes vivia solto no rodapé do hub.
struct AlertStatusSubView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var remotePushManager: RemotePushManager

    var body: some View {
        Form {
            // Banner do estado fantasma (toggle on + sistema denied). Aparece
            // antes de qualquer outra section pra ser a primeira coisa que o
            // usuário vê quando entrar em "Status & Permissões".
            Section {
                SystemAlertsBlockedBanner()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            .listSectionSpacing(.compact)

            Section("Permissão do sistema") {
                LabeledContent("Status") {
                    Text(statusLabel)
                        .foregroundStyle(statusColor)
                }

                if alertStore.authorizationStatus != .authorized {
                    Button("Permitir notificações") {
                        Task {
                            _ = await alertStore.requestAuthorization()
                            await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                            remotePushManager.registerForRemoteNotifications()
                        }
                    }
                    .accessibilityIdentifier("alerts-status-permitir")
                }

                if alertStore.authorizationStatus == .denied {
                    Text("As notificações estão desativadas no sistema. Reative em Ajustes para receber alertas.")
                        .font(.footnote)
                        .foregroundStyle(Color.readableSecondary)
                }
            }

            Section {
                Button("Recriar alertas agendados") {
                    Task {
                        await alertStore.refreshAuthorizationStatus()
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                }
                .accessibilityIdentifier("alerts-status-rebuild")
            } footer: {
                Text("Útil se você acabou de mudar tipos de alerta ou favoritos e quer reagendar os pushs locais imediatamente.")
            }
        }
        .navigationTitle("Status & Permissões")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .appleSportsBackground(.royal)
        .task {
            await alertStore.refreshAuthorizationStatus()
        }
    }

    private var statusLabel: String {
        switch alertStore.authorizationStatus {
        case .authorized: return "Ativa"
        case .denied: return "Negada"
        case .notDetermined: return "Pendente"
        case .provisional: return "Parcial"
        case .ephemeral: return "Temporária"
        @unknown default: return "Desconhecida"
        }
    }

    private var statusColor: Color {
        switch alertStore.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }
}

struct AlertTypesSubView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @State private var showDisableConfirmation = false

    var body: some View {
        Form {
            // Mesmo banner do Status — se o usuário entrar direto em "Tipos"
            // sem passar por "Status", precisa ver o estado fantasma aqui
            // também. Sem isso, ele toggleia tipos com o sistema bloqueado.
            Section {
                SystemAlertsBlockedBanner()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            .listSectionSpacing(.compact)

            Section {
                Toggle("Ativar alertas locais", isOn: masterToggleBinding)
            } footer: {
                Text("Mestre dos alertas locais. Quando desligado, nenhum tipo abaixo dispara.")
            }
            .alert("Desativar todos os alertas?", isPresented: $showDisableConfirmation) {
                Button("Cancelar", role: .cancel) { }
                Button("Desativar", role: .destructive) {
                    Task {
                        alertStore.update { $0.notificationsEnabled = false }
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                }
            } message: {
                Text("Você não receberá lembretes antes da partida, walk-on, começo nem fim. Pode reativar a qualquer momento aqui.")
            }

            Section("Eventos da partida") {
                Toggle("Avisar antes da partida", isOn: binding(\.notifyBeforeMatch))
                Toggle("Avisar quando entrar em quadra", isOn: binding(\.notifyMatchWalkOn))
                    .accessibilityIdentifier("alerts-walkon-toggle")
                Toggle("Avisar quando começar", isOn: binding(\.notifyMatchStarted))
                Toggle("Avisar quando terminar", isOn: binding(\.notifyMatchFinished))
            }

            Section("Antecedência") {
                Picker("Avisar com", selection: leadTimeBinding) {
                    Text("5 min antes").tag(5)
                    Text("15 min antes").tag(15)
                    Text("30 min antes").tag(30)
                    Text("60 min antes").tag(60)
                }
            }

            // "Quem seguir" foi consolidado aqui: alerta + quem-é-alertado
            // formam a mesma decisão. Forçar 2 telas separadas obrigava o
            // usuário a sair/voltar pra cobrir o caso comum "ativar walk-on
            // e seguir só Players favoritos".
            Section("Quem dispara o alerta") {
                Toggle("Partidas favoritas", isOn: binding(\.followFavoriteMatches))
                Toggle("Jogadores favoritos", isOn: binding(\.followFavoritePlayers))
                Toggle("Torneios favoritos", isOn: binding(\.followFavoriteTournaments))
            }
        }
        .navigationTitle("Tipos de alerta")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .appleSportsBackground(.royal)
        .onAppear {
            let validLeadTimes = [5, 15, 30, 60]
            if !validLeadTimes.contains(alertStore.preferences.leadTimeMinutes) {
                alertStore.update { $0.leadTimeMinutes = 15 }
            }
        }
    }

    private var leadTimeBinding: Binding<Int> {
        Binding(
            get: { alertStore.preferences.leadTimeMinutes },
            set: { newValue in
                alertStore.update { $0.leadTimeMinutes = newValue }
                Task {
                    await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                }
            }
        )
    }

    /// Binding especial pro toggle mestre. Quando o usuário tenta DESLIGAR,
    /// abre alerta de confirmação em vez de aplicar direto — evita que um tap
    /// acidental zere todos os alertas agendados (Error Prevention).
    private var masterToggleBinding: Binding<Bool> {
        Binding(
            get: { alertStore.preferences.notificationsEnabled },
            set: { newValue in
                if newValue {
                    // Ligar segue o caminho normal (que pode incluir pedir
                    // permissão do sistema se ainda não concedida).
                    Task {
                        if alertStore.authorizationStatus != .authorized {
                            let granted = await alertStore.requestAuthorization()
                            if !granted { return }
                        }
                        alertStore.update { $0.notificationsEnabled = true }
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                } else {
                    // Desligar pede confirmação.
                    showDisableConfirmation = true
                }
            }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<AlertPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { alertStore.preferences[keyPath: keyPath] },
            set: { newValue in
                Task {
                    if keyPath == \.notificationsEnabled, newValue, alertStore.authorizationStatus != .authorized {
                        let granted = await alertStore.requestAuthorization()
                        if !granted { return }
                    } else {
                        alertStore.update { $0[keyPath: keyPath] = newValue }
                    }
                    await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                }
            }
        )
    }
}

// AlertFollowFavoritesSubView foi removido — os 3 toggles "Partidas/Jogadores/
// Torneios favoritos" agora vivem dentro de AlertTypesSubView ("Quem dispara o
// alerta"). Sem callers órfãos.

struct AlertRemotePushSubView: View {
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var remotePushManager: RemotePushManager

    var body: some View {
        Form {
            Section("Estado") {
                LabeledContent("Notificações do aparelho") {
                    Text(remotePushManager.registrationState.label)
                        .foregroundStyle(statusColor(remotePushManager.registrationState))
                }
                LabeledContent("Alertas ao vivo") {
                    Text(remotePushManager.backendSyncState.label)
                        .foregroundStyle(remoteAlertStatusColor(remotePushManager.backendSyncState))
                }
#if DEBUG
                LabeledContent("Token") {
                    Text(remotePushManager.deviceToken.isEmpty ? "Ainda não disponível" : remotePushManager.deviceToken)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }
#endif
            }

            Section {
                Toggle("Alertas ao vivo dos favoritos", isOn: remotePushBackendBinding)
                    .accessibilityIdentifier("push-backend-toggle")
            } footer: {
                Text("Quando ligado, este aparelho recebe avisos em tempo real dos seus favoritos. Ao desligar, esses avisos deixam de chegar.")
            }

#if DEBUG
            Section("Diagnóstico local") {
                Button("Registrar notificações") {
                    if alertStore.authorizationStatus == .authorized {
                        remotePushManager.registerForRemoteNotifications()
                    } else {
                        Task {
                            let granted = await alertStore.requestAuthorization()
                            if granted { remotePushManager.registerForRemoteNotifications() }
                        }
                    }
                }
                .accessibilityIdentifier("push-register-apns")
            }
#endif

            Section("Privacidade dos alertas") {
                Label("Este aparelho usa um identificador privado para receber notificações.", systemImage: "lock.shield")
                Label("Ele é usado apenas para entregar alertas que você ativou.", systemImage: "checkmark.shield")
                Label("Ao desativar alertas ao vivo, este aparelho deixa de receber esses avisos.", systemImage: "bell.slash")
            }
        }
        .navigationTitle("Alertas ao vivo")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .appleSportsBackground(.royal)
        .task {
            remotePushManager.refreshSystemState()
        }
    }

    private var remotePushBackendBinding: Binding<Bool> {
        Binding(
            get: { remotePushManager.backendSyncEnabled },
            set: { enabled in remotePushManager.setBackendSyncEnabled(enabled) }
        )
    }

    private func statusColor(_ state: RemotePushManager.RegistrationState) -> Color {
        switch state {
        case .registered: return .green
        case .failed: return .red
        case .registering: return .orange
        case .idle: return .secondary
        }
    }

    private func remoteAlertStatusColor(_ state: RemotePushManager.BackendSyncState) -> Color {
        switch state {
        case .synced: return .green
        case .syncing: return .orange
        case .failed: return .red
        case .idle, .disabled: return .secondary
        }
    }
}
