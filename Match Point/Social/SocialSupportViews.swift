import SwiftUI
import SwiftData

// MARK: - Social Support Views

// MARK: - Ranking
//
// `SocialRankingScope` e o branching por escopo no `SocialRankingBuilder`
// foram removidos junto com o picker do Perfil — o ranking agora é SEMPRE
// semanal. Sem enum, sem switch, sem dead branches; só uma função pura.

enum SocialRankingBuilder {
    /// Constrói o leaderboard semanal local com dados reais do aparelho. O
    /// ranking global, quando disponível, vem de `CloudSocialBackend`; o local
    /// não inventa concorrentes para evitar uma disputa enganosa.
    static func weeklyRows(
        profile: UserProfile?,
        bets: [PointBet],
        matches: [TennisMatch]
    ) -> [(name: String, points: Int, isCurrentUser: Bool)] {
        let current = weeklyScore(profile: profile, bets: bets, matches: matches)
        return [(profile?.displayName ?? "Você", current, true)]
    }

    private static func weeklyScore(
        profile: UserProfile?,
        bets: [PointBet],
        matches: [TennisMatch]
    ) -> Int {
        let now = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let filteredBets = bets.filter { $0.createdAt >= start }
        let base = filteredBets.reduce(0) { partial, bet in
            switch bet.status {
            case .won: return partial + bet.payout
            case .lost: return partial - bet.stake
            case .open, .void: return partial
            }
        }
        let liveBonus = matches.filter(\.isLive).count * 5
        return max(0, base + liveBonus)
    }
}

struct PublicProfileView: View {
    let profile: UserProfile
    let rank: Int
    let predictionStats: PredictionStats
    let favoritePlayers: [Player]
    let bets: [PointBet]
    let matches: [TennisMatch]
    let achievements: [String]

    /// Legacy initializer for existing callers that don't have `matches`.
    /// Falls back to an empty slice so the heatmap / surface stats still work.
    init(
        profile: UserProfile,
        rank: Int,
        predictionStats: PredictionStats,
        favoritePlayers: [Player],
        bets: [PointBet],
        achievements: [String],
        matches: [TennisMatch] = []
    ) {
        self.profile = profile
        self.rank = rank
        self.predictionStats = predictionStats
        self.favoritePlayers = favoritePlayers
        self.bets = bets
        self.matches = matches
        self.achievements = achievements
    }

    private var season: SocialSeason {
        SocialSeason.current()
    }

    private var weeklySummary: WeeklySocialSummary {
        WeeklySocialSummary(
            season: season,
            rank: rank,
            localLeaderboardCount: max(rank, 1),
            stats: predictionStats
        )
    }

    private var signaturePicks: [PointBet] {
        bets.sorted {
            if $0.status != $1.status {
                return $0.status == .won
            }
            return $0.createdAt > $1.createdAt
        }
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

    private var earnedBadges: [SocialBadge] {
        badges.filter(\.isUnlocked)
    }

    private var highlights: [PickHighlight] {
        PickHighlightBuilder.highlights(
            bets: bets,
            matches: matches,
            favoritePlayers: favoritePlayers
        )
    }

    private var heatmap: PickActivityHeatmap {
        PickActivityHeatmap.build(from: bets)
    }

    private var surfaceStats: [(surface: String, stats: PickHighlightBuilder.SurfaceWinRate)] {
        PickHighlightBuilder.surfaceWinRates(bets: bets)
            .filter { $0.value.settled > 0 }
            .sorted { $0.value.winRate > $1.value.winRate }
            .map { ($0.key, $0.value) }
    }

    // Scales with Dynamic Type so a11y-large users get a proportionally
    // bigger avatar instead of a clipped one.
    @ScaledMetric(relativeTo: .largeTitle) private var avatarIconSize: CGFloat = 52

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        Image(systemName: profile.avatarSymbol)
                            .font(.system(size: avatarIconSize))
                            .foregroundStyle(.green)
                            .frame(width: avatarIconSize + 20, height: avatarIconSize + 20)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.displayName)
                                .font(.title2.weight(.bold))
                            Text("#\(rank) no ranking social")
                                .font(.subheadline)
                                .foregroundStyle(Color.readableSecondary)
                            Text("\(profile.points) pontos")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        shareProfileButton
                    }

                    Text(weeklySummary.weeklyReadLine)
                        .font(.headline.weight(.bold))
                    Text(weeklySummary.streakLine)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                .appListCardRow(cornerRadius: 22, padding: 18)
            }

            if !highlights.isEmpty {
                Section("Destaques") {
                    ForEach(highlights) { highlight in
                        highlightRow(highlight)
                            .appListCardRow()
                    }
                }
            }

            Section("Estatísticas") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    publicMetric("Previsões", "\(predictionStats.total)")
                    publicMetric("Acerto", predictionStats.accuracyText)
                    publicMetric("Ganhou", "\(predictionStats.won)")
                    publicMetric("Streak", "\(predictionStats.currentStreak)")
                }
                .appListCardRow()
            }

            if !surfaceStats.isEmpty {
                Section("Por superfície") {
                    ForEach(surfaceStats, id: \.surface) { row in
                        surfaceRow(surface: row.surface, stats: row.stats)
                            .appListCardRow()
                    }
                }
            }

            Section("Atividade recente") {
                VStack(alignment: .leading, spacing: 12) {
                    heatmapGrid
                    heatmapLegend
                }
                .appListCardRow()
            }

            Section("Temporada") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Janela", value: season.subtitle)
                    LabeledContent("Semana", value: "\(predictionStats.weeklyNetPoints) pts")
                    LabeledContent("Leitura", value: "\(weeklySummary.percentile)%")
                }
                .appListCardRow()
            }

            Section("Conquistas") {
                VStack(alignment: .leading, spacing: 12) {
                    FlowTagRow(items: achievements)

                    if !earnedBadges.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                            ForEach(earnedBadges) { badge in
                                BadgeChip(badge: badge)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .appListCardRow()
            }

            Section("Favoritos") {
                if favoritePlayers.isEmpty {
                    Text("Nenhum favorito público ainda.")
                        .foregroundStyle(Color.readableSecondary)
                        .appListCardRow()
                } else {
                    ForEach(favoritePlayers) { player in
                        NavigationLink(destination: PlayerDetailView(player: player)) {
                            Label(player.name, systemImage: "star.fill")
                        }
                        .appListCardRow()
                    }
                }
            }

            Section("Histórico recente") {
                if bets.isEmpty {
                    Text("Sem previsões públicas ainda.")
                        .foregroundStyle(Color.readableSecondary)
                        .appListCardRow()
                } else {
                    ForEach(signaturePicks.prefix(6)) { bet in
                        NavigationLink(destination: PickDetailView(bet: bet)) {
                            PickShareCard(
                                bet: bet,
                                profileName: profile.displayName,
                                weeklySummary: weeklySummary
                            )
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .appListCardRow(cornerRadius: 22, padding: 10)
                        .accessibilityIdentifier("public-profile-pick-\(bet.id.uuidString)")
                    }
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Perfil público")
    }

    private var shareProfileButton: some View {
        let text = """
        Perfil Match Point — \(profile.displayName)
        #\(rank) na liga social • \(predictionStats.accuracyText) de acerto
        Streak: \(predictionStats.currentStreak) • \(profile.points) pts
        \(weeklySummary.weeklyReadLine)
        """
        return ShareLink(item: text) {
            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        }
        .accessibilityLabel("Compartilhar perfil")
        .accessibilityIdentifier("public-profile-share")
    }

    private func highlightRow(_ highlight: PickHighlight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: highlight.systemImage)
                .font(.title3)
                .foregroundStyle(highlight.tint.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title)
                    .font(.subheadline.weight(.semibold))
                Text(highlight.detail)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            Spacer()
            Text(highlight.value)
                .font(.headline.monospacedDigit().weight(.bold))
                .foregroundStyle(highlight.tint.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityIdentifier("public-profile-highlight-\(highlight.id)")
    }

    private func surfaceRow(surface: String, stats: PickHighlightBuilder.SurfaceWinRate) -> some View {
        HStack {
            Label(surface, systemImage: "circle.grid.2x2")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(Int((stats.winRate * 100).rounded()))%")
                .font(.headline.monospacedDigit())
                .foregroundStyle(stats.winRate >= 0.55 ? .green : (stats.winRate >= 0.35 ? .orange : .red))
            Text("(\(stats.wins)V \(stats.losses)D)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private var heatmapGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(heatmap.cells) { cell in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(heatmapColor(for: cell))
                    .frame(height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                    )
                    .accessibilityLabel(heatmapAccessibilityLabel(for: cell))
            }
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 6) {
            Text("Menos")
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.green.opacity(0.15 + Double(level) * 0.20))
                    .frame(width: 14, height: 8)
            }
            Text("Mais")
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
            Spacer()
            Text("Últimos 28 dias")
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func heatmapColor(for cell: PickActivityHeatmap.Cell) -> Color {
        if cell.bets == 0 { return Color.white.opacity(0.05) }
        if cell.netPoints < 0 {
            return Color.red.opacity(0.25 + cell.intensity * 0.55)
        }
        return Color.green.opacity(0.15 + cell.intensity * 0.70)
    }

    private func heatmapAccessibilityLabel(for cell: PickActivityHeatmap.Cell) -> String {
        let date = cell.date.formatted(date: .abbreviated, time: .omitted)
        if cell.bets == 0 { return "\(date), sem picks" }
        return "\(date), \(cell.bets) picks, \(cell.wins) vitórias, \(cell.losses) derrotas"
    }

    private func publicMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.heavy))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

#if DEBUG
struct ModerationDashboardView: View {
    @Query(sort: \SocialPost.createdAt, order: .reverse) private var posts: [SocialPost]
    @EnvironmentObject private var cloudBackend: CloudSocialBackend
    @State private var filter = "Reportados"
    @State private var banReason = "Violação das regras da comunidade"

    private var filteredLocalPosts: [SocialPost] {
        switch filter {
        case "Ocultos":
            return posts.filter(\.isHidden)
        case "Fixados":
            return posts.filter(\.isPinned)
        default:
            return posts.filter { $0.reportCount > 0 }
        }
    }

    private var filteredCloudPosts: [CloudSocialPost] {
        switch filter {
        case "Ocultos":
            return cloudBackend.posts.filter(\.isHidden)
        case "Fixados":
            return cloudBackend.posts.filter(\.isPinned)
        default:
            return cloudBackend.posts.filter { $0.reportCount > 0 }
        }
    }

    private var hasAdminAccess: Bool {
        CloudSocialBackend.isSocialBackendConfigured && CloudSocialBackend.hasModerationAdminToken
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Revisão", value: hasAdminAccess ? "Disponível" : "Indisponível")
                LabeledContent("Sincronização", value: cloudBackend.state.label)
            } header: {
                Text("Status de comunidade")
            } footer: {
                Text("Usuários podem publicar, votar e denunciar. A revisão de conteúdo é controlada pela equipe do Match Point.")
            }

            Section("Regras") {
                if cloudBackend.communityRules.isEmpty {
                    Label("Sem regras carregadas.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.readableSecondary)
                } else {
                    ForEach(cloudBackend.communityRules, id: \.self) { rule in
                        Label(rule, systemImage: "checkmark.shield")
                    }
                }

                NavigationLink {
                    CommunityRulesEditorView(initialRules: cloudBackend.communityRules) { rules in
                        Task { await cloudBackend.saveCommunityRules(rules) }
                    }
                } label: {
                    Label("Editar regras", systemImage: "square.and.pencil")
                }
                .disabled(!hasAdminAccess)
            }

            Section {
                Picker("Filtro", selection: $filter) {
                    Text("Reportados").tag("Reportados")
                    Text("Ocultos").tag("Ocultos")
                    Text("Fixados").tag("Fixados")
                }
                .pickerStyle(.segmented)

                TextField("Motivo padrão para banimento", text: $banReason)
            }

            Section("Fila de revisão") {
                if cloudBackend.moderationQueue.isEmpty {
                    Text(hasAdminAccess ? "Nada pendente." : "Fila de revisão indisponível no momento.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }

                ForEach(cloudBackend.moderationQueue) { item in
                    moderationQueueRow(item)
                }
            }

            Section("Avaliações da comunidade") {
                if filteredCloudPosts.isEmpty {
                    Text("Nada neste filtro.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }

                ForEach(filteredCloudPosts) { post in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(post.body)
                        Text("\(post.reportCount) denúncia(s) • \(post.replyCount) resposta(s)")
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                        HStack {
                            Button(post.isPinned ? "Desfixar" : "Fixar") {
                                Task { await cloudBackend.setPinned(post, isPinned: !post.isPinned) }
                            }
                            .buttonStyle(.borderless)

                            Button(post.isHidden ? "Restaurar" : "Ocultar") {
                                Task { await cloudBackend.setHidden(post, isHidden: !post.isHidden) }
                            }
                            .buttonStyle(.borderless)

                            Button("Banir autor", role: .destructive) {
                                Task { await cloudBackend.banAuthor(of: post, reason: banReason) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(post.authorRecordName.isEmpty || !hasAdminAccess)

                            Button("Denunciar") {
                                Task { await cloudBackend.reportPost(post) }
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Local") {
                if filteredLocalPosts.isEmpty {
                    Text("Nada neste filtro.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }

                ForEach(filteredLocalPosts) { post in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(post.body)
                        Text("\(post.reportCount) denúncia(s) • \(post.replyCount) resposta(s)")
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                        HStack {
                            Button(post.isPinned ? "Desfixar" : "Fixar") {
                                post.isPinned.toggle()
                            }
                            .buttonStyle(.borderless)

                            Button(post.isHidden ? "Restaurar" : "Ocultar") {
                                post.isHidden.toggle()
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Auditoria") {
                if cloudBackend.moderationAudit.isEmpty {
                    Text(hasAdminAccess ? "Sem eventos de auditoria." : "Auditoria indisponível no momento.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }

                ForEach(cloudBackend.moderationAudit.prefix(20)) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(readableAuditEvent(event))
                            .font(.subheadline.weight(.semibold))
                        Text([event.postID, event.userRecordName, event.actor].compactMap { $0 }.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .appleSportsBackground(.royal)
        .navigationTitle("Moderação")
        .task {
            await cloudBackend.refreshAll()
            await cloudBackend.refreshModerationAdmin()
        }
        .refreshable {
            await cloudBackend.refreshAll()
            await cloudBackend.refreshModerationAdmin()
        }
    }

    private func moderationQueueRow(_ item: CloudModerationQueueItem) -> some View {
        let post = cloudBackend.posts.first { $0.id == item.postID }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.postID)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(item.reportCount)x")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
            }

            Text("Motivo recente: \(item.latestReason)")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)

            if let post {
                Text(post.body)
                    .font(.caption)
                    .lineLimit(2)

                HStack {
                    Button(post.isHidden ? "Restaurar" : "Ocultar") {
                        Task { await cloudBackend.setHidden(post, isHidden: !post.isHidden) }
                    }
                    .buttonStyle(.borderless)

                    Button("Banir autor", role: .destructive) {
                        Task { await cloudBackend.banAuthor(of: post, reason: banReason) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(post.authorRecordName.isEmpty)
                }
                .font(.caption)
            } else if let moderation = item.moderation {
                Text(moderation.isHidden ? "Publicação ocultada pela moderação." : "Publicação ainda visível.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    private func readableAuditEvent(_ event: CloudModerationAuditEvent) -> String {
        switch event.type {
        case "report":
            return "Denúncia recebida"
        case "moderation-action":
            return "Ação: \(event.action ?? "moderação")"
        case "community-rules-update":
            return "Regras atualizadas"
        case "user-ban":
            return "Usuário banido"
        case "user-unban":
            return "Usuário restaurado"
        default:
            return event.type
        }
    }
}

private struct CommunityRulesEditorView: View {
    @State private var draftText: String
    let onSave: ([String]) -> Void

    init(initialRules: [String], onSave: @escaping ([String]) -> Void) {
        _draftText = State(initialValue: initialRules.joined(separator: "\n"))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftText)
                    .frame(minHeight: 220)
                    .accessibilityIdentifier("moderation-rules-editor")

                Button {
                    onSave(draftRules)
                } label: {
                    Label("Salvar regras", systemImage: "checkmark.circle.fill")
                }
                .disabled(draftRules.isEmpty)
                .accessibilityIdentifier("moderation-save-rules")
            } footer: {
                Text("Uma regra por linha. O histórico de alterações é mantido para auditoria interna.")
            }
        }
        .navigationTitle("Regras")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var draftRules: [String] {
        draftText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
#endif
