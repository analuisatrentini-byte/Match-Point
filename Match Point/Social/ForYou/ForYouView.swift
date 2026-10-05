import SwiftUI
import SwiftData

struct ForYouView: View {
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @StateObject private var explanations = FeedExplanationGenerator.shared
    @Query private var matches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var showPreferences = false
    @State private var featuredExplanation: String?
    @State private var isGeneratingExplanation = false
    @State private var didRecordMatchBrainViewed = false

    // Restrict the feed to a rolling window so installs with years of synced
    // history don't drag the full table into memory on every navigation. The
    // threshold is captured once per view instance — the @Query refreshes when
    // the model context changes, which is more than often enough for a feed.
    init() {
        let threshold = MatchQueryWindow.feed()
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Título grande sem nada interativo. Conteúdo (valor) vem
                // imediatamente abaixo. Preferências ficam no FINAL do scroll
                // como link explícito "Personalizar feed" — princípio
                // value-first / progressive disclosure.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Match Brain")
                        .font(.largeTitle.weight(.heavy))
                    Text("O jogo certo para abrir agora, com o motivo antes do resto.")
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                }

                // Feed (a feature principal) vem primeiro — OU empty state
                // contextual quando não há nada pra mostrar.
                if feedSections.isEmpty {
                    emptyFeedState
                } else {
                    matchBrainDashboard
                    if let featuredMatch {
                        aiExplanationCard(for: featuredMatch)
                    }
                    ForEach(feedSections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title)
                                .font(.title3.weight(.bold))
                            Text(section.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)

                            ForEach(section.matches) { match in
                                NavigationLink(destination: MatchDetailView(match: match)) {
                                    CachedMatchHeroCard(
                                        match: match,
                                        rankings: rankings,
                                        allMatches: matches
                                    )
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(TapGesture().onEnded {
                                    recordMatchBrainOpen(match, source: section.title)
                                })
                            }
                        }
                    }
                }

                // "Personalizar feed" agora fica AQUI no rodapé. Quem mexer
                // nas preferências está intencionalmente buscando isso; quem
                // só quer ver o feed nunca precisa olhar.
                personalizeFooterLink
            }
            .padding()
        }
        .appleSportsBackground(.royal)
        .navigationTitle("Para você")
        .onAppear {
            guard !didRecordMatchBrainViewed else { return }
            didRecordMatchBrainViewed = true
            analyticsStore.record(
                ProductAnalyticsEventName.matchBrainViewed,
                properties: [
                    "sections": "\(feedSections.count)",
                    "hasFeaturedMatch": featuredMatch == nil ? "false" : "true"
                ]
            )
        }
        .sheet(isPresented: $showPreferences) {
            NavigationStack {
                preferencesSheet
                    .navigationTitle("Personalizar feed")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Concluído") { showPreferences = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Empty state contextual quando `feedSections.isEmpty`. Antes a tela
    /// mostrava só os 2 cards auxiliares (Live Tracker + Meus Favoritos) +
    /// footer "Personalizar", sem explicar o que era "Para Você" ou por que
    /// estava vazio. Agora dá: (1) explicação curta da feature, (2) diagnóstico
    /// (sem partidas vs filtro restritivo), (3) ação primária pra resolver.
    private var emptyFeedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feed vazio")
                .font(.headline)

            Text(emptyPrimaryReason)
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)

            if let secondaryReason = emptySecondaryReason {
                Text(secondaryReason)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }

            Button {
                showPreferences = true
            } label: {
                Label("Ajustar filtros", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.20), in: Capsule())
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityIdentifier("foryou-empty-personalize")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyPrimaryReason: String {
        switch experienceStore.preferences.tourFilter {
        case .atp: return "Filtro ativo: só ATP. Mude para \"ATP e WTA\" para ver os dois circuitos."
        case .wta: return "Filtro ativo: só WTA. Mude para \"ATP e WTA\" para ver os dois circuitos."
        case .all:
            if matches.isEmpty { return "Nenhuma partida sincronizada ainda — aguarde alguns instantes." }
            return "Nenhuma partida corresponde ao filtro atual."
        }
    }

    private var emptySecondaryReason: String? {
        if experienceStore.preferences.showOnlyRelevantNow {
            return "\"Só os jogos importantes\" está ligado e pode estar ocultando partidas."
        }
        return nil
    }

    private var personalizeFooterLink: some View {
        Button {
            showPreferences = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personalizar feed")
                        .font(.subheadline.weight(.semibold))
                    Text("Personalize o que aparece no seu feed.")
                        .font(.caption2)
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            .padding(12)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Personalizar feed")
        .accessibilityIdentifier("foryou-personalize")
    }

    // filterSummaryText removida — a sub-linha do botão "Personalizar feed"
    // é agora estática ("Personalize o que aparece no seu feed."). O estado
    // dinâmico das prefs (ATP/WTA, favoritos primeiro, etc.) só aparece dentro
    // do próprio sheet, onde o usuário consegue mexer; mostrar resumo técnico
    // no footer só servia pra confundir quem nunca abriu a tela de prefs.

    private var preferencesSheet: some View {
        Form {
            Section {
                Picker("Tour", selection: Binding(
                    get: { experienceStore.preferences.tourFilter },
                    set: { newValue in experienceStore.update { $0.tourFilter = newValue } }
                )) {
                    ForEach(TourPresentationFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Qual tour mostrar")
            } footer: {
                Text("Escolha se você quer ver partidas do circuito masculino (ATP), feminino (WTA) ou os dois juntos.")
            }

            Section {
                Toggle("Seus jogadores primeiro", isOn: Binding(
                    get: { experienceStore.preferences.prioritizeFavorites },
                    set: { newValue in experienceStore.update { $0.prioritizeFavorites = newValue } }
                ))
            } footer: {
                Text("Quando ligado, partidas com seus favoritos pulam pro topo do feed mesmo se outros jogos estiverem ao vivo.")
            }

            Section {
                Toggle("Só os jogos importantes", isOn: Binding(
                    get: { experienceStore.preferences.showOnlyRelevantNow },
                    set: { newValue in experienceStore.update { $0.showOnlyRelevantNow = newValue } }
                ))
            } footer: {
                Text("Esconde partidas sem ninguém famoso, fora dos seus favoritos. O Match Brain decide o que é \"importante\" baseado em ranking, favorito e momento ao vivo.")
            }

            Section {
                Picker("Estilo", selection: Binding(
                    get: { experienceStore.preferences.matchBrainStyle },
                    set: { newValue in experienceStore.update { $0.matchBrainStyle = newValue } }
                )) {
                    ForEach(MatchBrainStylePreference.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }

                Picker("Horário", selection: Binding(
                    get: { experienceStore.preferences.matchBrainViewingWindow },
                    set: { newValue in experienceStore.update { $0.matchBrainViewingWindow = newValue } }
                )) {
                    ForEach(MatchBrainViewingWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
            } header: {
                Text("Match Brain")
            } footer: {
                Text("Ajusta recomendações por estilo de jogo e janela de horário, além dos seus favoritos e tour.")
            }

            Section {
                Toggle("Modo spoiler-free", isOn: Binding(
                    get: { experienceStore.preferences.spoilerFreeMode },
                    set: { newValue in
                        experienceStore.update { $0.spoilerFreeMode = newValue }
                        UserDefaults.standard.set(!newValue, forKey: "match-point.widgets.show-result-spoilers")
                        UserDefaults(suiteName: "group.ALTB.Match-Point")?.set(!newValue, forKey: "match-point.widgets.show-result-spoilers")
                    }
                ))
            } footer: {
                Text("Oculta resultados finais em alertas e widgets quando você pretende ver a partida depois.")
            }
        }
    }

    private var matchBrainDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 5) {
                    Text(matchBrainDigest.headline)
                        .font(.headline)
                    Text(matchBrainDigest.featuredMatch.map(primaryBrainLine(for:)) ?? "Quando houver partidas sincronizadas, o Match Brain prioriza favoritos, tour, estilo, horário e pressão ao vivo.")
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            if !matchBrainDigest.whyNowAlerts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Por que agora", systemImage: "bell.badge.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.orange)
                    ForEach(matchBrainDigest.whyNowAlerts, id: \.self) { alert in
                        Text(alert)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let rankingProjection = featuredRankingProjection {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.blue)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Impacto no ranking")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.blue)
                        Text(rankingProjection)
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("match-brain-ranking-impact")
            }

            if !matchBrainDigest.liveComparisons.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Comparação ao vivo", systemImage: "list.number")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.readableSecondary)
                    ForEach(matchBrainDigest.liveComparisons) { comparison in
                        NavigationLink(destination: MatchDetailView(match: comparison.match)) {
                            liveComparisonRow(comparison)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            recordMatchBrainOpen(comparison.match, source: "live_comparison")
                        })
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(matchBrainDigest.history.title)
                        .font(.caption.weight(.bold))
                    Text(matchBrainDigest.history.detail)
                        .font(.caption2)
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.green.opacity(0.22), lineWidth: 1)
        )
        .accessibilityIdentifier("match-brain-dashboard")
    }

    private func liveComparisonRow(_ comparison: MatchBrainLiveComparison) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("#\(comparison.rank)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.green)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comparison.matchup)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(comparison.score)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                }
                Text(comparison.headline)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                Text(comparison.detail)
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var matchBrainDigest: MatchBrainDigest {
        MatchBrainDigest(
            matches: matches,
            rankings: rankings,
            preferences: experienceStore.preferences,
            behavior: behaviorStore.snapshot
        )
    }

    private func primaryBrainLine(for match: TennisMatch) -> String {
        let label = "\(match.player1TeamName) vs \(match.player2TeamName)"
        if match.isLive {
            return String(format: String(localized: "%@ é a melhor abertura agora: %@."), label, explanationContext(for: match))
        }
        if match.isUpcoming {
            return String(format: String(localized: "%@ é o alerta mais importante da próxima janela."), label)
        }
        return String(format: String(localized: "%@ tem o contexto mais útil para revisar."), label)
    }

    private var feedSections: [FeedSectionModel] {
        ForYouFeedBuilder.sections(
            matches: matches,
            rankings: rankings,
            preferences: experienceStore.preferences,
            behavior: behaviorStore.snapshot
        )
    }

    private var featuredMatch: TennisMatch? {
        matchBrainDigest.featuredMatch ?? feedSections.first?.matches.first
    }

    private var featuredRankingProjection: String? {
        guard let featuredMatch else { return nil }
        return RankingProjectionEngine.projectionText(for: featuredMatch, rankings: rankings)
    }

    private func recordMatchBrainOpen(_ match: TennisMatch, source: String) {
        analyticsStore.record(
            ProductAnalyticsEventName.matchBrainMatchOpened,
            properties: [
                "matchID": match.behaviorKey,
                "source": source,
                "isLive": match.isLive ? "true" : "false",
                "isFavorite": match.isFavorite ? "true" : "false"
            ]
        )
    }

    private func aiExplanationCard(for match: TennisMatch) -> some View {
        let rankByPlayerID = rankLookup(from: rankings)
        let reasons = MatchIntelligence.relevanceReasons(
            for: match,
            rankByPlayerID: rankByPlayerID,
            behavior: behaviorStore.snapshot
        )
        let player1Name = match.player1?.name ?? String(localized: "Jogador 1")
        let player2Name = match.player2?.name ?? String(localized: "Jogador 2")
        let matchLabel = "\(player1Name) vs \(player2Name)"
        let contextSummary = explanationContext(for: match)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Por que estamos destacando isso")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                Spacer()
                if explanations.availability != .ready && explanations.availability != .unknown {
                    Text(availabilityBadge)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                        .foregroundStyle(.purple)
                }
            }

            if let featuredExplanation, !isGeneratingExplanation {
                Text(featuredExplanation)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Gerando explicação…")
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.15), Color.cardSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.28), lineWidth: 1)
        )
        .accessibilityIdentifier("foryou-ai-explanation")
        .task(id: match.id) {
            isGeneratingExplanation = true
            featuredExplanation = nil
            let text = await explanations.generate(
                for: match.id,
                matchLabel: matchLabel,
                reasons: reasons,
                contextSummary: contextSummary
            )
            featuredExplanation = text
            isGeneratingExplanation = false
        }
    }

    private var availabilityBadge: String {
        switch explanations.availability {
        case .ready, .unknown: return ""
        case .downloading: return String(localized: "modelo baixando")
        case .notEligible: return String(localized: "dispositivo não elegível")
        case .appleIntelligenceOff: return String(localized: "Apple Intelligence off")
        case .unsupported: return String(localized: "iOS mais antigo")
        }
    }

    private func explanationContext(for match: TennisMatch) -> String {
        var parts: [String] = []
        if let tournament = match.tournament { parts.append(tournament.name) }
        if match.isLive {
            parts.append(String(localized: "ao vivo"))
            if !match.gameScore.isEmpty { parts.append(String(format: String(localized: "game %@"), match.gameScore)) }
        } else if match.isUpcoming {
            let hours = Int(max(0, match.date.timeIntervalSinceNow / 3600))
            parts.append(String(format: String(localized: "começa em %dh"), hours))
        }
        return parts.joined(separator: " • ")
    }

    private func rankLookup(from rankings: [RankingEntry]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for entry in rankings {
            guard let id = entry.player?.id else { continue }
            if map[id] == nil { map[id] = entry.rank }
        }
        return map
    }

}
