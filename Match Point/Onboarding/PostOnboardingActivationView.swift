import SwiftUI
import SwiftData
import OSLog

// MARK: - Post-Onboarding Activation
//
// Shown once, right after the user selects their favorites during onboarding.
// Goal: prove Match Point's value in <30 seconds. Surfaces:
//
//  • Primary favorite + next scheduled match with countdown
//  • MatchIntelligence "why watch" reasons (favorite bonus, ranking, timing)
//  • One-tap "Ativar alertas" that unifies notification permission +
//    Alert preferences flip in a single confirmation
//  • Live match dropdown when a favorite is already playing
//
// The view is presented as a full-screen cover from `ContentView` after
// `OnboardingView.finish()` runs, so all favorites/preferences are already
// persisted when it appears. Dismissing takes the user into the main tabs.

struct PostOnboardingActivationView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @EnvironmentObject private var remotePushManager: RemotePushManager

    @Query(filter: #Predicate<Player> { $0.isFavorite }, sort: \Player.name)
    private var favoritePlayers: [Player]

    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @Query private var matches: [TennisMatch]

    let onContinue: () -> Void

    @State private var didRequestAlerts = false
    @State private var isRequestingAlerts = false
    @State private var alertsBanner: AlertsBanner?

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
        let threshold = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .distantPast
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .forward
        )
    }

    private enum AlertsBanner: Equatable {
        case enabled
        case denied
        case error(String)

        var title: String {
            switch self {
            case .enabled: return "Alertas ativados"
            case .denied: return "Permissão negada"
            case .error: return "Não deu certo"
            }
        }

        var systemImage: String {
            switch self {
            case .enabled: return "checkmark.circle.fill"
            case .denied: return "bell.slash.fill"
            case .error: return "exclamationmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .enabled: return .green
            case .denied: return .orange
            case .error: return .red
            }
        }

        var detail: String {
            switch self {
            case .enabled:
                return "Vamos avisar antes, no início e no fim das próximas partidas dos seus favoritos."
            case .denied:
                return "Você pode habilitar em Ajustes > Notificações > Match Point quando quiser."
            case .error(let message):
                return message
            }
        }
    }

    private var primaryFavorite: Player? {
        favoritePlayers.first
    }

    private var favoritePlayerIDs: Set<UUID> {
        Set(favoritePlayers.map(\.id))
    }

    private var favoriteMatches: [TennisMatch] {
        matches.filter { match in
            if match.isFavorite { return true }
            if let player1 = match.player1, favoritePlayerIDs.contains(player1.id) { return true }
            if let player2 = match.player2, favoritePlayerIDs.contains(player2.id) { return true }
            return false
        }
    }

    private var liveFavoriteMatch: TennisMatch? {
        favoriteMatches.first(where: \.isLive)
    }

    private var nextUpcomingFavoriteMatch: TennisMatch? {
        favoriteMatches
            .filter(\.isUpcoming)
            .min { $0.date < $1.date }
    }

    private var lastCompletedFavoriteMatch: TennisMatch? {
        favoriteMatches
            .filter(\.isCompleted)
            .max { $0.date < $1.date }
    }

    private var featuredMatch: TennisMatch? {
        liveFavoriteMatch ?? nextUpcomingFavoriteMatch ?? lastCompletedFavoriteMatch
    }

    private var relevanceReasons: [MatchRelevanceReason] {
        guard let match = featuredMatch else { return [] }
        let rankByID = Dictionary(uniqueKeysWithValues: rankings.compactMap { entry -> (UUID, Int)? in
            guard let id = entry.player?.id else { return nil }
            return (id, entry.rank)
        })
        return MatchIntelligence.relevanceReasons(for: match, rankByPlayerID: rankByID)
    }

    private var alertsAreActive: Bool {
        alertStore.preferences.notificationsEnabled
            && alertStore.authorizationStatus == .authorized
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let match = featuredMatch {
                        matchSpotlight(match)
                        whyWatchSection
                        alertSection
                    } else {
                        noMatchesFallback
                    }
                    Spacer(minLength: 4)
                    continueButton
                }
                .padding(22)
            }
            .background(activationBackground)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        analyticsStore.record(ProductAnalyticsEventName.activationSkipped)
                        finish()
                    } label: {
                        Text("Pular")
                            .fontWeight(.semibold)
                    }
                    .accessibilityIdentifier("activation-skip")
                }
            }
            .task {
                await alertStore.refreshAuthorizationStatus()
                analyticsStore.record(
                    ProductAnalyticsEventName.activationShown,
                    properties: [
                        "hasMatch": featuredMatch != nil ? "true" : "false",
                        "favorites": "\(favoritePlayers.count)"
                    ]
                )
            }
        }
        .accessibilityIdentifier("activation-screen")
    }

    private var activationBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.20, blue: 0.16),
                Color(red: 0.02, green: 0.28, blue: 0.18),
                Color(red: 0.02, green: 0.10, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEU MATCH POINT ESTÁ PRONTO")
                .font(.caption.weight(.black))
                .foregroundStyle(.green)
                .accessibilityIdentifier("activation-eyebrow")

            if let name = primaryFavorite?.name {
                Text("Bem-vindo, fã de \(name).")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("activation-title")
            } else {
                Text("Bem-vindo ao Match Point.")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("activation-title")
            }

            Text("Nos próximos 30 segundos você já vê o próximo jogo, entende por que assistir e ativa os alertas — tudo em um lugar.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func matchSpotlight(_ match: TennisMatch) -> some View {
        let statusLine = statusLine(for: match)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(matchModeLabel(for: match), systemImage: matchModeSymbol(for: match))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(match.isLive ? .red : .yellow)
                Spacer()
                if let tournament = match.tournament {
                    Text(tournament.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(1)
                }
            }

            Text("\(match.player1?.name ?? "TBD") × \(match.player2?.name ?? "TBD")")
                .font(.title2.weight(.heavy))
                .foregroundStyle(.white)
                .accessibilityIdentifier("activation-featured-match")

            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusLine(for match: TennisMatch) -> String {
        if match.isLive {
            let intel = MatchIntelligence(match: match, rankings: rankings, allMatches: matches)
            let headline = intel.liveContext.headline
            let score = match.score.isEmpty ? nil : match.score
            if let score {
                return "Ao vivo agora • \(headline) — placar \(score)"
            }
            return "Ao vivo agora • \(headline)"
        }
        if match.isUpcoming {
            let interval = match.date.timeIntervalSinceNow
            if interval < 60 * 60 {
                let minutes = max(1, Int(interval / 60))
                return "Começa em ~\(minutes) minutos"
            }
            if interval < 60 * 60 * 24 {
                let hours = max(1, Int(interval / 3600))
                return "Começa em ~\(hours)h"
            }
            let days = max(1, Int(interval / 86_400))
            return days == 1 ? "Amanhã na sua agenda" : "Em \(days) dias na sua agenda"
        }
        if !match.score.isEmpty {
            return "Última partida concluída: \(match.score)"
        }
        return "Resultado consolidado disponível"
    }

    private func matchModeLabel(for match: TennisMatch) -> String {
        if match.isLive { return "AO VIVO" }
        if match.isUpcoming { return "PRÓXIMO JOGO" }
        return "ÚLTIMA PARTIDA"
    }

    private func matchModeSymbol(for match: TennisMatch) -> String {
        if match.isLive { return "dot.radiowaves.left.and.right" }
        if match.isUpcoming { return "calendar.badge.clock" }
        return "trophy.fill"
    }

    private var whyWatchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Por que acompanhar", systemImage: "sparkles")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            if relevanceReasons.isEmpty {
                Text("Assim que houver mais contexto (ranking, favorito, momento chave), a gente destaca aqui.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(relevanceReasons.prefix(4)) { reason in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: reason.symbol)
                                .foregroundStyle(.green)
                                .frame(width: 22, alignment: .center)
                            Text(reason.label)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            Spacer()
                            Text("+\(reason.points)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(Color.readableSecondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("activation-why-watch")
    }

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Alertas em um toque", systemImage: "bell.badge.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            Text("Avisamos antes do saque, no primeiro ponto e no fim da partida. Você pode desativar quando quiser.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)

            if let banner = alertsBanner {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: banner.systemImage)
                        .foregroundStyle(banner.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text(banner.detail)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(banner.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("activation-alerts-banner")
            }

            Button {
                Task { await enableAlertsFlow() }
            } label: {
                Group {
                    if isRequestingAlerts {
                        ProgressView().tint(.white)
                    } else {
                        Label(
                            alertsAreActive ? "Alertas ativados" : "Ativar alertas agora",
                            systemImage: alertsAreActive ? "checkmark.seal.fill" : "bell.and.waves.left.and.right.fill"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(alertsAreActive ? .green : .yellow)
            .controlSize(.large)
            .disabled(isRequestingAlerts || alertsAreActive)
            .accessibilityIdentifier("activation-enable-alerts")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var noMatchesFallback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sem jogos ainda", systemImage: "calendar.badge.exclamationmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)

            Text("Sem partidas sincronizadas dos seus favoritos ainda. Confira sua conexão e mantenha seus favoritos atualizados para o app preencher jogos ao vivo, próximos jogos e histórico assim que a API responder.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var continueButton: some View {
        Button {
            analyticsStore.record(ProductAnalyticsEventName.activationCompleted)
            finish()
        } label: {
            Label("Entrar no meu feed", systemImage: "arrow.right.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(Color(red: 0.02, green: 0.20, blue: 0.14))
        .controlSize(.large)
        .accessibilityIdentifier("activation-continue")
    }

    private func enableAlertsFlow() async {
        guard !isRequestingAlerts else { return }
        isRequestingAlerts = true
        defer { isRequestingAlerts = false }

        // Refresh permission status first — if we already have it, we can skip
        // the system prompt and just flip the flags on.
        await alertStore.refreshAuthorizationStatus()

        var granted = alertStore.authorizationStatus == .authorized
        if !granted {
            granted = await alertStore.requestAuthorization()
        }
        didRequestAlerts = true

        analyticsStore.record(
            granted
                ? ProductAnalyticsEventName.alertPermissionAccepted
                : ProductAnalyticsEventName.alertPermissionDeclined
        )

        if granted {
            alertStore.update {
                $0.notificationsEnabled = true
                $0.followFavoritePlayers = true
                $0.followFavoriteMatches = true
                $0.followFavoriteTournaments = true
            }
            alertsBanner = .enabled

            await remotePushManager.syncNotificationSubscriptions(
                in: context,
                reason: "activation-enable-alerts"
            )

            let engine: any AlertNotificationsServicing = AlertEventEngine.shared
            await engine.refreshScheduledNotifications(in: context, force: true)
        } else {
            alertsBanner = .denied
        }
    }

    private func finish() {
        onContinue()
        dismiss()
    }
}

// MARK: - Analytics identifiers

extension ProductAnalyticsEventName {
    static let activationShown = "activation_shown"
    static let activationCompleted = "activation_completed"
    static let activationSkipped = "activation_skipped"
    static let demoModeEnabled = "demo_mode_enabled"
    static let demoModeDisabled = "demo_mode_disabled"
}
