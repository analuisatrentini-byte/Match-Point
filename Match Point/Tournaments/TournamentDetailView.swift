import SwiftUI
import SwiftData

struct TournamentDetailView: View {
    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Resumo"
        case draw = "Draw"
        case orderOfPlay = "Ordem"
        case schedule = "Cronograma"

        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query private var allMatches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var selectedTab: DetailTab = .draw
    @State private var selectedRoundIndex = 0
    @State private var selectedScheduleDate: Date?
    @State private var isPresentingScenario = false
    var tournament: Tournament

    init(tournament: Tournament) {
        self.tournament = tournament
        let threshold = Calendar.current.date(byAdding: .day, value: -180, to: .now) ?? .distantPast
        _allMatches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    private var tournamentMatches: [TennisMatch] {
        allMatches
            .filter { $0.tournament?.id == tournament.id }
            .sorted { $0.date < $1.date }
    }

    private var tournamentMode: TournamentModeDigest {
        TournamentModeDigest(tournament: tournament, matches: allMatches, rankings: rankings)
    }

    private var drawStages: [TournamentDrawStage] {
        let order = ["Round of 16", "Quarter-final", "Semi-final", "Final", "Live Round", "Upcoming Round", "Completed Match"]
        return tournamentMode.bracketSections
            .sorted { left, right in
                (order.firstIndex(of: left.0) ?? 99) < (order.firstIndex(of: right.0) ?? 99)
            }
            .enumerated()
            .map { index, section in
                TournamentDrawStage(index: index, title: section.0, matches: section.1.sorted { $0.date < $1.date })
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tournamentHero
                tabPicker

                switch selectedTab {
                case .overview:
                    overviewTab
                case .draw:
                    drawTab
                case .orderOfPlay:
                    orderOfPlayTab
                case .schedule:
                    scheduleTab
                }
            }
            .padding()
        }
        .appleSportsBackground(.clay)
        .navigationTitle(tournament.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
#endif
        .favoriteToolbar(isFavorite: tournament.isFavorite) {
            let willFavorite = !tournament.isFavorite
            tournament.isFavorite.toggle()
            if willFavorite {
                analyticsStore.record(
                    ProductAnalyticsEventName.favoriteTournamentChosen,
                    properties: ["tournamentID": tournament.behaviorKey]
                )
            }
            Task {
                await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
            }
        }
        .onAppear {
            ensureScheduleDateSelection()
            behaviorStore.recordTournamentView(tournament)
            analyticsStore.record(
                ProductAnalyticsEventName.tournamentOpened,
                properties: ["tournamentID": tournament.behaviorKey]
            )
        }
        .sheet(isPresented: $isPresentingScenario) {
            RankingScenarioView(
                tournament: tournament,
                tournamentMatches: tournamentMatches
            )
        }
    }

    private var tournamentHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.20))
                        .frame(width: 58, height: 58)
                    Image(systemName: tournament.isFavorite ? "star.circle.fill" : "trophy.fill")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(tournament.isFavorite ? .yellow : .teal)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(tournamentMode.stageLabel.uppercased())
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.teal)
                    Text(tournament.name)
                        .font(.title2.weight(.heavy))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(displayCity(for: tournament)), \(displayCountry(for: tournament))")
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                heroMetric(value: "\(tournamentMatches.count)", label: "jogos")
                heroMetric(value: tournament.tour == .atp ? "ATP" : "WTA", label: "tour")
                heroMetric(value: displaySurface(for: tournament), label: "piso")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.teal.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.teal.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private var tabPicker: some View {
        Picker("Aba", selection: $selectedTab) {
            ForEach(DetailTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tournament-detail-tab-picker")
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            infoCard
            tournamentModeCard
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info")
                .font(.headline)
            LabeledContent("Location", value: "\(tournament.city), \(tournament.country)")
            LabeledContent("Surface", value: tournament.surface)
            LabeledContent("Tour", value: tournament.tour == .atp ? "ATP" : "WTA")
            LabeledContent("Dates", value: "\(tournament.startDate.formatted(date: .abbreviated, time: .omitted)) - \(tournament.endDate.formatted(date: .abbreviated, time: .omitted))")
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var tournamentModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Modo torneio", systemImage: "sparkles")
                .font(.headline.weight(.bold))
                .foregroundStyle(.teal)

            Text(tournamentMode.headline)
                .font(.subheadline.weight(.semibold))

            FlowTagRow(items: tournamentMode.formatHighlights)

            if !tournamentMode.localStorylines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Storylines")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    ForEach(tournamentMode.localStorylines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                    }
                }
            }

            if !tournamentMode.favoritePaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Caminho dos favoritos")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    ForEach(tournamentMode.favoritePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                    }
                }
            }

            if !tournamentMode.onlyThree.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Se só puder ver 3 hoje")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    ForEach(tournamentMode.featuredReasons) { featured in
                        NavigationLink(destination: MatchDetailView(match: featured.match)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(featured.match.player1?.name ?? "TBD") vs \(featured.match.player2?.name ?? "TBD")")
                                    .font(.subheadline.weight(.semibold))
                                Text(featured.reason)
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var drawTab: some View {
        VStack(spacing: 16) {
            drawTopBar
            drawHeader

            if drawStages.isEmpty {
                ContentUnavailableView(
                    "Draw ainda vazio",
                    systemImage: "rectangle.split.3x3",
                    description: Text("Sincronize partidas do torneio para montar a chave.")
                )
                .padding(.vertical, 24)
            } else {
                roundRail
                drawCanvas
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 18)
        .background(drawSurfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.22), lineWidth: 1)
        )
        .accessibilityIdentifier("tournament-draw-tab")
    }

    private var drawTopBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fechar draw")

            Spacer()

            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.13))
                        .frame(width: 42, height: 42)
                    Image(systemName: tournament.isFavorite ? "star.circle.fill" : "trophy.fill")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(tournament.isFavorite ? .yellow : .teal)
                }
                Text(tournament.name)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    isPresentingScenario = true
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Simular cenários de ranking")
                .accessibilityIdentifier("tournament-detail-scenario-button")

                Button {
                    selectedTab = .schedule
                } label: {
                    Image(systemName: "calendar")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abrir cronograma")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var drawHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DRAW")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.teal)
                Text("Chave do torneio")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
            }
            Spacer()
            if !drawStages.isEmpty {
                Text("\(drawStages.count) fases")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
            }
        }
        .padding(.horizontal, 18)
    }

    private var drawSurfaceBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.02, green: 0.32, blue: 0.36), Color(red: 0.00, green: 0.08, blue: 0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var roundRail: some View {
        HStack(spacing: 8) {
            roundStepButton(systemImage: "chevron.left") {
                selectedRoundIndex = max(0, selectedRoundIndex - 1)
            }
            .disabled(selectedRoundIndex == 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(drawStages) { stage in
                        Button {
                            selectedRoundIndex = stage.index
                        } label: {
                            VStack(spacing: 7) {
                                Text(shortRoundTitle(stage.title))
                                    .font(.caption2.weight(.heavy))
                                    .lineLimit(1)
                                drawGlyph(for: stage, isSelected: selectedRoundIndex == stage.index)
                            }
                            .foregroundStyle(selectedRoundIndex == stage.index ? .black : Color.readableSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .frame(minWidth: 68)
                            .background(selectedRoundIndex == stage.index ? Color.white : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Fase \(stage.title)")
                    }
                }
                .padding(.horizontal, 2)
            }

            roundStepButton(systemImage: "chevron.right") {
                selectedRoundIndex = min(max(0, drawStages.count - 1), selectedRoundIndex + 1)
            }
            .disabled(selectedRoundIndex >= drawStages.count - 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.20))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var drawCanvas: some View {
        let canvasHeight = max(560, drawStages.map(drawColumnHeight(for:)).max() ?? 560)

        return ScrollView([.horizontal, .vertical], showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(drawStages) { stage in
                    drawColumn(stage, canvasHeight: canvasHeight)
                    if let nextStage = drawStages.first(where: { $0.index == stage.index + 1 }) {
                        stageConnector(from: stage, to: nextStage, canvasHeight: canvasHeight)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: canvasHeight, alignment: .topLeading)
        }
        .frame(minHeight: 560)
    }

    private func drawColumn(_ stage: TournamentDrawStage, canvasHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: drawVerticalSpacing(for: stage.index)) {
            ForEach(stage.matches) { match in
                NavigationLink(destination: MatchDetailView(match: match)) {
                    drawMatchCard(match)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, drawTopPadding(for: stage.index))
        .frame(height: canvasHeight, alignment: .topLeading)
        .opacity(stage.index == selectedRoundIndex ? 1 : 0.74)
        .scaleEffect(stage.index == selectedRoundIndex ? 1 : 0.985, anchor: .top)
        .animation(.easeInOut(duration: 0.18), value: selectedRoundIndex)
    }

    private func drawMatchCard(_ match: TennisMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(match.date.formatted(.dateTime.weekday(.abbreviated).day().month())) · \(MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches))")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                matchStateBadge(match)
            }

            drawPlayerLine(player: match.player1, match: match)
            drawPlayerLine(player: match.player2, match: match)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: drawMatchCardWidth, alignment: .leading)
        .frame(height: drawMatchCardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(drawCardFill(for: match))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(drawTint(for: match).opacity(0.38), lineWidth: 1)
                )
        )
    }

    private func drawPlayerLine(player: Player?, match: TennisMatch) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(playerLineTint(player: player, match: match).opacity(0.28))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: player?.isFavorite == true ? "star.fill" : "person.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(playerLineTint(player: player, match: match))
                }

            Text(player?.name ?? "A definir")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(player == nil ? 0.54 : 0.88))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let player, match.didPlayerWin(player) == true {
                Image(systemName: "arrowtriangle.left.fill")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
            }
        }
    }

    private func stageConnector(from stage: TournamentDrawStage, to nextStage: TournamentDrawStage, canvasHeight: CGFloat) -> some View {
        Canvas { context, size in
            let pairCount = max(1, Int(ceil(Double(stage.matches.count) / 2.0)))
            let stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            let midX = size.width * 0.52
            let endX = size.width - 1

            for pairIndex in 0..<pairCount {
                let firstIndex = min(pairIndex * 2, max(0, stage.matches.count - 1))
                let secondIndex = min(firstIndex + 1, max(0, stage.matches.count - 1))
                let targetIndex = min(pairIndex, max(0, nextStage.matches.count - 1))
                let y1 = drawCardCenterY(stageIndex: stage.index, matchIndex: firstIndex)
                let y2 = drawCardCenterY(stageIndex: stage.index, matchIndex: secondIndex)
                let targetY: CGFloat

                if nextStage.matches.isEmpty {
                    targetY = (y1 + y2) / 2
                } else {
                    targetY = drawCardCenterY(stageIndex: nextStage.index, matchIndex: targetIndex)
                }

                var path = Path()
                path.move(to: CGPoint(x: 0, y: y1))
                path.addLine(to: CGPoint(x: midX, y: y1))

                if y2 != y1 {
                    path.move(to: CGPoint(x: 0, y: y2))
                    path.addLine(to: CGPoint(x: midX, y: y2))
                    path.move(to: CGPoint(x: midX, y: y1))
                    path.addLine(to: CGPoint(x: midX, y: y2))
                }

                path.move(to: CGPoint(x: midX, y: targetY))
                path.addLine(to: CGPoint(x: endX, y: targetY))
                context.stroke(path, with: .color(.white.opacity(0.24)), style: stroke)
            }
        }
        .frame(width: 52, height: canvasHeight)
    }

    private func roundStepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.readableSecondary)
                .frame(width: 26, height: 44)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func matchStateBadge(_ match: TennisMatch) -> some View {
        if match.isLive {
            Text("LIVE")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red, in: Capsule())
        } else if match.isCompleted {
            Text("F")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.green)
        } else {
            Text("A definir")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            scheduleDayHeader
            scheduleDateRail

            if selectedScheduleMatches.isEmpty {
                ContentUnavailableView(
                    "Sem partidas neste dia",
                    systemImage: "calendar",
                    description: Text("Use a faixa de datas para navegar por todos os dias do torneio.")
                )
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(selectedScheduleMatches) { match in
                        NavigationLink(destination: MatchDetailView(match: match)) {
                            scheduleRow(for: match)
                        }
                        .buttonStyle(.plain)

                        if match.id != selectedScheduleMatches.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.08))
                                .padding(.leading, 6)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.01, green: 0.25, blue: 0.29), Color(red: 0.01, green: 0.10, blue: 0.13)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.teal.opacity(0.24), lineWidth: 1)
                )
            }
        }
        .accessibilityIdentifier("tournament-schedule-day-tab")
    }

    private var orderOfPlayTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            orderOfPlayHeader
            scheduleDateRail

            if selectedDayCourtGroups.isEmpty {
                ContentUnavailableView(
                    "Sem partidas neste dia",
                    systemImage: "list.bullet.rectangle.portrait",
                    description: Text("Escolha outro dia para ver a ordem por quadra.")
                )
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 14) {
                    ForEach(selectedDayCourtGroups) { group in
                        orderOfPlayCourtCard(group)
                    }
                }
            }
        }
        .accessibilityIdentifier("tournament-order-of-play-tab")
    }

    private var orderOfPlayHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ORDEM DE JOGOS")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.teal)
                Text(scheduleTitle(for: selectedScheduleDay))
                    .font(.title3.weight(.heavy))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(selectedDayCourtGroups.count)")
                    .font(.title3.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.teal)
                Text("quadras")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    private var selectedDayCourtGroups: [OrderOfPlayCourtGroup] {
        let matches = selectedScheduleMatches
        guard !matches.isEmpty else { return [] }
        let grouped = Dictionary(grouping: matches) { courtLabel(for: $0) }
        return grouped
            .map { OrderOfPlayCourtGroup(court: $0.key, matches: $0.value.sorted(by: orderOfPlaySort)) }
            .sorted { orderOfPlayCourtPriority(for: $0.court) < orderOfPlayCourtPriority(for: $1.court) }
    }

    // Centre Court sempre no topo; demais quadras ordenadas por número. Partidas
    // sem court oficial ficam no fim para não parecerem uma OOP confirmada.
    private func orderOfPlayCourtPriority(for court: String) -> Int {
        if court == "Quadra a confirmar" { return Int.max }
        if court.localizedCaseInsensitiveContains("centre") { return 0 }
        if court.localizedCaseInsensitiveContains("center") { return 0 }
        let digits = court.split(whereSeparator: { !$0.isNumber })
        if let first = digits.first, let value = Int(first) { return value }
        return 1_000
    }

    private func orderOfPlaySort(_ left: TennisMatch, _ right: TennisMatch) -> Bool {
        let leftOrder = left.orderOfPlaySnapshot?.order
        let rightOrder = right.orderOfPlaySnapshot?.order
        if let leftOrder, let rightOrder, leftOrder != rightOrder {
            return leftOrder < rightOrder
        }
        if leftOrder != nil, rightOrder == nil { return true }
        if leftOrder == nil, rightOrder != nil { return false }
        return left.date < right.date
    }

    private func orderOfPlayCourtCard(_ group: OrderOfPlayCourtGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(orderOfPlayCourtTint(for: group).opacity(0.22))
                        .frame(width: 34, height: 34)
                    Image(systemName: orderOfPlayCourtSymbol(for: group))
                        .font(.footnote.weight(.heavy))
                        .foregroundStyle(orderOfPlayCourtTint(for: group))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.court.uppercased())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                    Text(orderOfPlayCourtStatus(for: group))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
                Text("\(group.matches.count) jogos")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(group.matches.enumerated()), id: \.element.id) { index, match in
                    NavigationLink(destination: MatchDetailView(match: match)) {
                        orderOfPlayRow(match: match, position: index)
                    }
                    .buttonStyle(.plain)

                    if match.id != group.matches.last?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.10))
                            .padding(.leading, 60)
                    }
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.24, blue: 0.28), Color(red: 0.01, green: 0.09, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(orderOfPlayCourtTint(for: group).opacity(0.30), lineWidth: 1)
        )
    }

    private func orderOfPlayRow(match: TennisMatch, position: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if position > 0 {
                    Text("NÃO ANTES DE")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.readableSecondary)
                }
                Text(match.date.formatted(.dateTime.hour().minute()))
                    .font(.subheadline.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches).uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(1)
                    if let order = match.orderOfPlaySnapshot?.order {
                        Text("JOGO \(order)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.teal)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    orderOfPlayBadge(for: match)
                }
                orderOfPlayPlayerLine(match.player1, match: match)
                orderOfPlayPlayerLine(match.player2, match: match)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func orderOfPlayPlayerLine(_ player: Player?, match: TennisMatch) -> some View {
        HStack(spacing: 6) {
            if player?.isFavorite == true {
                Image(systemName: "star.fill")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.yellow)
            }
            Text(player?.name ?? "A definir")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(player == nil ? 0.5 : 0.86))
                .lineLimit(1)
            if let player, match.didPlayerWin(player) == true {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func orderOfPlayBadge(for match: TennisMatch) -> some View {
        if match.isLive {
            Text("AO VIVO")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.red, in: Capsule())
        } else if match.isCompleted {
            Text("FINAL")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.green)
        } else {
            Text("A JOGAR")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func orderOfPlayCourtStatus(for group: OrderOfPlayCourtGroup) -> String {
        if group.court == "Quadra a confirmar" {
            return "Quadra ainda não confirmada"
        }
        if group.matches.contains(where: { $0.isLive }) {
            return "Ao vivo agora"
        }
        if let upcoming = group.matches.first(where: { !$0.isCompleted }),
           Calendar.current.isDateInToday(upcoming.date),
           upcoming.date > .now {
            let formatted = upcoming.date.formatted(.dateTime.hour().minute())
            return "Próximo às \(formatted)"
        }
        if group.matches.allSatisfy(\.isCompleted) {
            return "Todos os jogos encerrados"
        }
        return "\(group.matches.count) jogos programados"
    }

    private func orderOfPlayCourtSymbol(for group: OrderOfPlayCourtGroup) -> String {
        if group.court == "Quadra a confirmar" { return "questionmark.circle" }
        if group.matches.contains(where: { $0.isLive }) { return "dot.radiowaves.left.and.right" }
        if group.matches.allSatisfy(\.isCompleted) { return "checkmark.seal.fill" }
        return "sportscourt.fill"
    }

    private func orderOfPlayCourtTint(for group: OrderOfPlayCourtGroup) -> Color {
        if group.court == "Quadra a confirmar" { return .gray }
        if group.matches.contains(where: { $0.isLive }) { return .red }
        if group.matches.allSatisfy(\.isCompleted) { return .green }
        if group.court.localizedCaseInsensitiveContains("centre") { return .yellow }
        if group.court.localizedCaseInsensitiveContains("center") { return .yellow }
        return .teal
    }

    private var tournamentDays: [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: tournament.startDate)
        let end = calendar.startOfDay(for: tournament.endDate)
        guard start <= end else { return [] }

        var days: [Date] = []
        var cursor = start
        while cursor <= end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private var selectedScheduleDay: Date {
        selectedScheduleDate ?? defaultScheduleDate
    }

    private var defaultScheduleDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        if tournamentDays.contains(where: { calendar.isDate($0, inSameDayAs: today) }) {
            return today
        }
        if let nextMatchDay = tournamentMatches
            .map({ calendar.startOfDay(for: $0.date) })
            .filter({ $0 >= today })
            .sorted()
            .first {
            return nextMatchDay
        }
        return tournamentDays.first ?? calendar.startOfDay(for: tournament.startDate)
    }

    private var selectedScheduleMatches: [TennisMatch] {
        let calendar = Calendar.current
        return tournamentMatches
            .filter { calendar.isDate($0.date, inSameDayAs: selectedScheduleDay) }
            .sorted { $0.date < $1.date }
    }

    private var scheduleDayHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PARTIDAS")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.teal)
                Text(scheduleTitle(for: selectedScheduleDay))
                    .font(.title3.weight(.heavy))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(selectedScheduleMatches.count)")
                    .font(.title3.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.teal)
                Text("jogos")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    private var scheduleDateRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tournamentDays, id: \.self) { day in
                    scheduleDayButton(day)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Color.teal.opacity(0.38), Color(red: 0.04, green: 0.18, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func scheduleDayButton(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: selectedScheduleDay)
        let matches = tournamentMatches.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let liveCount = matches.filter(\.isLive).count

        return Button {
            selectedScheduleDate = day
        } label: {
            VStack(spacing: 4) {
                Text(scheduleShortLabel(for: day))
                    .font(.caption2.weight(.heavy))
                    .lineLimit(1)
                Text(day.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if liveCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 5, height: 5)
                    }
                    Text("\(matches.count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? .black : Color.readableSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 76)
            .background(isSelected ? Color.white : Color.white.opacity(matches.isEmpty ? 0.06 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scheduleTitle(for: day)), \(matches.count) partidas")
    }

    private func scheduleRow(for match: TennisMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(tournament.name) - \(courtLabel(for: match)) - \(MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches))")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.readableSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)

            HStack(alignment: .center, spacing: 12) {
                schedulePlayerColumn(player: match.player1, match: match, alignment: .leading)

                VStack(spacing: 4) {
                    if match.isCompleted, !match.score.isEmpty {
                        Text(compactScore(for: match))
                            .font(.subheadline.monospacedDigit().weight(.heavy))
                            .foregroundStyle(.white)
                    } else {
                        Text(match.date, format: .dateTime.hour().minute())
                            .font(.headline.monospacedDigit().weight(.heavy))
                            .foregroundStyle(.white)
                    }
                    scheduleStatusLabel(match)
                }
                .frame(width: 78)

                schedulePlayerColumn(player: match.player2, match: match, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func schedulePlayerColumn(player: Player?, match: TennisMatch, alignment: HorizontalAlignment) -> some View {
        let isTrailing = alignment == .trailing
        return VStack(alignment: alignment, spacing: 5) {
            Circle()
                .fill(playerLineTint(player: player, match: match).opacity(0.28))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: player?.isFavorite == true ? "star.fill" : "person.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(playerLineTint(player: player, match: match))
                }

            HStack(spacing: 5) {
                if !isTrailing {
                    playerSeed(player)
                }
                Text(player?.name ?? "A definir")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(player == nil ? 0.52 : 0.78))
                    .lineLimit(1)
                    .multilineTextAlignment(isTrailing ? .trailing : .leading)
                if isTrailing {
                    playerSeed(player)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
    }

    @ViewBuilder
    private func playerSeed(_ player: Player?) -> some View {
        if let player, let rank = rankings.first(where: { $0.player?.id == player.id })?.rank, rank <= 32 {
            Text("\(rank)")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color.readableSecondary)
        }
    }

    @ViewBuilder
    private func scheduleStatusLabel(_ match: TennisMatch) -> some View {
        if match.isLive {
            Text("AO VIVO")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.red)
        } else if match.isCompleted {
            Text("Final")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.green)
        } else if Calendar.current.isDateInToday(match.date) {
            Text("Hoje")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.teal)
        } else {
            Text("Agendado")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func compactScore(for match: TennisMatch) -> String {
        guard !match.score.isEmpty else { return "Final" }
        return match.score
            .split(separator: " ")
            .suffix(3)
            .joined(separator: " ")
    }

    private func scheduleTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInTomorrow(day) { return "Amanhã" }
        if calendar.isDateInYesterday(day) { return "Ontem" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }

    private func scheduleShortLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInTomorrow(day) { return "Amanhã" }
        if calendar.isDateInYesterday(day) { return "Ontem" }
        return day.formatted(.dateTime.weekday(.abbreviated))
    }

    private func courtLabel(for match: TennisMatch) -> String {
        let court = match.orderOfPlaySnapshot?.courtName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return court.isEmpty ? "Quadra a confirmar" : court
    }

    private func ensureScheduleDateSelection() {
        guard selectedScheduleDate == nil else { return }
        selectedScheduleDate = defaultScheduleDate
    }

    private func heroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.heavy))
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func drawGlyph(for stage: TournamentDrawStage, isSelected: Bool) -> some View {
        HStack(spacing: 2) {
            let count = min(max(stage.matches.count, 1), 4)
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isSelected ? Color.black.opacity(0.72) : Color.white.opacity(0.58))
                    .frame(width: 14, height: 2)
            }
            if stage.title == "Final" {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .frame(height: 12)
    }

    private func shortRoundTitle(_ title: String) -> String {
        switch title {
        case "Round of 128": return "1ª rodada"
        case "Round of 64": return "2ª rodada"
        case "Round of 32": return "3ª rodada"
        case "Round of 16": return "4ª rodada"
        case "Quarter-final": return "QF"
        case "Semi-final": return "SF"
        case "Final": return "F"
        case "Live Round": return "Live"
        case "Upcoming Round": return "Próx."
        case "Completed Match": return "Final"
        default: return title
        }
    }

    private var drawMatchCardWidth: CGFloat { 176 }

    private var drawMatchCardHeight: CGFloat { 76 }

    private var drawBaseVerticalStep: CGFloat { drawMatchCardHeight + 18 }

    private func drawTopPadding(for stageIndex: Int) -> CGFloat {
        (pow(2, CGFloat(stageIndex)) - 1) * drawBaseVerticalStep / 2
    }

    private func drawVerticalSpacing(for stageIndex: Int) -> CGFloat {
        max(12, pow(2, CGFloat(stageIndex)) * drawBaseVerticalStep - drawMatchCardHeight)
    }

    private func drawCardCenterY(stageIndex: Int, matchIndex: Int) -> CGFloat {
        drawTopPadding(for: stageIndex)
            + drawMatchCardHeight / 2
            + CGFloat(matchIndex) * (drawMatchCardHeight + drawVerticalSpacing(for: stageIndex))
    }

    private func drawColumnHeight(for stage: TournamentDrawStage) -> CGFloat {
        guard !stage.matches.isEmpty else { return drawMatchCardHeight }
        return drawTopPadding(for: stage.index)
            + CGFloat(stage.matches.count) * drawMatchCardHeight
            + CGFloat(max(0, stage.matches.count - 1)) * drawVerticalSpacing(for: stage.index)
            + drawTopPadding(for: stage.index)
    }

    private func drawTint(for match: TennisMatch) -> Color {
        if match.isLive { return .red }
        if match.player1?.isFavorite == true || match.player2?.isFavorite == true { return .yellow }
        if match.isCompleted { return .green }
        return .teal
    }

    private func drawCardFill(for match: TennisMatch) -> Color {
        if match.isLive { return Color.red.opacity(0.18) }
        return Color.black.opacity(0.26)
    }

    private func playerLineTint(player: Player?, match: TennisMatch) -> Color {
        guard let player else { return .gray }
        if match.didPlayerWin(player) == true { return .green }
        if player.isFavorite { return .yellow }
        return .teal
    }

    private func displayCity(for tournament: Tournament) -> String {
        tournament.city == "TBD" ? "City TBA" : tournament.city
    }

    private func displayCountry(for tournament: Tournament) -> String {
        tournament.country == "TBD" ? "Country TBA" : tournament.country
    }

    private func displaySurface(for tournament: Tournament) -> String {
        tournament.surface == "Unknown" ? "Superfície a confirmar" : tournament.surface
    }
}

private struct TournamentDrawStage: Identifiable {
    let index: Int
    let title: String
    let matches: [TennisMatch]

    var id: Int { index }
}

private struct OrderOfPlayCourtGroup: Identifiable {
    let court: String
    let matches: [TennisMatch]

    var id: String { court }
}
