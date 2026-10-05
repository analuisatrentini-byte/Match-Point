import SwiftData
import SwiftUI

struct ProviderDiagnosticsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloudBackend: CloudSocialBackend
    @StateObject private var healthTracker = ProviderHealthTracker.shared
    @State private var backendProxyDraft = ""
    @State private var backendWebSocketDraft = ""
    @State private var failureMetricsSnapshot: [FailureMetric] = []
    private let backendPlaceholder = "https://seu-backend.com/tennis"
    private let backendWebSocketPlaceholder = "wss://seu-backend.com/live"

    @State private var tournamentsStatus = "Idle"
    @State private var playersStatus = "Idle"
    @State private var liveStatus = "Idle"
    @State private var productionHealthStatus = "Não executado"
    @State private var pointTelemetryStatus = "Não executado"
    @State private var isChecking = false
    @State private var savedConfirmation: SavedConfirmation?
    @State private var dismissConfirmationTask: Task<Void, Never>?

    /// Captures what kind of configuration the user just persisted so the
    /// banner can show the concrete URL that will be used on the next
    /// request. The auto-dismiss timer in `presentConfirmation(...)` clears
    /// this after a few seconds — no need for the user to dismiss manually.
    private struct SavedConfirmation: Equatable {
        let detail: String
        let timestamp: Date
    }

    var body: some View {
        List {
            Section("Como usar agora") {
                Text("1. Configure o backend proxy. A chave da API Tennis fica somente no servidor.")
                Text("2. Configure o WebSocket do backend para live em tempo real.")
                Text("3. Use Health Check para validar REST, live e ponto a ponto.")
            }

            Section("Configuração") {
                TextField(backendPlaceholder, text: $backendProxyDraft)
#if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
#endif
                    .onChange(of: backendProxyDraft) { _, newValue in
                        if newValue.count > 2048 { backendProxyDraft = String(newValue.prefix(2048)) }
                    }

                TextField(backendWebSocketPlaceholder, text: $backendWebSocketDraft)
#if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
#endif
                    .onChange(of: backendWebSocketDraft) { _, newValue in
                        if newValue.count > 2048 { backendWebSocketDraft = String(newValue.prefix(2048)) }
                    }

                let trimmedProxy = backendProxyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedWebSocket = backendWebSocketDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let proxyURLValid = TennisAPIConfiguration.validatedBackendProxyURL(trimmedProxy) != nil
                let webSocketURLValid = trimmedWebSocket.isEmpty || TennisAPIConfiguration.validatedBackendWebSocketURL(trimmedWebSocket) != nil

                if !trimmedProxy.isEmpty, !proxyURLValid {
                    Label("Proxy REST deve usar https:// em produção ou http://localhost em Debug", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !trimmedWebSocket.isEmpty, !webSocketURLValid {
                    Label("Proxy WebSocket deve usar wss:// em produção ou ws://localhost em Debug", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Salvar backend") {
                    saveBackendConfiguration()
                }
                .disabled(trimmedProxy.isEmpty || !proxyURLValid || !webSocketURLValid)

                if let confirmation = savedConfirmation {
                    savedBanner(confirmation)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Section("Readiness") {
                LabeledContent("Status") {
                    Text(readiness.statusLabel)
                        .foregroundStyle(readiness.isReadyForSync ? .green : .orange)
                }

                Text(readiness.notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                LabeledContent("Atual") {
                    Text(TennisAPIConfiguration.selectedProviderDisplayName)
                }
                LabeledContent("Base URL") {
                    Text(configuredRestEndpointLabel)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Modo") {
                    Text("Backend proxy")
                        .foregroundStyle(readiness.isReadyForSync ? .green : .orange)
                }

                if !readiness.isReadyForSync {
                    Text("Configure o backend proxy antes de sincronizar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Endpoints") {
                diagnosticsRow(title: "REST", value: configuredRestEndpointLabel)
                diagnosticsRow(title: "WebSocket", value: configuredWebSocketEndpointLabel)
                diagnosticsRow(title: "Proxy REST", value: TennisAPIConfiguration.backendProxyBaseURL?.absoluteString ?? "Não configurado")
                diagnosticsRow(title: "Proxy WS", value: TennisAPIConfiguration.backendWebSocketBaseURL?.absoluteString ?? "Não configurado")
            }

            Section("Health Check") {
                diagnosticsRow(title: "Torneios", value: tournamentsStatus)
                diagnosticsRow(title: "Players", value: playersStatus)
                diagnosticsRow(title: "Live", value: liveStatus)
                diagnosticsRow(title: "Produção", value: productionHealthStatus)
                diagnosticsRow(title: "Ponto a ponto", value: pointTelemetryStatus)

                Button(isChecking ? "Verificando..." : "Executar diagnóstico") {
                    Task { await runDiagnostics() }
                }
                .disabled(isChecking || readiness.isReadyForSync == false)

                if readiness.isReadyForSync == false {
                    Text("Configure o backend proxy antes do diagnóstico.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Saúde do provider") {
                healthOverviewRow

                ForEach(ProviderHealthTracker.Scope.allCases) { scope in
                    scopeHealthRow(scope: scope, snapshot: healthTracker.snapshot(for: scope))
                }

                Button("Zerar telemetria") {
                    healthTracker.reset()
                }
                .accessibilityIdentifier("provider-health-reset")
            }

            Section("WebSocket em tempo real") {
                webSocketMonitorRows
            }

            if !healthTracker.fallbackLog.isEmpty {
                Section("Fallbacks recentes") {
                    ForEach(healthTracker.fallbackLog) { event in
                        fallbackLogRow(event)
                    }
                }
            }

            Section {
                if failureMetricsSnapshot.isEmpty {
                    Text("Nenhuma falha persistente registrada nos últimos 30 dias.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("failure-metrics-empty")
                } else {
                    ForEach(failureMetricsSnapshot) { metric in
                        failureMetricRow(metric)
                    }
                    Button("Zerar dashboard de falhas") {
                        UserDefaults.standard.removeObject(forKey: AppLogger.failureMetricsKey)
                        refreshFailureMetrics()
                    }
                    .accessibilityIdentifier("failure-metrics-reset")
                }
            } header: {
                Text("Métricas de falha (últimos 30 dias)")
            } footer: {
                Text("Contadores agregados por categoria.operação. Preenchido por AppLogger.recordFailure durante sync, live e persistência. Mensagens são sanitizadas (URLs, tokens, e-mails, UUIDs removidos).")
                    .font(.footnote)
            }

            Section("Observações") {
                Text("Players usa composição de várias fontes: endpoint dedicado, rankings e live matches.")
                Text("O WebSocket live usa a configuração do provider padrão API Tennis.")
                Text("Saúde do provider é atualizada a cada chamada REST, evento WebSocket e caminho de fallback.")
            }

            Section("Readiness de produção") {
                productionRow(
                    title: "API final",
                    isReady: productionHealthStatus.hasPrefix("OK"),
                    detail: productionHealthStatus.hasPrefix("OK") ? productionHealthStatus : "Execute Health Check usando o backend proxy de produção."
                )
                productionRow(
                    title: "Dados ponto a ponto",
                    isReady: pointTelemetryStatus.hasPrefix("OK"),
                    detail: pointTelemetryStatus.hasPrefix("OK") ? pointTelemetryStatus : "Precisa de live/fixtures com placar de ponto ou vencedor de ponto no payload."
                )
                productionRow(
                    title: "Backend contínuo",
                    isReady: hasAlwaysOnDataPlaneConfigured,
                    detail: hasAlwaysOnDataPlaneConfigured ? "REST e WebSocket passam pelo backend; contrato de ingestão contínua vai no payload de push." : "Configure proxy REST e WebSocket próprios; sync do device sozinho não cobre operação de mercado."
                )
                productionRow(
                    title: "Fila e auditoria",
                    isReady: hasAlwaysOnDataPlaneConfigured,
                    detail: hasAlwaysOnDataPlaneConfigured ? "Contrato exige dedupe server-side, fila at-least-once e histórico auditável de placares." : "Backend deve manter eventos, deduplicação e histórico de score fora do device."
                )
                productionRow(
                    title: "Push server-side",
                    isReady: hasAlwaysOnDataPlaneConfigured,
                    detail: hasAlwaysOnDataPlaneConfigured ? "Servidor fica dono da decisão de push; app envia token, favoritos e regras." : "RemotePushManager só registra token; o backend precisa decidir e disparar APNs automaticamente."
                )
                productionRow(
                    title: "Ranking oficial",
                    isReady: false,
                    detail: "Motor aceita snapshot oficial com pontos defendidos, pontos ganhos, race/live rank e projeção exata; falta conectar feed oficial no backend."
                )
                productionRow(
                    title: "Ranking global",
                    isReady: cloudBackend.leaderboardSource.isProductionGrade,
                    detail: globalRankingReadinessDetail
                )
                productionRow(
                    title: "CloudKit",
                    isReady: hasCloudKitEntitlement,
                    detail: cloudKitReadinessDetail
                )
                productionRow(
                    title: "CloudKit schema",
                    isReady: false,
                    detail: "Promover o schema CloudKit para produção no CloudKit Dashboard depois de validar records SocialPost, MatchPoll, LeaderboardEntry, SocialReport e PointBet."
                )
                productionRow(
                    title: "iCloud multi-conta",
                    isReady: false,
                    detail: "Validar em aparelho real com pelo menos duas contas iCloud: postar, responder, votar, leaderboard, denúncia, exclusão LGPD e fallback sem conta."
                )
                productionRow(
                    title: "CarPlay",
                    isReady: hasCarPlaySceneManifest,
                    detail: hasCarPlaySceneManifest ? "Scene configurada; ainda exige entitlement/aprovação Apple." : "Scene CarPlay não detectada."
                )
                productionRow(
                    title: "QA em aparelho",
                    isReady: false,
                    detail: "Precisa rodar no Xcode/simulador/aparelho com runtime iOS disponível."
                )
            }
        }
        .appleSportsBackground(.royal)
        .navigationTitle("Provider")
        .onAppear {
            loadConfiguration()
            refreshFailureMetrics()
        }
    }

    private func refreshFailureMetrics() {
        failureMetricsSnapshot = AppLogger.failureMetrics()
    }

    private var readiness: TennisAPIConfiguration.ProviderReadiness {
        TennisAPIConfiguration.providerReadiness(for: .apiTennis)
    }

    private var configuredRestEndpointLabel: String {
        TennisAPIConfiguration.backendProxyBaseURL?.absoluteString ?? "Não configurado"
    }

    private var configuredWebSocketEndpointLabel: String {
        TennisAPIConfiguration.backendWebSocketBaseURL?.absoluteString ?? "Não configurado"
    }

    @ViewBuilder
    private func diagnosticsRow(title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func productionRow(title: String, isReady: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isReady ? .green : .orange)
                Spacer()
                Text(isReady ? "Pronto" : "Pendente")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isReady ? .green : .orange)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hasAlwaysOnDataPlaneConfigured: Bool {
        TennisAPIConfiguration.backendProxyBaseURL != nil && TennisAPIConfiguration.backendWebSocketBaseURL != nil
    }

    private var hasCloudKitEntitlement: Bool {
        CloudSocialBackend.hasExpectedCloudKitContainerEntitlement
            && CloudSocialBackend.hasCloudKitServiceEntitlement
    }

    private var cloudKitReadinessDetail: String {
        let container = CloudSocialBackend.hasExpectedCloudKitContainerEntitlement
            ? "container \(CloudSocialBackend.expectedCloudKitContainerIdentifier) presente"
            : "container \(CloudSocialBackend.expectedCloudKitContainerIdentifier) ausente"
        let service = CloudSocialBackend.hasCloudKitServiceEntitlement
            ? "serviço CloudKit presente"
            : "serviço CloudKit ausente"
        return "\(container); \(service). Provisioning profile e ambiente Production ainda precisam ser validados no Apple Developer/Xcode."
    }

    private var globalRankingReadinessDetail: String {
        if cloudBackend.leaderboardSource.isProductionGrade {
            return "Ranking social confirmado via backend autoritativo baseado em apostas liquidadas."
        }
        if CloudSocialBackend.isSocialBackendConfigured {
            return "Backend social configurado, mas ainda não confirmado nesta sessão. Abra Perfil e carregue o ranking global."
        }
        return "Configure o backend social para evitar ranking público baseado apenas em pontos enviados pelo app."
    }

    private var hasCarPlaySceneManifest: Bool {
        Bundle.main.infoDictionary?["UIApplicationSceneManifest"] != nil
    }

    private func loadConfiguration() {
        TennisAPIConfiguration.purgeLegacyAPIKey()
        backendProxyDraft = TennisAPIConfiguration.backendProxyBaseURL?.absoluteString ?? ""
        backendWebSocketDraft = TennisAPIConfiguration.backendWebSocketBaseURL?.absoluteString ?? ""
        savedConfirmation = nil
        dismissConfirmationTask?.cancel()
    }

    private func saveBackendConfiguration() {
        let trimmedProxy = backendProxyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebSocket = backendWebSocketDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TennisAPIConfiguration.validatedBackendProxyURL(trimmedProxy) != nil,
              trimmedWebSocket.isEmpty || TennisAPIConfiguration.validatedBackendWebSocketURL(trimmedWebSocket) != nil else {
            savedConfirmation = nil
            return
        }
        TennisAPIConfiguration.setBackendProxyURL(trimmedProxy)
        TennisAPIConfiguration.setBackendWebSocketURL(trimmedWebSocket)
        resetDiagnostics()

        // Resolve the URLs the API will *actually* read on the next request
        // (rather than echoing the draft) — accounts for env-var overrides
        // and any normalization done inside TennisAPIConfiguration.
        let nextRest = TennisAPIConfiguration.restBaseURL.absoluteString
        let nextWS = TennisAPIConfiguration.webSocketBaseURL.absoluteString
        let detail = trimmedWebSocket.isEmpty
            ? "Próxima sincronização REST usará: \(nextRest)"
            : "Próxima sincronização usará REST: \(nextRest)\nWebSocket: \(nextWS)"
        presentConfirmation(detail)
    }

    private func presentConfirmation(_ detail: String) {
        savedConfirmation = SavedConfirmation(detail: detail, timestamp: .now)
        dismissConfirmationTask?.cancel()
        dismissConfirmationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            withAnimation { savedConfirmation = nil }
        }
    }

    @ViewBuilder
    private func savedBanner(_ confirmation: SavedConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Backend atualizado")
                    .font(.subheadline.weight(.semibold))
            }
            Text(confirmation.detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("provider-saved-confirmation")
    }

    private func resetDiagnostics() {
        tournamentsStatus = "Idle"
        playersStatus = "Idle"
        liveStatus = "Idle"
        productionHealthStatus = "Não executado"
        pointTelemetryStatus = "Não executado"
    }

    @MainActor
    private func runDiagnostics() async {
        isChecking = true
        defer { isChecking = false }

        let service = DataSyncService(context: context)

        do {
            try await service.syncTournaments()
            tournamentsStatus = "OK"
        } catch {
            tournamentsStatus = service.userFacingMessage(for: error)
        }

        do {
            try await service.syncPlayersAndRankings()
            playersStatus = "OK"
        } catch {
            playersStatus = service.userFacingMessage(for: error)
        }

        do {
            try await service.syncLiveMatches()
            liveStatus = "OK"
        } catch {
            liveStatus = service.userFacingMessage(for: error)
        }

        do {
            let report = try await service.validateProductionDataFeed()
            productionHealthStatus = "OK: \(report.summary)"
            pointTelemetryStatus = report.hasPointByPointTelemetry
                ? "OK: \(report.pointTelemetryCount) jogo(s) com telemetria"
                : "Pendente: API respondeu, mas sem ponto a ponto no payload atual"
        } catch {
            let message = service.userFacingMessage(for: error)
            productionHealthStatus = message
            pointTelemetryStatus = "Pendente: valide com evento live ativo"
        }
    }

    // MARK: - Health snapshot rendering

    @ViewBuilder
    private var healthOverviewRow: some View {
        let health = healthTracker.overallRestHealth
        HStack(spacing: 8) {
            Image(systemName: health.systemImage)
                .foregroundStyle(healthTint(health))
            VStack(alignment: .leading, spacing: 2) {
                Text("REST agregado")
                    .font(.subheadline.weight(.semibold))
                Text(healthDetail(health))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(health.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(healthTint(health))
        }
        .accessibilityIdentifier("provider-health-overall")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saúde REST agregada: \(health.label). \(healthDetail(health))")
    }

    @ViewBuilder
    private func scopeHealthRow(scope: ProviderHealthTracker.Scope, snapshot: ProviderHealthTracker.ScopeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.health.systemImage)
                    .foregroundStyle(healthTint(snapshot.health))
                Text(scope.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(snapshot.health.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(healthTint(snapshot.health))
            }
            HStack(spacing: 10) {
                Text("✓ \(snapshot.successCount)")
                Text("✗ \(snapshot.failureCount)")
                if snapshot.consecutiveFailures > 0 {
                    Text("seq falhas: \(snapshot.consecutiveFailures)")
                        .foregroundStyle(.orange)
                }
                if let average = snapshot.averageLatencyMillis {
                    Text("~\(average)ms")
                }
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let lastError = snapshot.lastErrorMessage, snapshot.failureCount > 0 {
                Text("Último erro: \(lastError)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if let lastSuccess = snapshot.lastSuccessAt {
                Text("Último sucesso: \(lastSuccess.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("provider-health-\(scope.rawValue)")
    }

    @ViewBuilder
    private var webSocketMonitorRows: some View {
        let monitor = healthTracker.webSocket
        LabeledContent("Estado") {
            Text(monitor.lastState)
                .foregroundStyle(monitor.isStreaming ? .green : .secondary)
        }
        LabeledContent("Frames recebidos") {
            Text("\(monitor.framesReceived)")
                .monospacedDigit()
        }
        LabeledContent("Stalls") {
            Text("\(monitor.stallEvents)")
                .monospacedDigit()
                .foregroundStyle(monitor.stallEvents > 0 ? .orange : .secondary)
        }
        LabeledContent("Reconexões") {
            Text("\(monitor.reconnectAttempts)")
                .monospacedDigit()
                .foregroundStyle(monitor.reconnectAttempts > 0 ? .orange : .secondary)
        }
        if let lastFrame = monitor.lastFrameAt {
            LabeledContent("Último frame") {
                Text(lastFrame.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
            }
        }
        if let close = monitor.lastCloseReason {
            LabeledContent("Última falha") {
                Text(close)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func failureMetricRow(_ metric: FailureMetric) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(metric.category).\(metric.operation)")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("×\(metric.count)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
            }
            if !metric.lastMessage.isEmpty {
                Text(metric.lastMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text("Última: \(metric.lastOccurredAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("failure-metric-\(metric.category).\(metric.operation)")
    }

    @ViewBuilder
    private func fallbackLogRow(_ event: ProviderHealthTracker.FallbackEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(event.scope.displayName)
                    .font(.caption.weight(.bold))
                Spacer()
                Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func healthTint(_ health: ProviderHealthTracker.Health) -> Color {
        switch health {
        case .idle: return .secondary
        case .healthy: return .green
        case .degraded: return .orange
        case .failing: return .red
        }
    }

    private func healthDetail(_ health: ProviderHealthTracker.Health) -> String {
        switch health {
        case .idle:
            return "Nenhuma chamada realizada nesta sessão."
        case .healthy:
            return "Todos os endpoints REST respondendo dentro do orçamento."
        case .degraded(let reason), .failing(let reason):
            return reason
        }
    }
}
