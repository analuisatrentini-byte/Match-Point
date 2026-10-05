import SwiftUI
import SwiftData

// MARK: - Matchboxd
struct SocialFeedView: View {
    @Environment(\.modelContext) var context
    @Query(sort: \SocialPost.createdAt, order: .reverse) var posts: [SocialPost]
    @Query(sort: \MatchPoll.createdAt, order: .reverse) var polls: [MatchPoll]
    @Query var matches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) var rankings: [RankingEntry]
    @Query(sort: \UserProfile.createdAt) var profiles: [UserProfile]

    @EnvironmentObject var cloudBackend: CloudSocialBackend
    @AppStorage("match-point.social.blocked-review-authors") var blockedReviewAuthorsData = "[]"
    @State var reviewText = ""
    @State var reviewTitle = ""
    @State var reviewRating = 4
    @State var selectedMatchID: UUID?
    @State var sortMode = "Recentes"
    // Matchboxd é um diário de avaliações de partidas. Enquetes ficam separadas
    // porque pontuam o usuário; reações rápidas e threads estilo feed foram
    // removidas para reduzir ruído e trabalho de moderação.
    // Ferramentas internas de revisão não ficam expostas para usuários finais.
    @State var feedTab: SocialTab = .conversas
    // FocusState para que o empty state do Feed possa "trazer" o usuário pro
    // input de avaliação com um único toque — em vez de mostrar uma tela
    // morta com texto.
    @FocusState private var commentFieldFocused: Bool
    @State private var isPublishingComment = false
    @State var reviewValidationMessage: String?

    enum SocialTab: String, CaseIterable, Identifiable {
        case conversas = "Avaliações"
        case enquetes = "Enquetes"
        var id: String { rawValue }
    }

    init() {
        let threshold = MatchQueryWindow.feed()
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    var profileName: String {
        profiles.first?.displayName ?? "Match Point Fan"
    }

    var featuredMatches: [TennisMatch] {
        let live = matches.filter(\.isLive)
        return live.isEmpty ? Array(matches.prefix(8)) : live
    }

    var selectedMatch: TennisMatch? {
        if let selectedMatchID, let match = featuredMatches.first(where: { $0.id == selectedMatchID }) {
            return match
        }
        return featuredMatches.first
    }

    var sortedPosts: [SocialPost] {
        let visible = posts.filter {
            !$0.isHidden
                && MatchReviewEncoding.rating(from: $0.eventKey) != nil
                && !blockedReviewAuthorKeys.contains(localReviewAuthorBlockKey(for: $0))
        }
        if sortMode == "Populares" {
            return visible.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.likes > $1.likes
            }
        }
        return visible.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.createdAt > $1.createdAt
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Modo", selection: $feedTab) {
                    ForEach(SocialTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("social-feed-tab")
                .socialGlassInlineRow()
            }

            Section {
                socialLeaderboardPreview
                    .socialGlassListCardRow()
            }

            switch feedTab {
            case .conversas:
                conversasSections
            case .enquetes:
                enquetesSections
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .accessibilityIdentifier("social-feed-screen")
        .navigationTitle("Matchboxd")
        .onAppear {
            if selectedMatchID == nil {
                selectedMatchID = featuredMatches.first?.id
            }
            Task {
                await cloudBackend.refreshAll()
            }
        }
        .refreshable {
            await cloudBackend.refreshAll()
        }
    }

    // MARK: - Leaderboard preview (top-of-feed hook)

    /// Compact top-3 podium + current user's position + link to the full
    /// `LeaderboardHubView`. Keeps ranking one-tap-away from the social feed
    /// so users don't need to hunt for it inside the Profile tab.
    @ViewBuilder
    private var socialLeaderboardPreview: some View {
        let entries = Array(cloudBackend.leaderboard.prefix(3))
        let currentIndex = cloudBackend.leaderboard.firstIndex(where: { $0.isCurrentUser })
        let currentRank = currentIndex.map { $0 + 1 } ?? (cloudBackend.leaderboard.isEmpty ? 1 : cloudBackend.leaderboard.count + 1)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ranking social", systemImage: "trophy.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                NavigationLink {
                    LeaderboardHubView()
                } label: {
                    Label("Ver tudo", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                }
                .accessibilityIdentifier("social-feed-open-leaderboard")
            }

            if entries.isEmpty {
                Text("O ranking abre depois da primeira previsão liquidada. Toque para configurar.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        socialLeaderboardEntry(entry, place: index + 1)
                    }
                }
            }

            HStack {
                Image(systemName: currentRank <= 3 ? "trophy.fill" : "figure.tennis")
                    .foregroundStyle(currentRank <= 3 ? .yellow : .green)
                Text("Você está em #\(currentRank)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(cloudBackend.leaderboardSource.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(cloudBackend.leaderboardSource.isProductionGrade ? .green : .orange)
            }
        }
        .padding(12)
        .accessibilityIdentifier("social-feed-leaderboard-preview")
    }

    private func socialLeaderboardEntry(_ entry: CloudLeaderboardEntry, place: Int) -> some View {
        let tint: Color = {
            switch place {
            case 1: return .yellow
            case 2: return Color(red: 0.75, green: 0.75, blue: 0.85)
            case 3: return Color(red: 0.80, green: 0.53, blue: 0.32)
            default: return .green
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text("#\(place)")
                .font(.caption2.monospacedDigit().weight(.black))
                .foregroundStyle(tint)
            Text(entry.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(entry.points) pts")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(entry.isCurrentUser ? .green : Color.readableSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(entry.isCurrentUser ? Color.green.opacity(0.20) : Color.cardOverlaySoft)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Avaliações (input + feed + ordenação)

    @ViewBuilder
    private var conversasSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Ordenação", selection: $sortMode) {
                    Text("Recentes").tag("Recentes")
                    Text("Populares").tag("Populares")
                }
                .pickerStyle(.segmented)

                if featuredMatches.isEmpty {
                    EmptyStateActionCard(
                        title: "Sem partidas por enquanto",
                        message: "As avaliações ficam ligadas a jogos reais. Assim que a sincronização trouxer partidas ao vivo ou futuras, o diário de partidas aparece aqui.",
                        systemImage: "star.bubble.fill"
                    )
                } else {
                    Picker("Partida", selection: Binding(
                        get: { selectedMatch?.id ?? featuredMatches[0].id },
                        set: { selectedMatchID = $0 }
                    )) {
                        ForEach(featuredMatches) { match in
                            Text(matchTitle(match)).tag(match.id)
                        }
                    }
                }

                HStack {
                    Text("Sua nota")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                    Spacer()
                    RatingStepper(rating: $reviewRating)
                }

                TextField("Título da avaliação", text: $reviewTitle)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.cardOverlaySoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextField("Escreva sua avaliação da partida", text: $reviewText, axis: .vertical)
                    .focused($commentFieldFocused)
                    .lineLimit(3...6)
                if let message = reviewValidationIssue ?? reviewValidationMessage {
                    Label(message, systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { @MainActor in
                        isPublishingComment = true
                        await addReview()
                        isPublishingComment = false
                    }
                } label: {
                    if isPublishingComment {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Publicar avaliação", systemImage: "star.bubble.fill")
                    }
                }
                .disabled(!canPublishReview || isPublishingComment)
            }
            .socialGlassListCardRow()
        }

        Section("Diário de partidas") {
            if sortedPosts.isEmpty, sortedCloudPosts.isEmpty {
                emptyFeedState
                    .socialGlassListCardRow()
            }

            ForEach(sortedCloudPosts) { post in
                cloudPostCard(post)
                    .socialGlassListCardRow()
            }

            ForEach(sortedPosts) { post in
                postCard(post)
                    .socialGlassListCardRow()
            }
        }
    }

    @ViewBuilder
    private var emptyFeedState: some View {
        if let match = selectedMatch {
            // Empty state contextual: nomeia a partida selecionada e dá um
            // CTA real que leva o usuário direto pro input. ContentUnavailable
            // com actions garante hierarquia visual consistente do iOS 17+.
            ContentUnavailableView {
                Label("Nenhuma avaliação ainda", systemImage: "star.bubble.fill")
            } description: {
                Text("Seja a primeira pessoa a avaliar \(match.player1TeamName) vs \(match.player2TeamName).")
            } actions: {
                Button {
                    commentFieldFocused = true
                } label: {
                    Label("Avaliar agora", systemImage: "star.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("social-empty-feed-cta")
            }
        } else {
            ContentUnavailableView(
                "Diário vazio",
                systemImage: "star.bubble.fill",
                description: Text("Avaliações aparecem aqui assim que houver partidas no app.")
            )
        }
    }

    // MARK: - Enquetes (criar + listar)

    @ViewBuilder
    private var enquetesSections: some View {
        Section("Partida") {
            if featuredMatches.isEmpty {
                Text("Enquetes por jogo dependem de partidas sincronizadas pela API.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .socialGlassListCardRow()
            } else {
                Picker("Partida", selection: Binding(
                    get: { selectedMatch?.id ?? featuredMatches[0].id },
                    set: { selectedMatchID = $0 }
                )) {
                    ForEach(featuredMatches) { match in
                        Text(matchTitle(match)).tag(match.id)
                    }
                }
                .socialGlassInlineRow()
            }
        }

        Section("Nova enquete") {
            if let selectedMatch {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A enquete usa uma pergunta padrão da partida para manter a conversa focada e segura.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)

                    Button {
                        createPoll(for: selectedMatch)
                    } label: {
                        Label("Criar enquete", systemImage: "chart.bar.doc.horizontal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .socialGlassListCardRow()
            } else {
                Text("Selecione uma partida acima para criar uma enquete.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .socialGlassListCardRow()
            }
        }

        Section("Enquetes ativas") {
            if cloudBackend.polls.isEmpty, polls.isEmpty {
                emptyPollsState
                    .socialGlassListCardRow()
            }

            ForEach(cloudBackend.polls) { poll in
                cloudPollCard(poll)
                    .socialGlassListCardRow()
            }

            ForEach(polls) { poll in
                pollCard(poll)
                    .socialGlassListCardRow()
            }
        }
    }

    @ViewBuilder
    private var emptyPollsState: some View {
        if let match = selectedMatch {
            ContentUnavailableView {
                Label("Sem enquetes ainda", systemImage: "chart.bar.doc.horizontal")
            } description: {
                Text("Faça a primeira enquete sobre \(match.player1TeamName) vs \(match.player2TeamName).")
            } actions: {
                Button {
                    createPoll(for: match)
                } label: {
                    Label("Criar enquete", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("social-empty-polls-cta")
            }
        } else {
            ContentUnavailableView(
                "Sem enquetes ainda",
                systemImage: "chart.bar.doc.horizontal",
                description: Text("As enquetes aparecem aqui assim que houver partidas no app.")
            )
        }
    }
}

private struct RatingStepper: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    rating = value
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .foregroundStyle(value <= rating ? .yellow : Color.readableSecondary)
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) estrelas")
            }
        }
        .accessibilityIdentifier("match-review-rating")
    }
}

private struct SocialGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .foregroundStyle(Color.white)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface)
            .clipShape(shape)
            .overlay(shape.stroke(Color.cardSurfaceStroke.opacity(0.30), lineWidth: 1))
    }
}

private extension View {
    func socialGlassListCardRow(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        self
            .modifier(SocialGlassCardModifier(cornerRadius: cornerRadius, padding: padding))
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func socialGlassInlineRow() -> some View {
        self
            .padding(6)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension MatchPoll {
    var totalVotes: Int {
        votesOne + votesTwo + votesThree
    }
}

struct FlowTagRow: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "seal.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
