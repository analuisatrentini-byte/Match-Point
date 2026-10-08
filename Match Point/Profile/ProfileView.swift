import AuthenticationServices
import CryptoKit
import OSLog
import SwiftUI
import SwiftData

// MARK: - Profile

struct ProfileView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \PointBet.createdAt, order: .reverse) private var bets: [PointBet]
    @Query(sort: \Player.name) private var players: [Player]
    @Query(sort: \TennisMatch.date, order: .reverse) private var matches: [TennisMatch]

    @Query(sort: \SocialPost.createdAt, order: .reverse) private var socialPosts: [SocialPost]
    @EnvironmentObject private var cloudBackend: CloudSocialBackend
    @EnvironmentObject private var responsibleGamblingStore: ResponsibleGamblingStore
    @State private var showWeeklyRecap = false
    @State private var draftName = ""
    @State private var draftAvatar = "person.crop.circle.fill"
    @State private var selectedBetKind: BetKind = .matchWinner
    @State private var selectedStake = 50
    @State private var selectedMatchID: UUID?
    @State private var selectedPlayerID: UUID?
    @State private var predictedScore = ""
    @State private var selectedTieBreakPrediction = "Sim"
    @State private var selectedTotalSets = "3"
    @State private var selectedPerformanceRule: BetPerformanceRule = .straightSets
    @State private var showCreatePrediction = false
    @State private var wizardStep: Int = 1
    @State private var showBetCreatedToast = false
    @State private var responsibleGamblingBlockMessage: String?
    @State private var responsibleGamblingWarningMessage: String?
    @State private var hasConfirmedResponsibleGamblingWarning = false
    @State private var showRiskDisclosureAcknowledgement = false
    @State private var preMatchOdds: [OddsDTO] = []
    @State private var liveOdds: [LiveOddsDTO] = []
    @State private var oddsMatchKey: String?
    @State private var oddsLoadMessage: String?
    @State private var isLoadingBetOdds = false
    @State private var pickCommentDrafts: [UUID: String] = [:]
    // Filtro do histórico de previsões. Default = Abertas porque é o caso
    // primário ao abrir a aba ("o que ainda está pendente?"). Resolvidas
    // junta ganhas + perdidas + anuladas — Recognition over Recall: o usuário
    // não precisa scrollar pra achar uma aposta em aberto enterrada no meio
    // do histórico.
    @State private var predictionFilter: PredictionFilter = .open
    @State private var accountMode: AccountMode = .signIn
    @State private var showPasswordRecovery = false
    @State private var loginIdentifier = ""
    @State private var accountEmail = ""
    @State private var accountUsername = ""
    @State private var accountPassword = ""
    @State private var recoveryIdentifier = ""
    @State private var recoveryCode = ""
    @State private var recoveryNewPassword = ""
    @State private var accountMessage: String?
    @State private var generatedRecoveryCode: String?
    private let accountAuthService = AccountAuthService()

    private enum PredictionFilter: String, CaseIterable, Identifiable {
        case open = "Abertas"
        case resolved = "Resolvidas"
        var id: String { rawValue }
    }

    private enum AccountMode {
        case signIn
        case createAccount
    }

    private var filteredBets: [PointBet] {
        switch predictionFilter {
        case .open:
            return bets.filter { $0.status == .open }
        case .resolved:
            return bets.filter { $0.status != .open }
        }
    }
    // Avatar icon scales with the user's Dynamic Type setting — fixed 48pt
    // ignored a11y and clipped the avatar circle when text was enlarged.
    @ScaledMetric(relativeTo: .largeTitle) private var avatarIconSize: CGFloat = 48

    init() {
        // Cap the match query to 90 days — bettable matches and stats
        // (weekly points, H2H) only need recent data; older rows never
        // surface in this tab but would otherwise load into memory on open.
        let threshold = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    private var profile: UserProfile? {
        profiles.first
    }

    private var favoritePlayers: [Player] {
        players.filter(\.isFavorite)
    }

    private var bettableMatches: [TennisMatch] {
        let favoriteIDs = Set(favoritePlayers.map(\.id))
        return matches
            .filter { match in
                !match.isCompleted && (
                    match.isFavorite ||
                    match.player1.map { favoriteIDs.contains($0.id) } == true ||
                    match.player2.map { favoriteIDs.contains($0.id) } == true
                )
            }
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                return lhs.date < rhs.date
            }
    }

    private var selectedMatch: TennisMatch? {
        if let selectedMatchID, let match = bettableMatches.first(where: { $0.id == selectedMatchID }) {
            return match
        }
        return bettableMatches.first
    }

    private var selectedPlayer: Player? {
        let players = selectablePlayers
        if let selectedPlayerID, let player = players.first(where: { $0.id == selectedPlayerID }) {
            return player
        }
        return players.first
    }

    private var selectablePlayers: [Player] {
        [selectedMatch?.player1, selectedMatch?.player2].compactMap { $0 }
    }

    private var selectedBetNeedsPlayer: Bool {
        switch selectedBetKind {
        case .matchWinner, .setWinner, .playerPerformance, .holdServe, .firstBreak, .nextGameWinner:
            return true
        case .finalScore, .tieBreakPlayed, .totalSets:
            return false
        }
    }

    private struct TipsterLeaderboardRow: Identifiable {
        let id: String
        let name: String
        let points: Int
        let isCurrentUser: Bool
        /// Tipster-specific fields are nil for the local/seeded ranking scopes
        /// where we don't compute them (weekly/monthly/atp/etc. show plain
        /// points-vs-points). Only the cloud-backed "Geral" leaderboard fills
        /// them in.
        let wins: Int?
        let losses: Int?
        let currentStreak: Int?
        let winRateText: String?
    }

    private var cloudLeaderboard: [TipsterLeaderboardRow] {
        cloudBackend.leaderboard.prefix(100).enumerated().map { index, entry in
            let winRate = entry.settled > 0
                ? String(format: "%.0f%%", Double(entry.wins) / Double(entry.settled) * 100)
                : nil
            return TipsterLeaderboardRow(
                id: entry.id,
                name: entry.displayName,
                points: entry.points,
                isCurrentUser: entry.isCurrentUser,
                wins: entry.wins,
                losses: entry.losses,
                currentStreak: entry.currentStreak,
                winRateText: winRate
            )
        }
    }

    private var localLeaderboard: [TipsterLeaderboardRow] {
        SocialRankingBuilder.weeklyRows(
            profile: profile,
            bets: bets,
            matches: matches
        )
        .sorted { $0.points > $1.points }
        .enumerated()
        .map { index, row in
            TipsterLeaderboardRow(
                id: "local-\(index)-\(row.name)",
                name: row.name,
                points: row.points,
                isCurrentUser: row.isCurrentUser,
                wins: nil,
                losses: nil,
                currentStreak: nil,
                winRateText: nil
            )
        }
    }

    private var leaderboard: [TipsterLeaderboardRow] {
        cloudLeaderboard.isEmpty ? localLeaderboard : cloudLeaderboard
    }

    private var rank: Int {
        (leaderboard.firstIndex { $0.isCurrentUser } ?? 0) + 1
    }

    private var badges: [SocialBadge] {
        BadgeCatalog.badges(
            bets: bets,
            favoritePlayers: favoritePlayers,
            matches: matches,
            profile: profile,
            stats: predictionStats
        )
    }

    private var achievements: [String] {
        badges.filter(\.isUnlocked).map(\.title)
    }

    private var upcomingBadges: [SocialBadge] {
        badges
            .filter { !$0.isUnlocked }
            .sorted { $0.progress > $1.progress }
            .prefix(3)
            .map { $0 }
    }

    private var predictionStats: PredictionStats {
        PredictionStats(bets: bets)
    }

    private var currentSeason: SocialSeason {
        SocialSeason.current()
    }

    private var weeklySummary: WeeklySocialSummary {
        WeeklySocialSummary(
            season: currentSeason,
            rank: rank,
            localLeaderboardCount: max(leaderboard.count, localLeaderboard.count),
            stats: predictionStats
        )
    }

    var body: some View {
        List {
            if let profile {
                Section {
                    profileHeader(profile)
                        .profileListCardRow()

                    NavigationLink {
                        IdentityEditorView(
                            draftName: $draftName,
                            draftAvatar: $draftAvatar,
                            avatarOptions: IdentityEditorView.defaultAvatarOptions,
                            onSave: saveIdentity
                        )
                        .onAppear {
                            loadIdentityDraft(force: true)
                        }
                    } label: {
                        Label("Editar perfil", systemImage: "pencil.circle.fill")
                    }
                    .accessibilityIdentifier("profile-edit-identity-link")
                    .profileInlineListRow()

                    NavigationLink {
                        PublicProfileView(
                            profile: profile,
                            rank: rank,
                            predictionStats: predictionStats,
                            favoritePlayers: favoritePlayers,
                            bets: bets,
                            achievements: achievements,
                            matches: matches
                        )
                    } label: {
                        Label("Ver perfil público", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .accessibilityIdentifier("profile-public-profile-link")
                    .profileInlineListRow()
                }

                Section("Resumo social") {
                    weeklySocialSummaryCard
                        .profileListCardRow()

                    Button {
                        showWeeklyRecap = true
                    } label: {
                        Label("Abrir resumo semanal", systemImage: "chart.bar.doc.horizontal")
                    }
                    .accessibilityIdentifier("profile-open-weekly-recap")
                    .profileInlineListRow()
                }

                Section("Ranking") {
                    leaderboardPodium
                        .profileListCardRow()

                    NavigationLink {
                        LeaderboardHubView()
                    } label: {
                        Label("Abrir ranking completo", systemImage: "trophy.fill")
                    }
                    .accessibilityIdentifier("profile-open-leaderboard-hub")
                    .profileInlineListRow()
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        leaderboardSourceRow

                        if !cloudLeaderboard.isEmpty {
                            ForEach(Array(cloudLeaderboard.enumerated()), id: \.element.id) { index, row in
                                tipsterRow(index: index, row: row)
                            }
                        } else if case .loading = cloudBackend.state {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Sincronizando ranking global…")
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                            }
                        } else if case .unavailable(let message) = cloudBackend.state {
                            Label(message, systemImage: "icloud.slash")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        } else if case .ready = cloudBackend.state {
                            Text("Ainda sem dados globais. O ranking aparece depois que previsões forem liquidadas.")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        } else {
                            Button {
                                Task {
                                    await cloudBackend.refreshAccountStatus()
                                    await cloudBackend.refreshAll()
                                    await cloudBackend.syncProfile(profile, performance: currentTipsterPerformance)
                                }
                            } label: {
                                Label("Carregar ranking global", systemImage: "icloud.and.arrow.down")
                            }
                            .font(.caption)
                        }

                        Text(cloudBackend.leaderboardSource.isProductionGrade
                             ? "Pontuação calculada a partir de previsões liquidadas."
                             : "Ranking temporário até a próxima sincronização oficial.")
                            .font(.caption2)
                            .foregroundStyle(Color.readableTertiary)
                    }
                    .profileListCardRow()
                } header: {
                    Text("Global")
                }

                Section("Esta semana (local)") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(localLeaderboard.enumerated()), id: \.element.id) { index, row in
                            tipsterRow(index: index, row: row)
                        }
                    }
                    .profileListCardRow()
                }

                Section("Temporada") {
                    seasonSummaryCard
                    .profileListCardRow()
                }

                Section("Previsões") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            wizardStep = 1
                            showCreatePrediction = true
                        } label: {
                            Label("Nova previsão", systemImage: "ticket")
                                .foregroundStyle(bettableMatches.isEmpty ? Color.readableSecondary : Color.green)
                        }
                        .disabled(bettableMatches.isEmpty)
                        .accessibilityIdentifier("profile-new-prediction")

                        if bettableMatches.isEmpty {
                            Label("Nenhuma partida disponível agora. Sincronize ou aguarde jogos dos seus favoritos.", systemImage: "calendar.badge.clock")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        }

                        if !bets.isEmpty {
                            Picker("Filtro", selection: $predictionFilter) {
                                ForEach(PredictionFilter.allCases) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("profile-prediction-filter")
                        }

                        if bets.isEmpty {
                            Text("Nenhuma previsão criada ainda.")
                                .foregroundStyle(Color.readableSecondary)
                        } else if filteredBets.isEmpty {
                            Text(predictionFilter == .open
                                 ? "Nenhuma previsão em aberto. Toque em Nova previsão para começar."
                                 : "Nenhuma previsão resolvida ainda — suas apostas em aberto liquidam quando as partidas terminarem.")
                                .foregroundStyle(Color.readableSecondary)
                        } else {
                            ForEach(filteredBets) { bet in
                                betRow(bet)
                                    .accessibilityIdentifier("bet-history-row")
                            }
                        }
                    }
                    .profileListCardRow()
                }

                Section("Jogadores favoritos") {
                    VStack(alignment: .leading, spacing: 12) {
                        if favoritePlayers.isEmpty {
                            Text("Siga jogadores na aba Jogadores ou no perfil do atleta.")
                                .foregroundStyle(Color.readableSecondary)
                        } else {
                            ForEach(favoritePlayers) { player in
                                NavigationLink(destination: PlayerDetailView(player: player)) {
                                    Label(player.name, systemImage: "star.fill")
                                }
                            }
                        }
                    }
                    .profileListCardRow()
                }

                Section("Conquistas") {
                    VStack(alignment: .leading, spacing: 12) {
                        FlowTagRow(items: achievements)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                            ForEach(badges.filter(\.isUnlocked)) { badge in
                                BadgeChip(badge: badge)
                            }
                        }
                        .padding(.vertical, 4)

                        if !upcomingBadges.isEmpty {
                            Text("Próximas metas")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.readableSecondary)
                            ForEach(upcomingBadges) { badge in
                                BadgeProgressRow(badge: badge)
                            }
                        }
                    }
                    .profileListCardRow()
                }
            } else {
                Section {
                    accountCreationCard
                    .profileListCardRow()
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .accessibilityIdentifier("profile-screen")
        .navigationTitle("Perfil")
        // O `tabRoot` em ContentView esconde a nav bar por padrão pra deixar
        // as outras tabs com header próprio (custom gradient/title). A aba
        // Perfil precisa da nav bar visível pra mostrar o ícone de engrenagem
        // — sem este override o ToolbarItem abaixo nunca aparecia.
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .accessibilityLabel("Configurações")
                .accessibilityIdentifier("profile-settings-link")
            }
        }
        // FAB verde removido — competia visualmente com o ícone de engrenagem
        // no topo. O acesso a "Nova previsão" agora é um botão inline no
        // header da seção "Histórico de previsões" (linha-coisa inline,
        // hierarquia secundária — sem dois pontos focais circulares).
        .sheet(isPresented: $showWeeklyRecap) {
            if let profile {
                NavigationStack {
                    WeeklyRecapView(
                        profile: profile,
                        bets: bets,
                        matches: matches,
                        rank: rank,
                        cloudLeaderboardCount: cloudBackend.leaderboard.count
                    )
                }
            }
        }
        .sheet(isPresented: $showCreatePrediction, onDismiss: {
            wizardStep = 1
            selectedMatchID = nil
            selectedPlayerID = nil
            selectedBetKind = .matchWinner
            selectedStake = 50
            predictedScore = ""
            selectedTieBreakPrediction = "Sim"
            selectedTotalSets = "3"
            selectedPerformanceRule = .straightSets
            preMatchOdds = []
            liveOdds = []
            oddsMatchKey = nil
            oddsLoadMessage = nil
            isLoadingBetOdds = false
            responsibleGamblingBlockMessage = nil
            responsibleGamblingWarningMessage = nil
            hasConfirmedResponsibleGamblingWarning = false
        }) {
            createPredictionSheet
        }
        .alert("Uso responsável", isPresented: Binding(
            get: { responsibleGamblingBlockMessage != nil },
            set: { if !$0 { responsibleGamblingBlockMessage = nil } }
        )) {
            Button("OK", role: .cancel) { responsibleGamblingBlockMessage = nil }
        } message: {
            Text(responsibleGamblingBlockMessage ?? "")
        }
        .alert("Confirmar aviso", isPresented: Binding(
            get: { responsibleGamblingWarningMessage != nil },
            set: { if !$0 { responsibleGamblingWarningMessage = nil } }
        )) {
            Button("Voltar", role: .cancel) {
                responsibleGamblingWarningMessage = nil
                hasConfirmedResponsibleGamblingWarning = false
            }
            Button("Confirmar mesmo assim") {
                responsibleGamblingWarningMessage = nil
                hasConfirmedResponsibleGamblingWarning = true
            }
        } message: {
            Text(responsibleGamblingWarningMessage ?? "")
        }
        .alert("Antes de prever", isPresented: $showRiskDisclosureAcknowledgement) {
            Button("Entendi") {
                responsibleGamblingStore.acknowledgeRiskDisclosure()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As previsões usam somente pontos simbólicos. O Match Point não aceita dinheiro, não realiza apostas reais e não substitui limites pessoais de uso responsável.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBetWizard)) { notification in
            if let id = notification.userInfo?["matchID"] as? UUID {
                selectedMatchID = id
                selectedPlayerID = nil
                wizardStep = 2
                showCreatePrediction = true
            }
        }
        .onAppear {
            loadIdentityDraft()
            if profile != nil {
                settleFinishedBets()
            }
            // iCloud só é acordado quando o usuário entra no Matchboxd
            // (princípio: pedir permissão em contexto). Se essa
            // conexão já existe (state != .idle), a aba Perfil reaproveita;
            // caso contrário, pula tudo silenciosamente — o leaderboard
            // público só vai aparecer quando o usuário visitar o Matchboxd
            // pela primeira vez. Pull-to-refresh continua disponível como
            // escape hatch explícito.
            if case .idle = cloudBackend.state {
                // Nada — não dispara a primeira chamada CloudKit aqui.
            } else {
                Task {
                    await cloudBackend.refreshAccountStatus()
                    await cloudBackend.refreshAll()
                    if let profile {
                        await cloudBackend.syncProfile(profile, performance: currentTipsterPerformance)
                    }
                }
            }
        }
        .refreshable {
            settleFinishedBets()
            if let profile {
                await cloudBackend.syncProfile(profile, performance: currentTipsterPerformance)
            }
            await cloudBackend.refreshAll()
        }
        .overlay(alignment: .bottom) {
            if showBetCreatedToast {
                Label("Previsão criada!", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { showBetCreatedToast = false }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showBetCreatedToast)
    }

    private var currentTipsterPerformance: CloudTipsterPerformance {
        CloudTipsterPerformance(
            wins: predictionStats.won,
            losses: predictionStats.lost,
            currentStreak: predictionStats.currentStreak
        )
    }

    private var accountCreationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentUnavailableView(
                accountMode == .signIn ? "Entre na sua conta" : "Criar uma conta",
                systemImage: "person.crop.circle.fill.badge.plus",
                description: Text(accountMode == .signIn
                                  ? "Use sua Conta Apple ou entre com e-mail e usuário para manter perfil, previsões e ranking."
                                  : "Cadastre-se usando e-mail, usuário e senha para sincronizar seu perfil.")
            )
            .frame(maxWidth: .infinity, minHeight: 120)

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("profile-sign-in-with-apple")

            switch accountMode {
            case .signIn:
                signInWithEmailSection
            case .createAccount:
                createAccountWithEmailSection
            }

            if let accountMessage {
                Text(accountMessage)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signInWithEmailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Entrar com e-mail e usuário")
                    .font(.headline)

                TextField("E-mail ou usuário", text: $loginIdentifier)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    .profileTextField()

                SecureField("Senha", text: $accountPassword)
                    .textContentType(.password)
                    .profileTextField()

                Button {
                    loginEmailAccount()
                } label: {
                    Label("Entrar", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          accountPassword.count < 8)
                .accessibilityIdentifier("profile-login-email-account")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPasswordRecovery.toggle()
                        recoveryIdentifier = recoveryIdentifier.isEmpty ? loginIdentifier : recoveryIdentifier
                        accountMessage = nil
                    }
                } label: {
                    Label(showPasswordRecovery ? "Ocultar recuperação" : "Esqueci minha senha", systemImage: "key.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.matchPointGreen)
                .accessibilityIdentifier("profile-toggle-password-recovery")

                if showPasswordRecovery {
                    recoverySection
                        .padding(.top, 4)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Não tenho uma conta")
                    .font(.headline)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        accountMode = .createAccount
                        accountMessage = nil
                        accountPassword = ""
                    }
                } label: {
                    Label("Criar uma conta", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .accessibilityIdentifier("profile-open-create-account")
            }
        }
    }

    private var createAccountWithEmailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Criar com e-mail")
                    .font(.headline)

                TextField("E-mail", text: $accountEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .profileTextField()

                TextField("Usuário", text: $accountUsername)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    .profileTextField()

                SecureField("Senha", text: $accountPassword)
                    .textContentType(.newPassword)
                    .profileTextField()

                Button {
                    createEmailAccount()
                } label: {
                    Label("Criar conta com e-mail", systemImage: "envelope.badge.shield.half.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          accountUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          accountPassword.count < 8)
                .accessibilityIdentifier("profile-create-email-account")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    accountMode = .signIn
                    accountMessage = nil
                    accountPassword = ""
                }
            } label: {
                Label("Já tenho uma conta", systemImage: "arrow.left.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .accessibilityIdentifier("profile-back-to-login")
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recuperação de senha")
                .font(.subheadline.weight(.bold))
            Text("Informe seu e-mail ou usuário para receber um código. Depois cole o código e escolha uma nova senha.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)

            TextField("E-mail ou usuário", text: $recoveryIdentifier)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                .profileTextField()

            SecureField("Código de recuperação", text: $recoveryCode)
                .textContentType(.oneTimeCode)
                .profileTextField()

            SecureField("Nova senha", text: $recoveryNewPassword)
                .textContentType(.newPassword)
                .profileTextField()

            Button {
                requestEmailRecovery()
            } label: {
                Label("Enviar código de recuperação", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(recoveryIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("profile-request-email-recovery")

            Button {
                recoverEmailAccount()
            } label: {
                Label("Redefinir senha", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(recoveryIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      recoveryNewPassword.count < 8)
            .accessibilityIdentifier("profile-recover-email-account")
        }
        .padding(12)
        .background(Color.cardOverlaySoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Wizard de Criar Previsão

    private var createPredictionSheet: some View {
        NavigationStack {
            Group {
                if let profile {
                    wizardContent(for: profile)
                } else {
                    ContentUnavailableView("Sem perfil", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text("Crie um perfil em Configurações para começar a prever."))
                }
            }
            .navigationTitle(wizardTitle)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { showCreatePrediction = false }
                }
                if wizardStep > 1 {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation { wizardStep -= 1 }
                        } label: {
                            Label("Voltar", systemImage: "chevron.left")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var wizardTitle: String {
        switch wizardStep {
        case 1: return "Partida (1/3)"
        case 2: return "Tipo (2/3)"
        default: return "Detalhes (3/3)"
        }
    }

    @ViewBuilder
    private func wizardContent(for profile: UserProfile) -> some View {
        switch wizardStep {
        case 1: wizardStepMatch
        case 2: wizardStepKind
        default: wizardStepDetails(profile: profile)
        }
    }

    private var wizardStepMatch: some View {
        // Step 1: lista compacta de partidas elegíveis. Tap avança pro step 2.
        List(bettableMatches) { match in
            Button {
                selectedMatchID = match.id
                selectedPlayerID = match.player1?.id
                predictedScore = BetSettlementEngine.defaultPredictedScore(for: match, player: match.player1)
                Task { await loadBetOdds(for: match) }
                withAnimation { wizardStep = 2 }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        if match.isLive {
                            Text("AO VIVO")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.red)
                        }
                        Image(systemName: selectedMatchID == match.id ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundStyle(selectedMatchID == match.id ? Color.green : Color.readableSecondary)
                    }
                    Text(match.tournament?.name ?? "")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                    Text(match.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(Color.readableSecondary)
                }
            }
            .buttonStyle(.plain)
            .appListCardRow()
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
    }

    private var wizardStepKind: some View {
        List {
            if let match = selectedMatch {
                Section("Partida") {
                    Label(shortMatchTitle(match), systemImage: "tennisball")
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                }
            }
            Section("Tipo de previsão") {
                ForEach(BetKind.allCases) { kind in
                    Button {
                        selectedBetKind = kind
                        withAnimation { wizardStep = 3 }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: betKindIcon(kind))
                                .font(.title3)
                                .foregroundStyle(.green)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.rawValue)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(betKindDescription(kind))
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                            }
                            Spacer()
                            Image(systemName: selectedBetKind == kind ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundStyle(selectedBetKind == kind ? Color.green : Color.readableSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .appListCardRow()
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
    }

    // Step 3 (Detalhes): card de resumo fixo no topo + mecanismo + stake +
    // confirmação tudo num único passo. Reduz de 4 para 3 steps — o usuário
    // não precisa de uma tela só pra revisar antes de confirmar.
    @ViewBuilder
    private func wizardStepDetails(profile: UserProfile) -> some View {
        Form {
            Section("Resumo") {
                if let match = selectedMatch {
                    LabeledContent("Partida", value: shortMatchTitle(match))
                        .font(.subheadline)
                }
                LabeledContent("Tipo", value: selectedBetKind.rawValue)
                    .font(.subheadline)
                if let match = selectedMatch {
                    betPricingSummary(match: match, profile: profile)
                }
            }

            if selectedBetNeedsPlayer {
                Section("Jogador") {
                    if let fallbackPlayerID = selectablePlayers.first?.id {
                        Picker("Jogador", selection: Binding(
                            get: { selectedPlayer?.id ?? fallbackPlayerID },
                            set: { selectedPlayerID = $0 }
                        )) {
                            ForEach(selectablePlayers) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            if selectedBetKind == .setWinner, let match = selectedMatch {
                Section("Set alvo") {
                    Text("Set \(BetSettlementEngine.targetSetIndex(for: match) + 1)")
                }
            }
            if selectedBetKind == .finalScore {
                Section("Placar previsto") {
                    TextField("ex: 6-4 6-4", text: $predictedScore)
#if os(iOS)
                        .textInputAutocapitalization(.characters)
#endif
                }
            }
            if selectedBetKind == .tieBreakPlayed {
                Section("Tie-break") {
                    Picker("Tie-break", selection: $selectedTieBreakPrediction) {
                        Text("Sim").tag("Sim")
                        Text("Não").tag("Não")
                    }
                    .pickerStyle(.segmented)
                }
            }
            if selectedBetKind == .totalSets {
                Section("Sets") {
                    Picker("Sets", selection: $selectedTotalSets) {
                        ForEach(totalSetOptions(for: selectedMatch), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            if selectedBetKind == .playerPerformance {
                Section("Performance") {
                    Picker("Performance", selection: $selectedPerformanceRule) {
                        ForEach(BetPerformanceRule.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }

            Section("Uso responsável") {
                responsibleGamblingDisclosure
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(stakePresets, id: \.self) { preset in
                        Button {
                            selectedStake = min(preset, profile.points)
                        } label: {
                            Text("\(preset)")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(selectedStake == preset ? Color.green.opacity(0.25) : Color.white.opacity(0.08))
                                .foregroundStyle(selectedStake == preset ? Color.green : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        selectedStake = profile.points
                    } label: {
                        Text("Max")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                stakeProportionVisual(profile: profile)
            } header: {
                Text("Pontos simbólicos")
            } footer: {
                Text("Os pontos são apenas simbólicos — não valem dinheiro real, prêmios físicos ou qualquer recompensa fora do app. Servem só pra alimentar seu ranking de tipster contra outros usuários.")
                    .font(.footnote)
            }

            Section {
                Button {
                    if placeBet(profile: profile) {
                        showCreatePrediction = false
                        showBetCreatedToast = true
                    }
                } label: {
                    Label("Confirmar previsão", systemImage: "ticket.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled((selectedBetNeedsPlayer && selectedPlayer == nil) || selectedMatch == nil || profile.points < selectedStake)
                .accessibilityIdentifier("bet-confirm")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var stakePresets: [Int] { [50, 100, 200, 500] }

    @ViewBuilder
    private func betPricingSummary(match: TennisMatch, profile: UserProfile) -> some View {
        let quote = pricingQuote(match: match, profile: profile)
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Cotação", value: String(format: "%.2fx", quote.multiplier))
            LabeledContent("Retorno possível", value: "\(quote.payout) pts")
            HStack(spacing: 6) {
                Image(systemName: quote.isBookmakerBacked ? "checkmark.seal.fill" : "info.circle.fill")
                    .foregroundStyle(quote.isBookmakerBacked ? .green : .orange)
                Text(oddsSummaryText(for: quote))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if isLoadingBetOdds {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Carregando cotações...")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
            } else if let oddsLoadMessage {
                Text(oddsLoadMessage)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
        .task(id: match.externalID ?? match.id.uuidString) {
            await loadBetOdds(for: match)
        }
    }

    private var responsibleGamblingDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sem dinheiro real", systemImage: "shield.checkered")
                .font(.subheadline.weight(.semibold))
            Text("As previsões usam apenas pontos simbólicos. O app não executa apostas, não envia ordens para bookmakers e não paga prêmios fora do ranking interno.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            Text("Defina limites em Configurações se perceber aumento de frequência, pontos altos ou tentativa de recuperar perdas.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    /// Visual de proporção do stake vs saldo. Antes era só texto cru "Saldo:
    /// 50.000 pts" sem dar dimensão — usuário de saldo alto não sabia se 500
    /// (Max preset) era 1% ou 80% do saldo. Agora: barra horizontal +
    /// percentagem com cor que muda conforme aproxima de "all-in".
    @ViewBuilder
    private func stakeProportionVisual(profile: UserProfile) -> some View {
        let saldo = max(profile.points, 1) // evita div por zero
        let ratio = min(1.0, Double(selectedStake) / Double(saldo))
        let percent = Int((ratio * 100).rounded())
        let tint = stakeSeverityColor(ratio: ratio)
        let percentText = saldo > 0 ? "(\(percent)% do saldo)" : "(saldo zerado)"

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Previsão: \(selectedStake) pts")
                Text(percentText)
                    .foregroundStyle(tint)
                Spacer()
                Text("Saldo: \(profile.points) pts")
                    .foregroundStyle(profile.points < selectedStake ? .red : Color.readableSecondary)
            }
            .font(.caption)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: 6)

            if ratio >= 0.5 && profile.points >= selectedStake {
                // Aviso quando passa de metade do saldo — preventivo, ainda
                // tappável, mas chama atenção.
                HStack(spacing: 4) {
                    Image(systemName: ratio >= 0.75 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    Text(ratio >= 0.75
                         ? "Você está usando quase todo o saldo. Pense duas vezes."
                         : "Você está usando mais da metade do seu saldo.")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            }
        }
    }

    /// Mapeia razão stake/saldo em cor crescente de aviso.
    /// < 25%  → verde (apostando confortavelmente)
    /// 25-50% → cinza (normal)
    /// 50-75% → amarelo (atenção)
    /// > 75%  → vermelho (perto do all-in)
    private func stakeSeverityColor(ratio: Double) -> Color {
        switch ratio {
        case ..<0.25: return .green
        case ..<0.5:  return .secondary
        case ..<0.75: return .yellow
        default:      return .red
        }
    }

    private func betKindIcon(_ kind: BetKind) -> String {
        switch kind {
        case .matchWinner: return "trophy.fill"
        case .setWinner: return "1.square.fill"
        case .finalScore: return "number.square.fill"
        case .playerPerformance: return "chart.line.uptrend.xyaxis"
        case .tieBreakPlayed: return "equal.circle.fill"
        case .totalSets: return "list.number"
        case .holdServe: return "tennisball.fill"
        case .firstBreak: return "bolt.fill"
        case .nextGameWinner: return "forward.fill"
        }
    }

    private func betKindDescription(_ kind: BetKind) -> String {
        switch kind {
        case .matchWinner: return "Quem ganha a partida"
        case .setWinner: return "Quem leva o próximo set"
        case .finalScore: return "Placar exato em sets"
        case .playerPerformance: return "Como o jogador vence (sets diretos, virada, etc.)"
        case .tieBreakPlayed: return "Vai ter tie-break na partida?"
        case .totalSets: return "Quantos sets no total"
        case .holdServe: return "O sacador confirma o saque?"
        case .firstBreak: return "Quem dá o primeiro break"
        case .nextGameWinner: return "Quem leva o próximo game"
        }
    }

    // MARK: - Header
    private var weeklySocialSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentSeason.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    Text(weeklySummary.weeklyReadLine)
                        .font(.headline.weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: weeklySummary.currentStreak >= 2 ? "flame.fill" : "chart.line.uptrend.xyaxis")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(weeklySummary.currentStreak >= 2 ? .orange : .green)
            }

            HStack(spacing: 10) {
                profileMetric(title: "Acerto", value: predictionStats.accuracyText, tint: .green)
                profileMetric(title: "Streak", value: "\(predictionStats.currentStreak)", tint: .orange)
                profileMetric(title: "Semana", value: "\(predictionStats.weeklyNetPoints)", tint: .blue)
            }

            Text(weeklySummary.streakLine)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("profile-weekly-social-summary")
    }

    private var seasonSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Janela", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    Text(currentSeason.subtitle)
                        .font(.headline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("Semana")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(Color.readableSecondary)
                    Text("\(predictionStats.weeklyNetPoints)")
                        .font(.title3.monospacedDigit().weight(.heavy))
                        .foregroundStyle(predictionStats.weeklyNetPoints >= 0 ? .green : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.matchPointGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.matchPointGreen.opacity(0.28), lineWidth: 1)
                }
            }

            VStack(spacing: 10) {
                seasonInfoRow(
                    title: "Resumo",
                    detail: weeklySummary.weeklyReadLine,
                    systemImage: "chart.bar.doc.horizontal",
                    tint: .green
                )
                seasonInfoRow(
                    title: "Ritmo",
                    detail: weeklySummary.streakLine,
                    systemImage: weeklySummary.currentStreak >= 2 ? "flame.fill" : "clock.badge.checkmark",
                    tint: weeklySummary.currentStreak >= 2 ? .orange : .blue
                )
            }
        }
        .accessibilityIdentifier("profile-season-summary")
    }

    private func seasonInfoRow(title: String, detail: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Color.readableSecondary)
                Text(detail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.cardSurfaceHover.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var leaderboardPodium: some View {
        let rows = Array(leaderboard.prefix(3).enumerated())
        return VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Ranking indisponível",
                    systemImage: "list.number",
                    description: Text("Crie previsões para abrir sua temporada social.")
                )
            } else {
                ForEach(rows, id: \.element.id) { index, row in
                    tipsterRow(index: index, row: row)
                        .padding(10)
                        .background(row.isCurrentUser ? Color.green.opacity(0.12) : Color.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .accessibilityIdentifier("profile-leaderboard-podium")
    }

    private func profileHeader(_ profile: UserProfile) -> some View {
        HStack(spacing: 16) {
            Image(systemName: profile.avatarSymbol)
                .font(.system(size: avatarIconSize))
                .foregroundStyle(.green)
                .frame(width: avatarIconSize + 16, height: avatarIconSize + 16)
                .background(Color.green.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(profile.displayName)
                    .font(.title2.weight(.bold))
                Text("#\(rank) no ranking")
                    .font(.subheadline)
                    .foregroundStyle(Color.readableSecondary)
                Text("\(profile.points) pontos")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func tipsterRow(index: Int, row: TipsterLeaderboardRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("#\(index + 1)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(row.isCurrentUser ? .headline : .body)
                if let winRateText = row.winRateText, let wins = row.wins, let losses = row.losses {
                    HStack(spacing: 6) {
                        Text("\(winRateText) acerto")
                        Text("•")
                        Text("\(wins)V \(losses)D")
                        if let streak = row.currentStreak, streak >= 2 {
                            Text("•")
                            HStack(spacing: 2) {
                                Image(systemName: "flame.fill")
                                Text("\(streak)")
                            }
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
                }
            }

            Spacer()

            Text("\(row.points) pts")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(row.isCurrentUser ? .green : Color.readableSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tipsterAccessibilityLabel(index: index, row: row))
    }

    private func tipsterAccessibilityLabel(index: Int, row: TipsterLeaderboardRow) -> String {
        var parts: [String] = ["Posição \(index + 1)", row.name, "\(row.points) pontos"]
        if let winRateText = row.winRateText, let wins = row.wins, let losses = row.losses {
            parts.append("\(winRateText) de acerto em \(wins + losses) palpites")
            parts.append("\(wins) vitórias, \(losses) derrotas")
        }
        if let streak = row.currentStreak, streak >= 2 {
            parts.append("Streak de \(streak) acertos")
        }
        if row.isCurrentUser { parts.append("Você") }
        return parts.joined(separator: ". ")
    }

    private var leaderboardSourceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: cloudBackend.leaderboardSource.isProductionGrade ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(cloudBackend.leaderboardSource.isProductionGrade ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(cloudBackend.leaderboardSource.label)
                    .font(.subheadline.weight(.semibold))
                Text(leaderboardSourceDetail)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
        .accessibilityIdentifier("profile-global-ranking-source")
    }

    private var leaderboardSourceDetail: String {
        switch cloudBackend.leaderboardSource {
        case .backendAuthoritative:
            return "Ranking público calculado com previsões liquidadas."
        case .cloudKitFallback:
            return "Ranking temporário até a próxima atualização oficial."
        case .none:
            return "Carregue o ranking para ver sua posição global."
        }
    }

    private func profileMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func betRow(_ bet: PointBet) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bet.kind.rawValue)
                    .font(.headline)
                Spacer()
                Text(bet.status.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusTint(for: bet.status))
                if let profile, let payload = PickShareCardRenderer.payload(for: bet, profile: profile, weeklySummary: weeklySummary) {
                    ShareLink(
                        item: payload,
                        preview: SharePreview("Pick Match Point", image: Image(systemName: "ticket"))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Compartilhar card da previsão")
                    .accessibilityIdentifier("profile-share-pick-card-\(bet.id.uuidString)")
                } else {
                    ShareLink(
                        item: ShareTextFactory.prediction(bet),
                        preview: SharePreview("Match Point", image: Image(systemName: "ticket"))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Compartilhar previsão")
                    .accessibilityIdentifier("profile-share-prediction-\(bet.id.uuidString)")
                }
            }
            Text(bet.selection)
                .font(.subheadline)
            if bet.kind == .setWinner, let targetSetIndex = bet.targetSetIndex {
                Text("Set alvo: \(targetSetIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if bet.kind == .finalScore, !bet.predictedScore.isEmpty {
                Text("Placar previsto: \(bet.predictedScore)")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if bet.kind == .playerPerformance {
                Text(bet.performanceRule.rawValue)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if [.tieBreakPlayed, .totalSets].contains(bet.kind), !bet.predictedScore.isEmpty {
                Text("Previsão: \(bet.predictedScore)")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if [.holdServe, .firstBreak, .nextGameWinner].contains(bet.kind), !bet.predictedScore.isEmpty {
                Text("Estado inicial: \(readableSnapshot(bet.predictedScore))")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                Text(gamePredictionExplanation(for: bet.kind))
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
            }
            Text("\(bet.stake) pts usados • retorno \(bet.payout) pts")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)

            if let profile {
                NavigationLink {
                    PickDetailView(bet: bet)
                } label: {
                    PickShareCard(
                        bet: bet,
                        profileName: profile.displayName,
                        weeklySummary: weeklySummary
                    )
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("profile-pick-visual-card")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile-open-pick-detail-\(bet.id.uuidString)")
            }

            pickReactionSummaryStrip(for: bet)
            socialControls(for: bet)
        }
    }

    /// Compact chip strip showing the current emoji reaction counts + a
    /// button to open the full `PickDetailView`. Chips are tappable so the
    /// user can toggle the reaction without leaving the profile.
    private func pickReactionSummaryStrip(for bet: PointBet) -> some View {
        let summary = PickInteractionAnalyzer.summary(
            for: bet.id,
            localPosts: socialPosts,
            cloudPosts: cloudBackend.posts,
            viewer: profile?.displayName ?? "Match Point Fan"
        )
        return HStack(spacing: 6) {
            ForEach(PickReactionKind.allCases) { kind in
                Button {
                    publishPickEmojiReaction(kind, for: bet)
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.emoji)
                        Text("\(summary.count(for: kind))")
                            .monospacedDigit()
                    }
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(summary.viewerReactions.contains(kind) ? Color.green.opacity(0.20) : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reagir com \(kind.label). \(summary.count(for: kind)) reações.")
                .accessibilityIdentifier("profile-pick-reaction-\(kind.rawValue)")
            }
            Spacer(minLength: 4)
            NavigationLink {
                PickDetailView(bet: bet)
            } label: {
                Label("\(summary.commentCount)", systemImage: "bubble.left")
                    .font(.caption2.weight(.bold))
            }
            .accessibilityLabel("Abrir comentários. \(summary.commentCount) comentários.")
            .accessibilityIdentifier("profile-pick-open-comments-\(bet.id.uuidString)")
        }
    }

    private func socialControls(for bet: PointBet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(PickSocialAction.actions(for: bet)) { action in
                    Button {
                        publishPickReaction(action, for: bet)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Comentar este pick", text: pickCommentBinding(for: bet.id), axis: .vertical)
                    .font(.caption)
                    .accessibilityIdentifier("profile-pick-comment-field")
                Button {
                    publishPickComment(for: bet)
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled((pickCommentDrafts[bet.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Publicar comentário do pick")
                .accessibilityIdentifier("profile-pick-comment-send")
            }
        }
        .padding(.top, 4)
    }

    private func pickCommentBinding(for betID: UUID) -> Binding<String> {
        Binding(
            get: { pickCommentDrafts[betID] ?? "" },
            set: { pickCommentDrafts[betID] = $0 }
        )
    }

    private func publishPickReaction(_ action: PickSocialAction, for bet: PointBet) {
        let eventKey = PickInteractionEncoding.comment(betID: bet.id)
        publishPickSocialPost(
            body: "\(action.body) \(pickContextLine(for: bet))",
            for: bet,
            eventKey: eventKey
        )
    }

    fileprivate func publishPickEmojiReaction(_ kind: PickReactionKind, for bet: PointBet) {
        let eventKey = PickInteractionEncoding.reaction(betID: bet.id, kind: kind)
        let body = "\(kind.emoji) \(kind.label) — \(pickContextLine(for: bet))"
        publishPickSocialPost(body: body, for: bet, eventKey: eventKey)
    }

    private func publishPickComment(for bet: PointBet) {
        let draft = (pickCommentDrafts[bet.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        pickCommentDrafts[bet.id] = ""
        let eventKey = PickInteractionEncoding.comment(betID: bet.id)
        publishPickSocialPost(
            body: "\(draft) \(pickContextLine(for: bet))",
            for: bet,
            eventKey: eventKey
        )
    }

    private func publishPickSocialPost(body: String, for bet: PointBet, eventKey: String? = nil) {
        let author = profile?.displayName ?? "Match Point Fan"
        let resolvedKey = eventKey ?? PickInteractionEncoding.comment(betID: bet.id)
        let post = SocialPost(
            match: bet.match,
            authorName: author,
            body: body,
            eventKey: resolvedKey
        )
        context.insert(post)
        Task { @MainActor in
            await cloudBackend.publishComment(match: bet.match, authorName: author, body: body)
        }
    }

    fileprivate func publishPickCommentDraft(for bet: PointBet) {
        publishPickComment(for: bet)
    }

    private func pickContextLine(for bet: PointBet) -> String {
        let matchTitle = bet.match.map { "\($0.player1TeamName) vs \($0.player2TeamName)" } ?? "Partida"
        return "[\(matchTitle) • \(bet.kind.rawValue): \(bet.selection)]"
    }

    private func placeBet(profile: UserProfile) -> Bool {
        guard let match = selectedMatch else { return false }
        let player = selectedBetNeedsPlayer ? selectedPlayer : nil
        if selectedBetNeedsPlayer, player == nil { return false }
        let stake = min(selectedStake, profile.points)

        // Gate de uso responsável: rodado imediatamente antes de qualquer
        // inserção no modelo. Retorna false quando bloqueado — o chamador
        // NÃO deve fechar o wizard nem mostrar o toast de sucesso.
        let decision = ResponsibleGamblingGate.evaluate(
            preferences: responsibleGamblingStore.preferences,
            existingBets: bets,
            requestedStake: stake,
            currentBalance: profile.points
        )
        switch decision {
        case .blocked(let reason):
            responsibleGamblingBlockMessage = describeBlock(reason)
            hasConfirmedResponsibleGamblingWarning = false
            return false
        case .warned(.pendingRiskDisclosure):
            showRiskDisclosureAcknowledgement = true
            return false
        case .warned(let reason):
            guard hasConfirmedResponsibleGamblingWarning else {
                responsibleGamblingWarningMessage = describeWarning(reason)
                return false
            }
        case .allowed:
            break
        }

        let resolvedPredictedScore = predictionValue(for: selectedBetKind, match: match, player: player)
        let quote = pricingQuote(match: match, profile: profile)
        let bet = PointBet(
            match: match,
            player: player,
            kind: selectedBetKind,
            selection: selectionLabel(for: selectedBetKind, player: player),
            stake: stake,
            payout: quote.payout,
            targetSetIndex: selectedBetKind == .setWinner ? BetSettlementEngine.targetSetIndex(for: match) : nil,
            predictedScore: resolvedPredictedScore,
            performanceRule: selectedPerformanceRule
        )
        profile.points -= stake
        profile.updatedAt = .now
        context.insert(bet)
        hasConfirmedResponsibleGamblingWarning = false
        predictedScore = BetSettlementEngine.defaultPredictedScore(for: match, player: player)
        Task { @MainActor in
            await cloudBackend.syncBet(bet, profile: profile)
            await cloudBackend.syncProfile(profile)
        }
        return true
    }

    // Mapeia motivo de bloqueio em uma frase que o usuário entende. Fica
    // adjacente a placeBet pra manter o contrato claro: bloqueio silencioso
    // NUNCA acontece — sempre há uma mensagem explicando por quê.
    private func describeBlock(_ reason: ResponsibleGamblingDecision.BlockReason) -> String {
        switch reason {
        case .selfExclusion(let until):
            let formatted = until.formatted(date: .abbreviated, time: .shortened)
            return "Auto-exclusão ativa até \(formatted). Novas previsões só serão liberadas após esse período."
        case .dailyStakeExceeded(let limit, let currentUse):
            return "Você atingiu o limite diário de \(limit) pts (já usou \(currentUse)). Confirme depois da meia-noite ou revise o limite em Configurações."
        case .weeklyStakeExceeded(let limit, let currentUse):
            return "Limite semanal de \(limit) pts atingido (já usou \(currentUse)). Aguarde a próxima semana ou revise o limite."
        case .dailyBetCountExceeded(let limit, let currentUse):
            return "Você já criou \(currentUse) previsões hoje — teto configurado é \(limit)."
        case .lossCooldownActive(let until, let consecutiveLosses):
            let formatted = until.formatted(date: .abbreviated, time: .shortened)
            return "Cooldown ativo após \(consecutiveLosses) derrotas seguidas. Novas previsões liberadas em \(formatted)."
        }
    }

    private func describeWarning(_ reason: ResponsibleGamblingDecision.WarnReason) -> String {
        switch reason {
        case .pendingRiskDisclosure:
            return "Leia e confirme o aviso obrigatório antes de criar previsões."
        case .approachingDailyStakeLimit(let percentUsed):
            return "Essa previsão leva você a \(percentUsed)% do limite diário configurado. Confirme apenas se ainda fizer sentido dentro do seu limite."
        case .largeStakeRelativeToBalance(let percentOfBalance):
            return "Esse stake representa \(percentOfBalance)% do seu saldo simbólico. Evite aumentar stake para recuperar perdas."
        }
    }

    private func settleFinishedBets() {
        guard let profile else { return }
        for bet in bets where bet.status == .open {
            guard let status = BetSettlementEngine.status(for: bet) else {
                continue
            }
            // Skip crediting if stake/payout/selection were altered after
            // placement — `hasValidIntegrity` compares the stored SHA-256 with
            // a fresh hash over the current state. The bet stays `.open` so an
            // operator can investigate instead of silently rewarding tampering.
            guard bet.hasValidIntegrity else {
                AppLogger.persistence.error("settleFinishedBets skipped: integrity hash mismatch for bet \(bet.id.uuidString, privacy: .public)")
                AppLogger.recordFailure(
                    category: "persistence",
                    operation: "settleFinishedBets.integrityMismatch",
                    error: APIError(message: "PointBet integrity hash does not match current state")
                )
                continue
            }
            bet.status = status
            bet.settledAt = .now
            if status == .won {
                profile.points += bet.payout
            }
            Task { @MainActor in
                await cloudBackend.syncBet(bet, profile: profile)
            }
        }
        profile.updatedAt = .now
        Task { @MainActor in
            await cloudBackend.syncProfile(profile)
        }
    }

    private func ensureProfile() {
        // Guard against duplicates from concurrent onAppear calls (e.g. LiveTrackerView
        // navigation simultaneously mounting a second ProfileView instance).
        if profiles.count > 1 {
            for extra in profiles.dropFirst() {
                context.delete(extra)
            }
        }
        if profiles.isEmpty {
            let profile = UserProfile()
            context.insert(profile)
            do {
                try context.save()
            } catch {
                AppLogger.persistence.error("Failed to create default profile: \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "persistence", operation: "profile.ensureProfile", error: error)
            }
            draftName = profile.displayName
            draftAvatar = profile.avatarSymbol
            if let match = selectedMatch {
                predictedScore = BetSettlementEngine.defaultPredictedScore(for: match, player: selectedPlayer)
            }
            return
        }
        if profile != nil, draftName.isEmpty {
            loadIdentityDraft()
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                accountMessage = "Não foi possível ler a credencial da Conta Apple."
                return
            }
            let appleUserID = credential.user
            let name = credential.fullName
                .flatMap { PersonNameComponentsFormatter().string(from: $0).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            let emailName = credential.email?
                .split(separator: "@")
                .first
                .map(String.init)
            let displayName = name ?? emailName ?? "Match Point Fan"
            let authorizationCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            Task {
                do {
                    let session = try await accountAuthService.signInWithApple(
                        appleUserID: appleUserID,
                        email: credential.email,
                        displayName: displayName,
                        authorizationCode: authorizationCode
                    )
                    createAuthenticatedProfile(
                        displayName: session.user.displayName,
                        externalKey: session.user.externalKey,
                        avatarSymbol: "person.crop.circle.fill"
                    )
                    MatchPointAccountStore.saveAppleAccount(userID: appleUserID, email: credential.email, displayName: session.user.displayName)
                    accountMessage = "Conta Apple conectada."
                } catch {
                    accountMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            accountMessage = "Não foi possível entrar com a Conta Apple: \(error.localizedDescription)"
        }
    }

    private func createEmailAccount() {
        let email = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = accountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.contains(".") else {
            accountMessage = "Informe um e-mail válido."
            return
        }
        guard username.count >= 3 else {
            accountMessage = "O usuário precisa ter pelo menos 3 caracteres."
            return
        }
        guard accountPassword.count >= 8 else {
            accountMessage = "A senha precisa ter pelo menos 8 caracteres."
            return
        }

        Task {
            do {
                let session = try await accountAuthService.signUpWithEmail(email: email, username: username, password: accountPassword)
                createAuthenticatedProfile(
                    displayName: session.user.displayName,
                    externalKey: session.user.externalKey,
                    avatarSymbol: "person.crop.circle.fill"
                )
                accountPassword = ""
                accountMessage = "Conta criada e conectada."
            } catch AuthServiceError.backendNotConfigured {
                accountMessage = "Serviço de conta indisponível no momento."
            } catch {
                accountMessage = error.localizedDescription
            }
        }
    }

    private func loginEmailAccount() {
        let identifier = loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            accountMessage = "Informe e-mail ou usuário."
            return
        }
        guard accountPassword.count >= 8 else {
            accountMessage = "A senha precisa ter pelo menos 8 caracteres."
            return
        }

        Task {
            do {
                let session = try await accountAuthService.loginWithEmail(identifier: identifier, password: accountPassword)
                createAuthenticatedProfile(
                    displayName: session.user.displayName,
                    externalKey: session.user.externalKey,
                    avatarSymbol: "person.crop.circle.fill"
                )
                accountPassword = ""
                accountMessage = "Conta conectada."
            } catch AuthServiceError.backendNotConfigured {
                accountMessage = "Serviço de conta indisponível no momento."
            } catch {
                accountMessage = error.localizedDescription
            }
        }
    }

    private func requestEmailRecovery() {
        Task {
            do {
                accountMessage = try await accountAuthService.requestRecovery(identifier: recoveryIdentifier)
            } catch {
                accountMessage = error.localizedDescription
            }
        }
    }

    private func recoverEmailAccount() {
        Task {
            do {
                let session = try await accountAuthService.resetPassword(
                    identifier: recoveryIdentifier,
                    code: recoveryCode,
                    newPassword: recoveryNewPassword
                )
                recoveryCode = ""
                recoveryNewPassword = ""
                accountMessage = "Senha redefinida para \(session.user.username)."
                if profile == nil {
                    createAuthenticatedProfile(
                        displayName: session.user.displayName,
                        externalKey: session.user.externalKey,
                        avatarSymbol: "person.crop.circle.fill"
                    )
                }
            } catch {
                accountMessage = error.localizedDescription
            }
        }
    }

    private func createAuthenticatedProfile(displayName: String, externalKey: String, avatarSymbol: String) {
        let target: UserProfile
        if let profile {
            target = profile
        } else {
            let new = UserProfile(displayName: displayName, avatarSymbol: avatarSymbol)
            context.insert(new)
            target = new
        }
        target.displayName = displayName
        target.avatarSymbol = avatarSymbol
        target.externalKey = externalKey
        target.updatedAt = .now
        draftName = displayName
        draftAvatar = avatarSymbol
        do {
            try context.save()
            Task { @MainActor in
                await cloudBackend.syncProfile(target, performance: currentTipsterPerformance)
            }
        } catch {
            AppLogger.persistence.error("Failed to create authenticated profile: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "profile.createAuthenticatedProfile", error: error)
            accountMessage = "Não foi possível salvar a conta neste aparelho."
        }
    }

    private func loadIdentityDraft(force: Bool = false) {
        guard let profile, force || draftName.isEmpty else { return }
        draftName = profile.displayName
        draftAvatar = profile.avatarSymbol
    }

    private func saveIdentity() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let target: UserProfile
        if let profile {
            target = profile
        } else {
            let new = UserProfile(displayName: trimmed, avatarSymbol: draftAvatar)
            context.insert(new)
            target = new
        }

        target.displayName = trimmed
        target.avatarSymbol = draftAvatar
        target.updatedAt = .now

        do {
            try context.save()
            Task { @MainActor in
                await cloudBackend.syncProfile(target, performance: currentTipsterPerformance)
            }
        } catch {
            AppLogger.persistence.error("Failed to save profile identity: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "profile.saveIdentity", error: error)
        }
    }

    private func pricingQuote(match: TennisMatch, profile: UserProfile) -> BetPricingQuote {
        BetPricingEngine.quote(
            kind: selectedBetKind,
            match: match,
            player: selectedBetNeedsPlayer ? selectedPlayer : nil,
            stake: min(selectedStake, profile.points),
            preMatchOdds: oddsMatchKey == match.externalID ? preMatchOdds : [],
            liveOdds: oddsMatchKey == match.externalID ? liveOdds : []
        )
    }

    private func oddsSummaryText(for quote: BetPricingQuote) -> String {
        if quote.isBookmakerBacked {
            return "\(quote.sourceLabel). Usada só para calcular pontos simbólicos."
        }
        return "\(quote.sourceLabel): nenhum bookmaker compatível foi encontrado para essa seleção."
    }

    @MainActor
    private func loadBetOdds(for match: TennisMatch) async {
        guard let matchKey = match.externalID, !matchKey.isEmpty else {
            preMatchOdds = []
            liveOdds = []
            oddsMatchKey = nil
            oddsLoadMessage = "Odds reais exigem ID externo da partida; usando cotação simbólica."
            return
        }
        guard oddsMatchKey != matchKey || (preMatchOdds.isEmpty && liveOdds.isEmpty && oddsLoadMessage == nil) else {
            return
        }

        isLoadingBetOdds = true
        oddsLoadMessage = nil
        oddsMatchKey = matchKey
        let service = DataSyncService(context: context)

        async let preFetch = fetchBetOdds(fallback: [OddsDTO]()) {
            try await service.odds(matchKey: matchKey)
        }
        async let liveFetch = fetchBetOdds(fallback: [LiveOddsDTO]()) {
            try await service.liveOdds(matchKey: matchKey)
        }
        let (preResult, liveResult) = await (preFetch, liveFetch)
        preMatchOdds = preResult.values
        liveOdds = liveResult.values
        isLoadingBetOdds = false

        if preResult.values.isEmpty && liveResult.values.isEmpty {
            oddsLoadMessage = [preResult.error, liveResult.error].compactMap { $0 }.first
                ?? "Sem cotações publicadas; usando cotação simbólica."
        }
    }

    private struct BetOddsFetchResult<Value> {
        let values: Value
        let error: String?
    }

    private func fetchBetOdds<Value>(fallback: Value, _ work: () async throws -> Value) async -> BetOddsFetchResult<Value> {
        do {
            return BetOddsFetchResult(values: try await work(), error: nil)
        } catch {
            AppLogger.api.error("bet odds fetch failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "api", operation: "betOdds.fetch", error: error)
            return BetOddsFetchResult(values: fallback, error: "Não foi possível carregar odds reais; usando cotação simbólica.")
        }
    }

    private func shortMatchTitle(_ match: TennisMatch) -> String {
        "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }

    private func finalScorePrediction(for match: TennisMatch, player: Player?) -> String {
        let trimmed = predictedScore.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? BetSettlementEngine.defaultPredictedScore(for: match, player: player) : trimmed
    }

    private func predictionValue(for kind: BetKind, match: TennisMatch, player: Player?) -> String {
        switch kind {
        case .finalScore:
            return finalScorePrediction(for: match, player: player)
        case .tieBreakPlayed:
            return selectedTieBreakPrediction
        case .totalSets:
            return selectedTotalSets
        case .holdServe, .firstBreak, .nextGameWinner:
            return BetSettlementEngine.defaultPredictionValue(for: kind, match: match, player: player)
        default:
            return ""
        }
    }

    private func selectionLabel(for kind: BetKind, player: Player?) -> String {
        switch kind {
        case .tieBreakPlayed:
            return selectedTieBreakPrediction
        case .totalSets:
            return "\(selectedTotalSets) sets"
        default:
            return player?.name ?? "Previsão"
        }
    }

    private func totalSetOptions(for match: TennisMatch?) -> [String] {
        match?.tournament?.isMajor == true ? ["3", "4", "5"] : ["2", "3"]
    }

    private func readableSnapshot(_ rawValue: String) -> String {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let server = parts.first?.isEmpty == false ? parts[0] : "saque indefinido"
        let game = parts.dropFirst().first ?? "game indefinido"
        return "\(server), game \(game)"
    }

    private func gamePredictionExplanation(for kind: BetKind) -> String {
        switch kind {
        case .holdServe:
            return "Liquida quando o game muda e o sacador do snapshot vence o game."
        case .firstBreak:
            return "Sem ponto a ponto externo, usa a primeira mudança de game após a previsão para detectar quebra."
        case .nextGameWinner:
            return "Liquida pelo próximo game concluído após o snapshot."
        default:
            return ""
        }
    }

    private func statusTint(for status: BetStatus) -> Color {
        switch status {
        case .open: return .orange
        case .won: return .green
        case .lost: return .red
        case .void: return .secondary
        }
    }
}

private struct MatchPointEmailAccount {
    let id: String
    let email: String
    let username: String
    let recoveryCode: String
}

private enum MatchPointAccountStore {
    private enum DefaultsKey {
        static let provider = "match-point.account.provider"
        static let appleUserID = "match-point.account.apple-user-id"
        static let appleEmail = "match-point.account.apple-email"
        static let appleDisplayName = "match-point.account.apple-display-name"
        static let emailAccountID = "match-point.account.email-id"
        static let email = "match-point.account.email"
        static let username = "match-point.account.username"
    }

    private enum KeychainAccount {
        static let passwordSalt = "email-password-salt"
        static let passwordHash = "email-password-hash"
        static let recoverySalt = "email-recovery-salt"
        static let recoveryHash = "email-recovery-hash"
    }

    private static let keychain = KeychainSecretStore(service: "match-point.account")

    static func appleExternalKey(_ userID: String) -> String {
        "apple:\(userID)"
    }

    static func emailExternalKey(_ accountID: String) -> String {
        "email:\(accountID)"
    }

    static func saveAppleAccount(userID: String, email: String?, displayName: String) {
        let defaults = UserDefaults.standard
        defaults.set("apple", forKey: DefaultsKey.provider)
        defaults.set(userID, forKey: DefaultsKey.appleUserID)
        defaults.set(email, forKey: DefaultsKey.appleEmail)
        defaults.set(displayName, forKey: DefaultsKey.appleDisplayName)
    }

    static func createEmailAccount(email: String, username: String, password: String) throws -> MatchPointEmailAccount {
        let normalizedEmail = email.lowercased()
        let normalizedUsername = username.lowercased()
        if let existingEmail = UserDefaults.standard.string(forKey: DefaultsKey.email), existingEmail.lowercased() != normalizedEmail {
            throw AccountError.accountAlreadyExists
        }

        let id = UserDefaults.standard.string(forKey: DefaultsKey.emailAccountID) ?? UUID().uuidString
        let passwordSalt = UUID().uuidString
        let recoverySalt = UUID().uuidString
        let recoveryCode = generateRecoveryCode()
        guard keychain.write(hash(password, salt: passwordSalt), account: KeychainAccount.passwordHash),
              keychain.write(passwordSalt, account: KeychainAccount.passwordSalt),
              keychain.write(hash(recoveryCode, salt: recoverySalt), account: KeychainAccount.recoveryHash),
              keychain.write(recoverySalt, account: KeychainAccount.recoverySalt) else {
            throw AccountError.keychainUnavailable
        }

        let defaults = UserDefaults.standard
        defaults.set("email", forKey: DefaultsKey.provider)
        defaults.set(id, forKey: DefaultsKey.emailAccountID)
        defaults.set(normalizedEmail, forKey: DefaultsKey.email)
        defaults.set(normalizedUsername, forKey: DefaultsKey.username)
        return MatchPointEmailAccount(id: id, email: normalizedEmail, username: normalizedUsername, recoveryCode: recoveryCode)
    }

    static func recoverEmailAccount(identifier: String, recoveryCode: String, newPassword: String) throws -> MatchPointEmailAccount {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: DefaultsKey.emailAccountID),
              let email = defaults.string(forKey: DefaultsKey.email),
              let username = defaults.string(forKey: DefaultsKey.username) else {
            throw AccountError.noEmailAccount
        }
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedIdentifier == email || normalizedIdentifier == username else {
            throw AccountError.accountNotFound
        }
        guard let recoverySalt = keychain.read(account: KeychainAccount.recoverySalt),
              let expectedRecoveryHash = keychain.read(account: KeychainAccount.recoveryHash),
              hash(recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines), salt: recoverySalt) == expectedRecoveryHash else {
            throw AccountError.invalidRecoveryCode
        }
        guard newPassword.count >= 8 else {
            throw AccountError.weakPassword
        }
        let passwordSalt = UUID().uuidString
        guard keychain.write(hash(newPassword, salt: passwordSalt), account: KeychainAccount.passwordHash),
              keychain.write(passwordSalt, account: KeychainAccount.passwordSalt) else {
            throw AccountError.keychainUnavailable
        }
        return MatchPointEmailAccount(id: id, email: email, username: username, recoveryCode: "")
    }

    private static func hash(_ value: String, salt: String) -> String {
        let data = Data("\(salt):\(value)".utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func generateRecoveryCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return (0..<12)
            .map { _ in alphabet.randomElement().map(String.init) ?? "X" }
            .joined()
    }

    enum AccountError: LocalizedError {
        case accountAlreadyExists
        case accountNotFound
        case invalidRecoveryCode
        case keychainUnavailable
        case noEmailAccount
        case weakPassword

        var errorDescription: String? {
            switch self {
            case .accountAlreadyExists:
                return "Já existe uma conta de e-mail neste aparelho. Use recuperar acesso ou apague os dados da conta."
            case .accountNotFound:
                return "Nenhuma conta encontrada para este e-mail ou usuário."
            case .invalidRecoveryCode:
                return "Código de recuperação inválido."
            case .keychainUnavailable:
                return "Não foi possível salvar credenciais seguras no Keychain."
            case .noEmailAccount:
                return "Ainda não existe conta por e-mail neste aparelho."
            case .weakPassword:
                return "A nova senha precisa ter pelo menos 8 caracteres."
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension View {
    func profileListCardRow() -> some View {
        self
            .foregroundStyle(Color.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.cardSurfaceStroke.opacity(0.42), lineWidth: 1)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func profileInlineListRow() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.readableSecondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func profileTextField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(12)
            .foregroundStyle(Color.white)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
    }
}

struct PredictionStats {
    let total: Int
    let won: Int
    let lost: Int
    let open: Int
    let currentStreak: Int
    let weeklyNetPoints: Int

    init(bets: [PointBet]) {
        total = bets.count
        won = bets.filter { $0.status == .won }.count
        lost = bets.filter { $0.status == .lost }.count
        open = bets.filter { $0.status == .open }.count

        currentStreak = bets
            .sorted { $0.createdAt > $1.createdAt }
            .prefix { $0.status == .won }
            .count

        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        weeklyNetPoints = bets
            .filter { $0.createdAt >= weekAgo }
            .reduce(0) { partial, bet in
                switch bet.status {
                case .won:
                    return partial + bet.payout - bet.stake
                case .lost:
                    return partial - bet.stake
                case .open, .void:
                    return partial
                }
            }
    }

    var accuracyText: String {
        guard settled > 0 else { return "0%" }
        return "\(Int((Double(won) / Double(settled)) * 100))%"
    }

    var settled: Int {
        won + lost
    }
}
