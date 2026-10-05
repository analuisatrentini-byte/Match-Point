import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import Match_Point

@Suite(.serialized)
struct Match_PointTests {
    @MainActor
    @Test func modelContainerSupportsRealModels() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let player = Player(name: "Aryna Sabalenka", nationality: "BLR", isWTA: true)
        let tournament = Tournament(
            name: "Madrid Open",
            city: "Madrid",
            country: "Spain",
            surface: "Clay",
            tour: .wta,
            startDate: .now,
            endDate: .now
        )
        let match = TennisMatch(date: .now, tournament: tournament, player1: player, player2: Player(name: "Iga Swiatek", nationality: "POL", isWTA: true))
        let ranking = RankingEntry(player: player, rank: 1, points: 9500, tour: .wta)
        let profile = UserProfile(displayName: "Ana", avatarSymbol: "tennisball.fill")
        let bet = PointBet(match: match, player: player, selection: player.name, stake: 50, payout: 90)
        let post = SocialPost(match: match, authorName: "Ana", body: "Grande jogo.")
        let poll = MatchPoll(match: match, question: "Quem vence?", optionOne: player.name, optionTwo: "Iga Swiatek")

        context.insert(player)
        context.insert(tournament)
        context.insert(match)
        context.insert(ranking)
        context.insert(profile)
        context.insert(bet)
        context.insert(post)
        context.insert(poll)
        try context.save()

        #expect((try context.fetch(FetchDescriptor<Player>())).count == 2)
        #expect((try context.fetch(FetchDescriptor<Tournament>())).count == 1)
        #expect((try context.fetch(FetchDescriptor<TennisMatch>())).count == 1)
        #expect((try context.fetch(FetchDescriptor<RankingEntry>())).count == 1)
        #expect((try context.fetch(FetchDescriptor<UserProfile>())).count == 1)
        #expect((try context.fetch(FetchDescriptor<PointBet>())).count == 1)
        #expect((try context.fetch(FetchDescriptor<SocialPost>())).count == 1)
        #expect((try context.fetch(FetchDescriptor<MatchPoll>())).count == 1)
    }

    @MainActor
    @Test func localSocialLeaderboardUsesOnlyRealLocalProfile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let profile = UserProfile(displayName: "UI Fan", points: 1_100)
        let player = Player(externalKey: "social-p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let match = TennisMatch(date: .now, player1: player, player2: Player(name: "Jannik Sinner", nationality: "ITA", isWTA: false))
        let wonBet = PointBet(match: match, player: player, selection: player.name, stake: 25, payout: 45, status: .won)

        context.insert(profile)
        context.insert(player)
        context.insert(match)
        context.insert(wonBet)
        try context.save()

        let rows = SocialRankingBuilder.weeklyRows(profile: profile, bets: [wonBet], matches: [match])
        #expect(rows.count == 1)
        #expect(rows.first?.name == "UI Fan")
        #expect(rows.first?.isCurrentUser == true)
        #expect(rows.first?.points == 45)
    }

    @MainActor
    @Test func weeklySocialSummarySurfacesPercentileAndStreak() throws {
        let player = Player(externalKey: "summary-p1", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let match = TennisMatch(date: .now, player1: player, player2: Player(name: "Aryna Sabalenka", nationality: "BLR", isWTA: true))
        let first = PointBet(match: match, player: player, selection: player.name, stake: 50, payout: 90, status: .won)
        let second = PointBet(match: match, player: player, selection: player.name, stake: 25, payout: 45, status: .won)
        let stats = PredictionStats(bets: [first, second])
        let summary = WeeklySocialSummary(
            season: SocialSeason.current(),
            rank: 1,
            localLeaderboardCount: 1,
            stats: stats
        )

        #expect(summary.percentile == 82)
        #expect(summary.currentStreak == 2)
        #expect(summary.weeklyReadLine.contains("82%"))
        #expect(summary.streakLine.contains("2"))
    }

    @MainActor
    @Test func badgeCatalogUnlocksExpectedBadgesForBetHistory() throws {
        let profile = UserProfile(displayName: "Ana", points: 1_600)
        let player = Player(name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let opponent = Player(name: "Coco Gauff", nationality: "USA", isWTA: true)
        let match = TennisMatch(date: .now, player1: player, player2: opponent)
        var bets: [PointBet] = []
        for _ in 0..<3 {
            bets.append(PointBet(
                match: match,
                player: player,
                kind: .setWinner,
                selection: player.name,
                stake: 50,
                payout: 100,
                status: .won,
                targetSetIndex: 0
            ))
        }

        let stats = PredictionStats(bets: bets)
        let catalog = BadgeCatalog.badges(
            bets: bets,
            favoritePlayers: [player, opponent],
            matches: [match],
            profile: profile,
            stats: stats
        )

        let unlocked = Set(catalog.filter(\.isUnlocked).map(\.id))
        #expect(unlocked.contains("first-serve"))
        #expect(unlocked.contains("scout"))
        #expect(unlocked.contains("sharp-read"))
        #expect(unlocked.contains("hot-streak"))
        #expect(unlocked.contains("set-reader"))
        #expect(unlocked.contains("top-seed"))
        #expect(unlocked.contains("wta-specialist"))
        // Locked because we only have three consecutive wins, need seven.
        #expect(!unlocked.contains("legendary-streak"))
        let legendary = catalog.first { $0.id == "legendary-streak" }
        #expect(legendary?.progressLabel == "3/7")
    }

    @MainActor
    @Test func pickInteractionEncodingRoundTripsCommentsAndReactions() {
        let betID = UUID()
        let commentKey = PickInteractionEncoding.comment(betID: betID)
        let reactionKey = PickInteractionEncoding.reaction(betID: betID, kind: .fire)

        let commentDecoded = PickInteractionEncoding.decode(commentKey)
        let reactionDecoded = PickInteractionEncoding.decode(reactionKey)
        let legacyDecoded = PickInteractionEncoding.decode("pick:\(betID.uuidString):some-legacy-id")

        #expect(commentDecoded?.betID == betID)
        #expect(commentDecoded?.kind == .comment)
        #expect(reactionDecoded?.betID == betID)
        #expect(reactionDecoded?.kind == .reaction(.fire))
        #expect(legacyDecoded?.betID == betID)
        #expect(legacyDecoded?.kind == .comment)
        #expect(PickInteractionEncoding.decode(nil) == nil)
        #expect(PickInteractionEncoding.decode("unrelated:key:value") == nil)
    }

    @MainActor
    @Test func pickInteractionAnalyzerAggregatesReactionsAndCommentsPerBet() {
        let betID = UUID()
        let otherID = UUID()
        let match = TennisMatch(date: .now)
        let post1 = SocialPost(
            match: match,
            authorName: "Ana",
            body: "🔥",
            eventKey: PickInteractionEncoding.reaction(betID: betID, kind: .fire)
        )
        let post2 = SocialPost(
            match: match,
            authorName: "Bruno",
            body: "🎯",
            eventKey: PickInteractionEncoding.reaction(betID: betID, kind: .bullseye)
        )
        let commentPost = SocialPost(
            match: match,
            authorName: "Ana",
            body: "Vamos!",
            eventKey: PickInteractionEncoding.comment(betID: betID)
        )
        let otherBetPost = SocialPost(
            match: match,
            authorName: "Ana",
            body: "reaction on another pick",
            eventKey: PickInteractionEncoding.reaction(betID: otherID, kind: .fire)
        )
        let hiddenPost = SocialPost(
            match: match,
            authorName: "Ana",
            body: "hidden reaction",
            eventKey: PickInteractionEncoding.reaction(betID: betID, kind: .respect),
            isHidden: true
        )

        let summary = PickInteractionAnalyzer.summary(
            for: betID,
            localPosts: [post1, post2, commentPost, otherBetPost, hiddenPost],
            cloudPosts: [],
            viewer: "Ana"
        )
        let comments = PickInteractionAnalyzer.comments(
            for: betID,
            localPosts: [post1, post2, commentPost, otherBetPost, hiddenPost],
            cloudPosts: []
        )

        #expect(summary.count(for: .fire) == 1)
        #expect(summary.count(for: .bullseye) == 1)
        #expect(summary.count(for: .respect) == 0)
        #expect(summary.commentCount == 1)
        #expect(summary.viewerReactions == [.fire])
        #expect(comments.count == 1)
        #expect(comments.first?.authorName == "Ana")
        #expect(comments.first?.body == "Vamos!")
    }

    @MainActor
    @Test func pickHighlightBuilderProducesBestPickAndSurfaceStats() {
        let player = Player(name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let tournamentClay = Tournament(
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: .now,
            endDate: .now
        )
        let tournamentHard = Tournament(
            name: "US Open",
            city: "New York",
            country: "USA",
            surface: "Hard",
            tour: .atp,
            startDate: .now,
            endDate: .now
        )
        let matchClay = TennisMatch(date: .now, tournament: tournamentClay, player1: player, player2: Player(name: "Sinner", nationality: "ITA", isWTA: false))
        let matchHard = TennisMatch(date: .now, tournament: tournamentHard, player1: player, player2: Player(name: "Djokovic", nationality: "SRB", isWTA: false))

        let bigWin = PointBet(match: matchClay, player: player, selection: player.name, stake: 100, payout: 400, status: .won)
        let smallWin = PointBet(match: matchClay, player: player, selection: player.name, stake: 20, payout: 40, status: .won)
        let hardLoss = PointBet(match: matchHard, player: player, selection: player.name, stake: 50, payout: 90, status: .lost)

        let highlights = PickHighlightBuilder.highlights(
            bets: [bigWin, smallWin, hardLoss],
            matches: [matchClay, matchHard],
            favoritePlayers: [player]
        )
        let best = highlights.first { $0.id == "best-pick" }
        let surface = PickHighlightBuilder.surfaceWinRates(bets: [bigWin, smallWin, hardLoss])

        #expect(best?.value == "+400 pts")
        #expect(surface["Saibro"]?.wins == 2)
        #expect(surface["Saibro"]?.losses == 0)
        #expect(surface["Dura"]?.losses == 1)
    }

    @MainActor
    @Test func pickActivityHeatmapBucketsBetsByDay() {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let match = TennisMatch(date: now)
        let todayBet = PointBet(match: match, selection: "Winner", stake: 50, payout: 100, status: .won, createdAt: today)
        let olderCreated = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        let olderBet = PointBet(match: match, selection: "Winner", stake: 30, payout: 45, status: .lost, createdAt: olderCreated)

        let heatmap = PickActivityHeatmap.build(from: [todayBet, olderBet], days: 7, now: now, calendar: calendar)
        #expect(heatmap.cells.count == 7)
        let last = heatmap.cells.last
        #expect(last?.bets == 1)
        #expect(last?.wins == 1)
        #expect(heatmap.cells.contains { $0.losses == 1 })
    }

    @MainActor
    @Test func weeklyInsightsBuilderSurfacesBestPickAndTournamentInsight() {
        let player = Player(name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let tournament = Tournament(
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .wta,
            startDate: .now,
            endDate: .now
        )
        let match = TennisMatch(date: .now, tournament: tournament, player1: player, player2: Player(name: "Coco Gauff", nationality: "USA", isWTA: true))
        let bigWin = PointBet(match: match, player: player, selection: player.name, stake: 50, payout: 200, status: .won)
        let smallLoss = PointBet(match: match, player: player, selection: player.name, stake: 25, payout: 45, status: .lost)

        let stats = PredictionStats(bets: [bigWin, smallLoss])
        let summary = WeeklySocialSummary(
            season: SocialSeason.weekly(),
            rank: 1,
            localLeaderboardCount: 1,
            stats: stats
        )
        let insights = WeeklyInsightsBuilder.insights(
            summary: summary,
            bets: [bigWin, smallLoss],
            matches: [match],
            favoritePlayers: [player]
        )

        let ids = Set(insights.map(\.id))
        #expect(ids.contains("read"))
        #expect(ids.contains("streak"))
        #expect(ids.contains("best"))
        #expect(ids.contains("tournaments"))
        let best = insights.first { $0.id == "best" }
        #expect(best?.value == "+200 pts")
    }

    @MainActor
    @Test func socialSeasonAllReturnsWeeklyMonthlyAndSlamWindows() {
        let seasons = SocialSeason.all()
        let kinds = seasons.map(\.kind)
        #expect(kinds == [.weekly, .monthly, .slam])
        #expect(seasons[0].contains(.now))
        // Monthly always covers today (start-of-month ≤ now < start-of-next-month).
        #expect(seasons[1].contains(.now))
    }

    @MainActor
    @Test func demoModeSeedMaterializesFavoriteFriendlyDataset() {
        let payload = DemoModeSeed.materialize()

        #expect(payload.matches.count == 3)
        #expect(payload.matches.contains { $0.externalID == DemoSeedIdentifiers.liveMatchExternalID && $0.isLive })
        #expect(payload.matches.contains { $0.externalID == DemoSeedIdentifiers.upcomingMatchExternalID && $0.isUpcoming })
        #expect(payload.matches.contains { $0.externalID == DemoSeedIdentifiers.completedMatchExternalID && $0.isCompleted })

        let favorites = payload.players.filter(\.isFavorite)
        #expect(!favorites.isEmpty, "Demo mode must seed at least one favorite player so activation surfaces content immediately.")

        let live = payload.matches.first { $0.externalID == DemoSeedIdentifiers.liveMatchExternalID }
        #expect(live?.tournament != nil, "Live demo match needs a tournament so headers render.")

        #expect(!payload.rankings.isEmpty)
        #expect(payload.polls.count >= 1)
    }

    @MainActor
    @Test func demoModeServiceSeedsAndClearsWhenToggled() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "match-point.demo.tests.\(UUID().uuidString)")!
        let service = DemoModeService(defaults: defaults)

        service.enableDemoMode(in: context)
        try context.save()

        let liveKey = DemoSeedIdentifiers.liveMatchExternalID
        let afterSeed = try context.fetch(FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.externalID == liveKey }
        ))
        #expect(afterSeed.count == 1)
        #expect(service.isDemoActive)

        service.disableDemoMode(in: context)
        try context.save()

        let afterClear = try context.fetch(FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.externalID == liveKey }
        ))
        #expect(afterClear.isEmpty)
        #expect(!service.isDemoActive)
        #expect(service.isDemoDismissed)
    }

    @MainActor
    @Test func demoModeBootstrapSkipsWhenProductionDataAlreadyPresent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "match-point.demo.tests.\(UUID().uuidString)")!
        let service = DemoModeService(defaults: defaults)

        // Simulate a synced install: real data (no demo-* externalKey prefix).
        let realPlayer = Player(externalKey: "real-1", name: "Real Player", nationality: "BRA", isWTA: false)
        context.insert(realPlayer)
        try context.save()

        service.bootstrapIfNeeded(in: context, hasConfiguredProvider: true)

        let liveKey = DemoSeedIdentifiers.liveMatchExternalID
        let demoMatches = try context.fetch(FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.externalID == liveKey }
        ))
        #expect(demoMatches.isEmpty)
        #expect(!service.isDemoActive)
    }

    @MainActor
    @Test func demoModeBootstrapAutoSeedsWhenNoProviderAndEmptyStore() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "match-point.demo.tests.\(UUID().uuidString)")!
        let service = DemoModeService(defaults: defaults)

        service.bootstrapIfNeeded(in: context, hasConfiguredProvider: false)

        let liveKey = DemoSeedIdentifiers.liveMatchExternalID
        let demoMatches = try context.fetch(FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.externalID == liveKey }
        ))
        #expect(demoMatches.count == 1)
        #expect(service.isDemoActive)
    }

    @MainActor
    @Test func demoModeBootstrapRespectsDismissalFromUser() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "match-point.demo.tests.\(UUID().uuidString)")!
        let service = DemoModeService(defaults: defaults)

        service.enableDemoMode(in: context)
        try context.save()
        service.disableDemoMode(in: context)
        try context.save()

        service.bootstrapIfNeeded(in: context, hasConfiguredProvider: false)

        let liveKey = DemoSeedIdentifiers.liveMatchExternalID
        let demoMatches = try context.fetch(FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.externalID == liveKey }
        ))
        #expect(demoMatches.isEmpty, "User dismissal must survive across bootstrap invocations.")
    }

    @MainActor
    @Test func leaderboardHistoryStoreRoundTripsRankSnapshots() {
        LeaderboardHistoryStore.clearAll()
        defer { LeaderboardHistoryStore.clearAll() }

        LeaderboardHistoryStore.recordCurrent(seasonKind: .weekly, source: "test", rank: 12)
        #expect(LeaderboardHistoryStore.previousRank(seasonKind: .weekly, source: "test") == 12)
        // Second record within the throttling window does NOT overwrite.
        LeaderboardHistoryStore.recordCurrent(seasonKind: .weekly, source: "test", rank: 5)
        #expect(LeaderboardHistoryStore.previousRank(seasonKind: .weekly, source: "test") == 12)
    }

    @MainActor
    @Test func tournamentAndMatchUpsertsUpdateExistingRecords() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let originalTournament = TournamentDTO(
            id: "t-1",
            name: "Rome Masters",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: "ATP",
            startDate: date("2026-05-10"),
            endDate: date("2026-05-17")
        )
        let updatedTournament = TournamentDTO(
            id: "t-1",
            name: "Internazionali BNL d'Italia",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: "ATP",
            startDate: date("2026-05-11"),
            endDate: date("2026-05-18")
        )

        let player1 = Player.upsert(
            from: PlayerDTO(id: "p1", name: "Jannik Sinner", nationality: "ITA", tour: "ATP", birthDate: nil),
            in: context
        )
        let player2 = Player.upsert(
            from: PlayerDTO(id: "p2", name: "Carlos Alcaraz", nationality: "ESP", tour: "ATP", birthDate: nil),
            in: context
        )

        let tournament = Tournament.upsert(from: originalTournament, in: context)
        _ = Tournament.upsert(from: updatedTournament, in: context)

        let playersById = ["p1": player1, "p2": player2]
        let tournamentsById = ["t-1": tournament]

        let originalMatch = MatchDTO(
            id: "m-1",
            date: dateTime("2026-05-17 12:00"),
            tournamentId: "t-1",
            player1Id: "p1",
            player2Id: "p2",
            player1Name: "Jannik Sinner",
            player2Name: "Carlos Alcaraz",
            player1Country: "ITA",
            player2Country: "ESP",
            score: "6-4 3-6 6-3",
            status: "Final",
            isLive: false
        )
        let updatedMatch = MatchDTO(
            id: "m-1",
            date: dateTime("2026-05-17 12:30"),
            tournamentId: "t-1",
            player1Id: "p1",
            player2Id: "p2",
            player1Name: "Jannik Sinner",
            player2Name: "Carlos Alcaraz",
            player1Country: "ITA",
            player2Country: "ESP",
            score: "7-6 6-4",
            status: "Final",
            isLive: false
        )

        let storedMatch = TennisMatch.upsert(from: originalMatch, playersById: playersById, tournamentsById: tournamentsById, in: context)
        let updatedStoredMatch = TennisMatch.upsert(from: updatedMatch, playersById: playersById, tournamentsById: tournamentsById, in: context)

        #expect(tournament.name == "Internazionali BNL d'Italia")
        #expect(tournament.startDate == date("2026-05-11"))
        #expect(storedMatch.id == updatedStoredMatch.id)
        #expect(updatedStoredMatch.score == "7-6 6-4")
        #expect(updatedStoredMatch.date == dateTime("2026-05-17 12:30"))
        #expect((try context.fetch(FetchDescriptor<TennisMatch>())).count == 1)
    }

    @MainActor
    @Test func matchIntelligenceAndFeedPreferRelevantFavoriteLiveMatches() throws {
        let tournament = Tournament(
            externalKey: "tour-1",
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: date("2026-06-01"),
            endDate: date("2026-06-14"),
            isFavorite: true
        )
        let player1 = Player(externalKey: "p1", name: "Novak Djokovic", nationality: "SRB", isWTA: false, isFavorite: true)
        let player2 = Player(externalKey: "p2", name: "Rafael Nadal", nationality: "ESP", isWTA: false)
        let liveMatch = TennisMatch(
            externalID: "live-1",
            date: .now.addingTimeInterval(-600),
            status: "Second Set",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: "Rafael Nadal",
            pointScore: "40-30",
            gameScore: "4-5",
            isFavorite: true,
            tournament: tournament,
            player1: player1,
            player2: player2,
            score: "6-4"
        )
        let upcomingMatch = TennisMatch(
            externalID: "upcoming-1",
            date: .now.addingTimeInterval(3600),
            status: "Scheduled",
            isLive: false,
            tournament: tournament,
            player1: player1,
            player2: player2
        )
        let rankings = [
            RankingEntry(externalKey: "ATP-p1", player: player1, rank: 3, points: 8100, tour: .atp),
            RankingEntry(externalKey: "ATP-p2", player: player2, rank: 8, points: 6200, tour: .atp)
        ]
        let matches = [liveMatch, upcomingMatch]

        let intelligence = MatchIntelligence(match: liveMatch, rankings: rankings, allMatches: matches)
        let sections = ForYouFeedBuilder.sections(matches: matches, rankings: rankings, preferences: ExperiencePreferences())

        #expect(intelligence.relevanceScore >= 90)
        #expect(intelligence.breakPointLabel == "Break point Novak Djokovic")
        #expect(intelligence.recommendation == "Abrir agora")
        #expect(sections.first?.id == "live")
        #expect(sections.first?.matches.first?.id == liveMatch.id)
    }

    @MainActor
    @Test func behaviorPersonalizationPromotesViewedPlayersAndTournaments() {
        let familiarTournament = Tournament(
            externalKey: "rome",
            name: "Rome Masters",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400 * 7)
        )
        let neutralTournament = Tournament(
            externalKey: "halle",
            name: "Halle Open",
            city: "Halle",
            country: "Germany",
            surface: "Grass",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400 * 7)
        )
        let followed = Player(externalKey: "sinner", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let opponent = Player(externalKey: "rune", name: "Holger Rune", nationality: "DEN", isWTA: false)
        let neutral1 = Player(externalKey: "fritz", name: "Taylor Fritz", nationality: "USA", isWTA: false)
        let neutral2 = Player(externalKey: "paul", name: "Tommy Paul", nationality: "USA", isWTA: false)
        let personalizedMatch = TennisMatch(
            externalID: "rome-sinner",
            date: .now.addingTimeInterval(7_200),
            status: "Scheduled",
            tournament: familiarTournament,
            player1: followed,
            player2: opponent
        )
        let neutralMatch = TennisMatch(
            externalID: "halle-fritz",
            date: .now.addingTimeInterval(3_600),
            status: "Scheduled",
            tournament: neutralTournament,
            player1: neutral1,
            player2: neutral2
        )
        let snapshot = BehaviorPersonalizationSnapshot(
            playerViews: ["sinner": BehaviorAffinity(count: 4, lastSeenAt: .now)],
            tournamentViews: ["rome": BehaviorAffinity(count: 3, lastSeenAt: .now)],
            matchViews: [:],
            activeHours: [Calendar.current.component(.hour, from: .now): 3],
            ignoredAlertEvents: [:],
            favoriteSignalCount: 0,
            lastUpdatedAt: .now
        )

        let scores = MatchIntelligence.relevanceScores(
            for: [neutralMatch, personalizedMatch],
            rankings: [],
            behavior: snapshot
        )
        let sections = ForYouFeedBuilder.sections(
            matches: [neutralMatch, personalizedMatch],
            rankings: [],
            preferences: ExperiencePreferences(),
            behavior: snapshot
        )
        let reasons = BehaviorPersonalizationScorer.relevanceReasons(for: personalizedMatch, snapshot: snapshot)

        #expect((scores[personalizedMatch.id] ?? 0) > (scores[neutralMatch.id] ?? 0))
        #expect(sections.first?.matches.first?.id == personalizedMatch.id)
        #expect(reasons.contains { $0.label == "Você acompanha Jannik Sinner" })
        #expect(reasons.contains { $0.label == "Torneio recorrente para você" })
    }

    @MainActor
    @Test func matchBrainDigestComparesLiveMatchesAndUsesStyleAndTimePreferences() {
        let tournament = Tournament(
            externalKey: "brain-rome",
            name: "Rome Masters",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400 * 7)
        )
        let favorite = Player(externalKey: "brain-alcaraz", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        favorite.isFavorite = true
        let pressureOpponent = Player(externalKey: "brain-sinner", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let otherPlayer = Player(externalKey: "brain-fritz", name: "Taylor Fritz", nationality: "USA", isWTA: false)
        let otherOpponent = Player(externalKey: "brain-paul", name: "Tommy Paul", nationality: "USA", isWTA: false)
        let pressureMatch = TennisMatch(
            externalID: "brain-live-pressure",
            date: .now,
            status: "Second Set",
            isLive: true,
            serverName: favorite.name,
            pointScore: "30-40",
            gameScore: "4-4",
            tournament: tournament,
            player1: favorite,
            player2: pressureOpponent,
            score: "6-4"
        )
        let quietMatch = TennisMatch(
            externalID: "brain-live-quiet",
            date: .now.addingTimeInterval(120),
            status: "First Set",
            isLive: true,
            serverName: otherPlayer.name,
            pointScore: "15-15",
            gameScore: "1-1",
            tournament: tournament,
            player1: otherPlayer,
            player2: otherOpponent,
            score: ""
        )
        let rankings = [
            RankingEntry(externalKey: "brain-r1", player: favorite, rank: 2, points: 8_800, tour: .atp),
            RankingEntry(externalKey: "brain-r2", player: pressureOpponent, rank: 3, points: 8_400, tour: .atp)
        ]
        let preferences = ExperiencePreferences(
            matchBrainStyle: .pressureMoments,
            matchBrainViewingWindow: .useHabit
        )
        let snapshot = BehaviorPersonalizationSnapshot(
            activeHours: [Calendar.current.component(.hour, from: pressureMatch.date): 4],
            recommendationOpenCount: 5,
            usefulRecommendationOpenCount: 4,
            lastRecommendationSummary: "Carlos Alcaraz vs Jannik Sinner: Break point ativo"
        )

        let digest = MatchBrainDigest(
            matches: [quietMatch, pressureMatch],
            rankings: rankings,
            preferences: preferences,
            behavior: snapshot
        )

        #expect(digest.featuredMatch?.id == pressureMatch.id)
        #expect(digest.liveComparisons.count == 2)
        #expect(digest.liveComparisons.first?.match.id == pressureMatch.id)
        #expect(digest.whyNowAlerts.contains { $0.contains("Break point") })
        #expect(digest.history.title == "80% de sinais úteis")
    }

    @MainActor
    @Test func recommendationHistoryRecordsUsefulRecommendationOpens() {
        let defaults = UserDefaults(suiteName: "match-point-tests-\(UUID().uuidString)")!
        let store = BehaviorPersonalizationStore(defaults: defaults, storageKey: "behavior")
        let player = Player(externalKey: "history-iga", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        player.isFavorite = true
        let opponent = Player(externalKey: "history-coco", name: "Coco Gauff", nationality: "USA", isWTA: true)
        let match = TennisMatch(
            externalID: "history-match",
            date: .now,
            status: "Live",
            isLive: true,
            pointScore: "40-30",
            player1: player,
            player2: opponent
        )
        let reasons = [
            MatchRelevanceReason(symbol: "person.crop.circle.badge.checkmark", label: "Jogador favorito: Iga Swiatek", points: 35)
        ]

        store.recordRecommendationOpen(match, relevanceScore: 70, reasons: reasons)

        #expect(store.snapshot.recommendationOpenCount == 1)
        #expect(store.snapshot.usefulRecommendationOpenCount == 1)
        #expect(store.snapshot.recommendationAccuracyRate == 1.0)
        #expect(store.snapshot.lastRecommendationSummary?.contains("Iga Swiatek") == true)
    }

    @MainActor
    @Test func playerProfileInsightsComputeFormHeadToHeadAndTitles() {
        let tournament1 = Tournament(externalKey: "tour-1", name: "Australian Open", city: "Melbourne", country: "Australia", surface: "Hard", tour: .atp, startDate: date("2026-01-10"), endDate: date("2026-01-24"))
        let tournament2 = Tournament(externalKey: "tour-2", name: "Indian Wells", city: "Indian Wells", country: "USA", surface: "Hard", tour: .atp, startDate: date("2026-03-01"), endDate: date("2026-03-14"))
        let player = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let opponent = Player(externalKey: "p2", name: "Daniil Medvedev", nationality: "RUS", isWTA: false)

        let finishedWin = TennisMatch(
            externalID: "m1",
            date: .now.addingTimeInterval(-86_400 * 5),
            status: "Final",
            isLive: false,
            tournament: tournament1,
            player1: player,
            player2: opponent,
            score: "6-4 6-4"
        )
        let finishedLoss = TennisMatch(
            externalID: "m2",
            date: .now.addingTimeInterval(-86_400 * 3),
            status: "Final",
            isLive: false,
            tournament: tournament2,
            player1: opponent,
            player2: player,
            score: "6-3 6-4"
        )
        let upcoming = TennisMatch(
            externalID: "m3",
            date: .now.addingTimeInterval(86_400),
            status: "Scheduled",
            isLive: false,
            tournament: tournament2,
            player1: player,
            player2: opponent
        )
        let ranking = RankingEntry(externalKey: "ATP-p1", player: player, rank: 2, points: 8900, tour: .atp)

        let insights = PlayerProfileInsights(player: player, matches: [finishedWin, finishedLoss, upcoming], rankings: [ranking])

        #expect(insights.rank == 2)
        #expect(insights.wins == 1)
        #expect(insights.losses == 1)
        #expect(insights.titles == 1)
        #expect(insights.recentForm == [false, true])
        #expect(insights.upcomingMatches.count == 1)
        #expect(insights.headToHead.first?.wins == 1)
        #expect(insights.headToHead.first?.losses == 1)
    }

    @MainActor
    @Test func tournamentCalendarInsightsGroupRoundsAndAgenda() {
        let tournament = Tournament(
            externalKey: "tour-1",
            name: "US Open",
            city: "New York",
            country: "USA",
            surface: "Hard",
            tour: .atp,
            startDate: .now.addingTimeInterval(-86_400),
            endDate: .now.addingTimeInterval(86_400 * 7)
        )
        let players = (1...4).map { Player(externalKey: "p\($0)", name: "Player \($0)", nationality: "USA", isWTA: false) }
        let matches = [
            TennisMatch(externalID: "qf1", date: .now.addingTimeInterval(60), status: "Scheduled", tournament: tournament, player1: players[0], player2: players[1]),
            TennisMatch(externalID: "sf1", date: .now.addingTimeInterval(86_400), status: "Scheduled", tournament: tournament, player1: players[0], player2: players[2]),
            TennisMatch(externalID: "f1", date: .now.addingTimeInterval(172_800), status: "Scheduled", tournament: tournament, player1: players[0], player2: players[3])
        ]

        let insights = TournamentCalendarInsights(tournament: tournament, matches: matches)

        #expect(insights.todayMatches.count == 1)
        #expect(insights.upcomingMatches.count == 3)
        #expect(insights.bracketSections.map(\.0).contains("Final"))
        #expect(insights.bracketSections.map(\.0).contains("Semi-final"))
    }

    @MainActor
    @Test func liveTrackerKeepsFinishedFavoriteMatchForTwoMinutes() {
        let player = Player(externalKey: "p1", name: "Iga Swiatek", nationality: "POL", isWTA: true, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Coco Gauff", nationality: "USA", isWTA: true)
        let justFinished = TennisMatch(
            externalID: "m1",
            date: .now.addingTimeInterval(-7_200),
            status: "Final",
            isLive: false,
            lastUpdatedAt: .now.addingTimeInterval(-90),
            player1: player,
            player2: opponent,
            score: "6-4 6-4"
        )
        let staleFinished = TennisMatch(
            externalID: "m2",
            date: .now.addingTimeInterval(-7_200),
            status: "Final",
            isLive: false,
            lastUpdatedAt: .now.addingTimeInterval(-180),
            player1: player,
            player2: opponent,
            score: "6-3 6-3"
        )

        let trackers = LiveTrackerBuilder.activeTrackers(
            matches: [justFinished, staleFinished],
            favoritePlayerIDs: [player.id],
            rankings: [],
            now: .now
        )

        #expect(trackers.map(\.externalID).contains("m1"))
        #expect(trackers.map(\.externalID).contains("m2") == false)
    }

    @MainActor
    @Test func betSettlementHandlesSetScoreAndPerformanceBets() {
        let player = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let opponent = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "final-1",
            date: .now.addingTimeInterval(-3_600),
            status: "Final",
            isLive: false,
            player1: player,
            player2: opponent,
            score: "4-6 6-3 6-4"
        )

        let setBet = PointBet(
            match: match,
            player: player,
            kind: .setWinner,
            selection: player.name,
            stake: 50,
            payout: 110,
            targetSetIndex: 1
        )
        let scoreBet = PointBet(
            match: match,
            player: player,
            kind: .finalScore,
            selection: player.name,
            stake: 50,
            payout: 170,
            predictedScore: "4-6 6-3 6-4"
        )
        let performanceBet = PointBet(
            match: match,
            player: player,
            kind: .playerPerformance,
            selection: player.name,
            stake: 50,
            payout: 130,
            performanceRule: .comebackWin
        )
        let missedPerformanceBet = PointBet(
            match: match,
            player: player,
            kind: .playerPerformance,
            selection: player.name,
            stake: 50,
            payout: 130,
            performanceRule: .straightSets
        )

        #expect(BetSettlementEngine.status(for: setBet) == .won)
        #expect(BetSettlementEngine.status(for: scoreBet) == .won)
        #expect(BetSettlementEngine.status(for: performanceBet) == .won)
        #expect(BetSettlementEngine.status(for: missedPerformanceBet) == .lost)
    }

    @MainActor
    @Test func socialEventGeneratorCreatesIdempotentMatchUpdates() {
        let player = Player(externalKey: "p1", name: "Novak Djokovic", nationality: "SRB", isWTA: false)
        let opponent = Player(externalKey: "p2", name: "Rafael Nadal", nationality: "ESP", isWTA: false)
        let match = TennisMatch(
            externalID: "live-social-1",
            date: .now.addingTimeInterval(-1_200),
            status: "Second Set",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: "Rafael Nadal",
            pointScore: "40-30",
            gameScore: "4-5",
            player1: player,
            player2: opponent,
            score: "6-4"
        )

        let events = SocialEventGenerator.events(for: [match], existingEventKeys: [])
        let existingKeys = Set(events.map(\.id))
        let repeatedEvents = SocialEventGenerator.events(for: [match], existingEventKeys: existingKeys)

        #expect(events.contains { $0.body.contains("Break point") })
        #expect(events.contains { $0.body.contains("Set 1") })
        #expect(repeatedEvents.isEmpty)
    }

    @MainActor
    @Test func socialEventGeneratorCreatesRankingAndH2HStorytelling() {
        let sinner = Player(externalKey: "p1", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let alcaraz = Player(externalKey: "p2", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let grassEvent = Tournament(
            externalKey: "grass-1",
            name: "Wimbledon",
            city: "London",
            country: "United Kingdom",
            surface: "Grass",
            tour: .atp,
            startDate: .now.addingTimeInterval(-86_400),
            endDate: .now.addingTimeInterval(86_400)
        )
        let liveMatch = TennisMatch(
            externalID: "story-live",
            date: .now.addingTimeInterval(-900),
            status: "Set 2",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: alcaraz.name,
            pointScore: "30-15",
            gameScore: "3-4",
            tournament: grassEvent,
            player1: sinner,
            player2: alcaraz,
            score: "4-6"
        )
        let previous = TennisMatch(
            externalID: "story-h2h",
            date: .now.addingTimeInterval(-30 * 86_400),
            status: "Final",
            tournament: grassEvent,
            player1: sinner,
            player2: alcaraz,
            score: "7-6 6-4"
        )
        let rankings = [
            RankingEntry(externalKey: "r1", player: sinner, rank: 1, points: 9_800, tour: .atp),
            RankingEntry(externalKey: "r2", player: alcaraz, rank: 2, points: 9_200, tour: .atp)
        ]

        let events = SocialEventGenerator.events(
            for: [liveMatch],
            existingEventKeys: [],
            rankings: rankings,
            allMatches: [liveMatch, previous]
        )

        #expect(events.contains { $0.id.contains(":story:ranking") && $0.body.contains("manter o #1") })
        #expect(events.contains { $0.id.contains(":story:set-pressure") && $0.body.contains("precisa vencer este set") })
        #expect(events.contains { $0.id.contains(":story:h2h-surface") && $0.body.contains("nunca perdeu") && $0.body.contains("grama") })
    }

    @MainActor
    @Test func premiumLiveContextFlagsBreakPointPressure() {
        let player = Player(externalKey: "p1", name: "Beatriz Haddad Maia", nationality: "BRA", isWTA: true, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let match = TennisMatch(
            externalID: "pressure-1",
            date: .now.addingTimeInterval(-900),
            status: "Final Set",
            isLive: true,
            serverName: "Iga Swiatek",
            pointScore: "40-30",
            gameScore: "4-5",
            player1: player,
            player2: opponent,
            score: "6-4 3-6"
        )

        let context = MatchIntelligence(match: match, rankings: [], allMatches: [match]).liveContext

        #expect(context.pressureScore >= 0.55)
        #expect(context.headline.contains("Break point"))
        #expect(context.chips.contains("Favorito"))
    }

    @MainActor
    @Test func favoritePlayerFeedBuildsPersonalizedSections() {
        let favorite = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let live = TennisMatch(
            externalID: "fav-live",
            date: .now.addingTimeInterval(-600),
            status: "Live",
            isLive: true,
            player1: favorite,
            player2: opponent
        )
        let upcoming = TennisMatch(
            externalID: "fav-next",
            date: .now.addingTimeInterval(3_600),
            status: "Scheduled",
            player1: opponent,
            player2: favorite
        )

        let feed = FavoritePlayerFeed(players: [favorite, opponent], matches: [upcoming, live], rankings: [])

        #expect(feed.favoritePlayers.map(\.id) == [favorite.id])
        #expect(feed.liveMatches.map(\.id) == [live.id])
        #expect(feed.upcomingMatches.map(\.id) == [upcoming.id])
        #expect(feed.spotlight.count == 2)
    }

    @MainActor
    @Test func matchBrainExplainsBreakPointAndGlossary() {
        let favorite = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "brain-1",
            date: .now.addingTimeInterval(-300),
            status: "Live",
            isLive: true,
            serverName: "Jannik Sinner",
            pointScore: "40-30",
            gameScore: "4-5",
            player1: favorite,
            player2: opponent,
            score: "6-4"
        )

        let narrative = MatchBrainNarrative(match: match, rankings: [], allMatches: [match])

        #expect(narrative.headline.contains("Break point"))
        #expect(narrative.whyItMatters.contains("favorito"))
        #expect(narrative.glossaryInsights.contains { $0.term == "Break point" })
    }

    @MainActor
    @Test func favoriteRadarAndTournamentModeSurfacePriorityGames() {
        let favorite = Player(externalKey: "p1", name: "Beatriz Haddad Maia", nationality: "BRA", isWTA: true, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let tournament = Tournament(
            externalKey: "t1",
            name: "Rome",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: .wta,
            startDate: .now.addingTimeInterval(-86_400),
            endDate: .now.addingTimeInterval(86_400)
        )
        let live = TennisMatch(
            externalID: "radar-live",
            date: .now.addingTimeInterval(-600),
            status: "Live",
            isLive: true,
            tournament: tournament,
            player1: favorite,
            player2: opponent
        )
        let next = TennisMatch(
            externalID: "radar-next",
            date: .now.addingTimeInterval(7_200),
            status: "Scheduled",
            tournament: tournament,
            player1: opponent,
            player2: favorite
        )
        let ranking = RankingEntry(externalKey: "r1", player: favorite, rank: 12, points: 3_400, tour: .wta)

        let radar = FavoritePlayerRadar(player: favorite, matches: [live, next], rankings: [ranking])
        let mode = TournamentModeDigest(tournament: tournament, matches: [live, next], rankings: [ranking])

        #expect(radar.alertLine.contains("Em quadra"))
        #expect(radar.rankingLine.contains("#12"))
        #expect(mode.favoritesAlive.map(\.id) == [favorite.id])
        #expect(mode.onlyThree.count == 2)
        #expect(mode.formatHighlights.contains { $0.contains("Superfície") })
        #expect(mode.localStorylines.isEmpty == false)
        #expect(mode.favoritePaths.contains { $0.contains(favorite.name) })
    }

    @MainActor
    @Test func expandedPredictionSettlementHandlesTieBreakSetsAndNextGame() {
        let server = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let receiver = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let completed = TennisMatch(
            externalID: "expanded-final",
            date: .now.addingTimeInterval(-7_200),
            status: "Final",
            isLive: false,
            player1: server,
            player2: receiver,
            score: "7-6 4-6 6-3"
        )
        let nextGame = TennisMatch(
            externalID: "expanded-live",
            date: .now.addingTimeInterval(-600),
            status: "Live",
            isLive: true,
            serverName: server.name,
            pointScore: "15-0",
            gameScore: "3-2",
            player1: server,
            player2: receiver
        )
        let holdBet = PointBet(
            match: nextGame,
            player: server,
            kind: .holdServe,
            selection: server.name,
            stake: 50,
            payout: 75,
            predictedScore: BetSettlementEngine.defaultPredictionValue(for: .holdServe, match: nextGame, player: server)
        )
        nextGame.gameScore = "4-2"

        let tieBreakBet = PointBet(match: completed, kind: .tieBreakPlayed, selection: "Sim", stake: 50, payout: 105, predictedScore: "Sim")
        let totalSetsBet = PointBet(match: completed, kind: .totalSets, selection: "3 sets", stake: 50, payout: 125, predictedScore: "3")

        #expect(BetSettlementEngine.status(for: tieBreakBet) == .won)
        #expect(BetSettlementEngine.status(for: totalSetsBet) == .won)
        #expect(BetSettlementEngine.status(for: holdBet) == .won)
    }

    @MainActor
    @Test func advancedMatchBrainUsesTimelineAndRankingProjection() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false, isFavorite: true)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let tournament = Tournament(
            externalKey: "gs",
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: .now.addingTimeInterval(-86_400),
            endDate: .now.addingTimeInterval(86_400 * 12)
        )
        let match = TennisMatch(
            externalID: "brain-advanced",
            date: .now.addingTimeInterval(-600),
            status: "Live",
            isLive: true,
            serverName: alcaraz.name,
            pointScore: "30-15",
            gameScore: "4-4",
            tournament: tournament,
            player1: alcaraz,
            player2: sinner,
            score: "6-4"
        )
        match.liveTimelinePayload = try timelinePayload([
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-80), title: "Jannik Sinner winner", detail: "Ponto Jannik Sinner"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-70), title: "Jannik Sinner pressiona", detail: "Ponto Jannik Sinner"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-60), title: "Carlos Alcaraz saque", detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-50), title: "Carlos Alcaraz saque", detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-40), title: "Carlos Alcaraz saque", detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-30), title: "Carlos Alcaraz saque", detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz")
        ])
        let rankings = [
            RankingEntry(externalKey: "r1", player: alcaraz, rank: 3, points: 7_000, tour: .atp),
            RankingEntry(externalKey: "r2", player: sinner, rank: 2, points: 7_200, tour: .atp)
        ]

        let narrative = MatchBrainNarrative(match: match, rankings: rankings, allMatches: [match])

        #expect(narrative.advancedSignals.contains { $0.contains("Carlos Alcaraz") })
        #expect(narrative.liveRankingProjection?.contains("Projeção por tabela ATP/WTA") == true)
        #expect(narrative.liveRankingProjection?.contains("+2000") == true)
    }

    @MainActor
    @Test func matchBrainUsesStructuredPointTimelineForServeRuns() throws {
        let server = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let receiver = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "live-run",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: server.name,
            pointScore: "40-15",
            gameScore: "4-3",
            player1: server,
            player2: receiver
        )
        let events = (0..<10).map { index in
            MatchTimelineEvent(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                title: "Ponto \(index)",
                detail: "Ponto registrado",
                pointWinnerName: index < 8 ? server.name : receiver.name,
                serverName: server.name,
                pointScore: "40-15",
                gameScore: "4-3"
            )
        }
        match.liveTimelinePayload = try timelinePayload(events)

        let analyzer = MatchPointRunAnalyzer(match: match)

        #expect(analyzer.serviceRunText == "Carlos Alcaraz ganhou 8 dos últimos 10 pontos confirmados no saque.")
    }

    @MainActor
    @Test func matchBrainDoesNotPromoteHeuristicServeRunsAsConfirmedPoints() throws {
        let server = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let receiver = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "live-run-heuristic",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: server.name,
            pointScore: "40-15",
            gameScore: "4-3",
            player1: server,
            player2: receiver
        )
        match.liveTimelinePayload = try timelinePayload((0..<6).map { index in
            MatchTimelineEvent(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                title: "Carlos Alcaraz saque",
                detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz",
                serverName: server.name,
                pointScore: "40-15",
                gameScore: "4-3"
            )
        })

        let analyzer = MatchPointRunAnalyzer(match: match)
        let momentum = analyzer.momentumTimeline(limit: 6)

        #expect(analyzer.serviceRunText == nil)
        #expect(momentum.allSatisfy { $0.isEstimated } == true)
    }

    @MainActor
    @Test func matchStatsBreakdownAggregatesServicePointsAndAces() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "stats-match",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: alcaraz.name,
            player1: alcaraz,
            player2: sinner
        )
        // Alcaraz serving: 3 aces, 1 winner, Sinner takes 1 return point
        // Sinner serving: 2 winners, Alcaraz takes 1 return point
        match.liveTimelinePayload = try timelinePayload([
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 1), title: "Ace", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 2), title: "Ace", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 3), title: "Ace", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 4), title: "Winner", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 5), title: "Rally", detail: "", pointWinnerName: sinner.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 6), title: "Winner", detail: "", pointWinnerName: sinner.name, serverName: sinner.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 7), title: "Winner", detail: "", pointWinnerName: sinner.name, serverName: sinner.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 8), title: "Rally", detail: "", pointWinnerName: alcaraz.name, serverName: sinner.name)
        ])

        let breakdown = MatchStatsBreakdown.compute(from: match)

        #expect(breakdown.player1.totalPoints == 5)
        #expect(breakdown.player2.totalPoints == 3)
        #expect(breakdown.player1.aces == 3)
        #expect(breakdown.player2.aces == 0)
        #expect(breakdown.player1.winners == 1)
        #expect(breakdown.player2.winners == 2)
        #expect(breakdown.player1.pointsOnServe == 4)
        #expect(breakdown.player1.pointsOnReturn == 1)
        #expect(breakdown.player2.pointsOnServe == 2)
        #expect(breakdown.player2.pointsOnReturn == 1)
        #expect(breakdown.isMeaningful == true)
    }

    @MainActor
    @Test func matchStatsBreakdownDetectsBreakPointConversions() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "bp-match",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: sinner.name,
            player1: alcaraz,
            player2: sinner
        )
        // Sinner serving, faces two break points: saves the first (wins the
        // point), loses the second (Alcaraz converts).
        match.liveTimelinePayload = try timelinePayload([
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 10), title: "Break point", detail: "", pointWinnerName: nil, serverName: sinner.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 11), title: "Ponto", detail: "", pointWinnerName: sinner.name, serverName: sinner.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 12), title: "Break point", detail: "", pointWinnerName: nil, serverName: sinner.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 13), title: "Ponto", detail: "", pointWinnerName: alcaraz.name, serverName: sinner.name),
            // Filler pra passar do sampleSize mínimo
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 14), title: "Ponto", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 15), title: "Ponto", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 16), title: "Ponto", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name),
            MatchTimelineEvent(timestamp: Date(timeIntervalSince1970: 17), title: "Ponto", detail: "", pointWinnerName: alcaraz.name, serverName: alcaraz.name)
        ])

        let breakdown = MatchStatsBreakdown.compute(from: match)

        #expect(breakdown.player1.breakPointOpportunities == 2)
        #expect(breakdown.player1.breakPointsConverted == 1)
        #expect(breakdown.player2.breakPointsFaced == 2)
        #expect(breakdown.player2.breakPointsSaved == 1)
    }

    @MainActor
    @Test func headToHeadDigestAggregatesWinsSurfacesAndStreak() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)

        let clay = Tournament(externalKey: "t-clay", name: "Roland Garros", city: "Paris", country: "FRA", surface: "Clay", tour: .atp, startDate: date("2025-05-25"), endDate: date("2025-06-08"))
        let grass = Tournament(externalKey: "t-grass", name: "Wimbledon", city: "London", country: "GBR", surface: "Grass", tour: .atp, startDate: date("2025-06-30"), endDate: date("2025-07-13"))
        let hard = Tournament(externalKey: "t-hard", name: "US Open", city: "New York", country: "USA", surface: "Hard", tour: .atp, startDate: date("2025-08-25"), endDate: date("2025-09-07"))

        // Ordem cronológica: Sinner (clay) → Alcaraz (grass) → Alcaraz (hard) →
        // partida atual (upcoming). Streak esperada: Alcaraz venceu os últimos 2.
        let past1 = TennisMatch(externalID: "past-1", date: date("2025-06-05"), status: "Final", tournament: clay, player1: alcaraz, player2: sinner, score: "3-6 4-6")
        let past2 = TennisMatch(externalID: "past-2", date: date("2025-07-12"), status: "Final", tournament: grass, player1: alcaraz, player2: sinner, score: "6-4 7-6")
        let past3 = TennisMatch(externalID: "past-3", date: date("2025-09-06"), status: "Final", tournament: hard, player1: alcaraz, player2: sinner, score: "6-2 6-4")
        let current = TennisMatch(externalID: "current", date: date("2026-01-15"), status: "Scheduled", tournament: hard, player1: alcaraz, player2: sinner)

        let digest = HeadToHeadDigest.compute(currentMatch: current, allMatches: [past1, past2, past3, current])

        #expect(digest.totalMeetings == 3)
        #expect(digest.winsByPlayer1 == 2)
        #expect(digest.winsByPlayer2 == 1)
        #expect(digest.currentStreak?.winnerName == "Carlos Alcaraz")
        #expect(digest.currentStreak?.count == 2)
        // Ordem: mais recente primeiro → Alcaraz (hard), Alcaraz (grass), Sinner (clay).
        #expect(digest.recentPlayer1Outcomes == [true, true, false])
        // Splits: cada superfície aparece uma vez porque houve um encontro em cada.
        let claySplit = digest.surfaceSplits.first { $0.surface == "Clay" }
        let grassSplit = digest.surfaceSplits.first { $0.surface == "Grass" }
        let hardSplit = digest.surfaceSplits.first { $0.surface == "Hard" }
        #expect(claySplit?.player2Wins == 1)
        #expect(grassSplit?.player1Wins == 1)
        #expect(hardSplit?.player1Wins == 1)
        #expect(digest.lastEncounterID == past3.id)
    }

    @MainActor
    @Test func winProbabilityReturnsNilForNonLiveMatch() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "not-live",
            date: .now,
            status: "Scheduled",
            isLive: false,
            player1: alcaraz,
            player2: sinner
        )
        #expect(WinProbabilityEstimate.compute(from: match) == nil)
    }

    @MainActor
    @Test func winProbabilityFavorsPlayerLeadingInSetsBestOfThree() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let tour = Tournament(externalKey: "t-atp", name: "Miami Open", city: "Miami", country: "USA", surface: "Hard", tour: .atp, startDate: .now, endDate: .now)
        let match = TennisMatch(
            externalID: "bo3-lead",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: alcaraz.name,
            gameScore: "3-2",
            tournament: tour,
            player1: alcaraz,
            player2: sinner,
            score: "6-4"
        )

        let estimate = try #require(WinProbabilityEstimate.compute(from: match))

        #expect(estimate.player1Percent > 70)
        #expect(estimate.player2Percent < 30)
        #expect(estimate.bestOfFive == false)
    }

    @MainActor
    @Test func winProbabilityFavorsPlayerTwoSetsUpBestOfFive() throws {
        let djokovic = Player(externalKey: "p1", name: "Novak Djokovic", nationality: "SRB", isWTA: false)
        let alcaraz = Player(externalKey: "p2", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let major = Tournament(externalKey: "wimbledon", name: "Wimbledon", city: "London", country: "GBR", surface: "Grass", tour: .atp, startDate: .now, endDate: .now)
        let match = TennisMatch(
            externalID: "bo5-2-0",
            date: .now,
            status: "Live",
            isLive: true,
            tournament: major,
            player1: djokovic,
            player2: alcaraz,
            score: "6-3 6-4"
        )

        let estimate = try #require(WinProbabilityEstimate.compute(from: match))

        #expect(estimate.bestOfFive == true)
        #expect(estimate.player1Percent >= 85)
        #expect(estimate.player2Percent <= 15)
    }

    @MainActor
    @Test func winProbabilityClampsWithinBoundsWhenDominated() throws {
        let djokovic = Player(externalKey: "p1", name: "Novak Djokovic", nationality: "SRB", isWTA: false)
        let alcaraz = Player(externalKey: "p2", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let major = Tournament(externalKey: "roland-garros", name: "Roland Garros", city: "Paris", country: "FRA", surface: "Clay", tour: .atp, startDate: .now, endDate: .now)
        let match = TennisMatch(
            externalID: "clamp",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: djokovic.name,
            gameScore: "5-0",
            tournament: major,
            player1: djokovic,
            player2: alcaraz,
            score: "6-0 6-0"
        )

        let estimate = try #require(WinProbabilityEstimate.compute(from: match))

        #expect(estimate.player1Probability <= 0.95)
        #expect(estimate.player2Probability >= 0.05)
    }

    @MainActor
    @Test func headToHeadDigestReturnsEmptyWhenNoPriorMeetings() throws {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let current = TennisMatch(externalID: "first", date: .now, player1: alcaraz, player2: sinner)

        let digest = HeadToHeadDigest.compute(currentMatch: current, allMatches: [current])

        #expect(digest.totalMeetings == 0)
        #expect(digest.winsByPlayer1 == 0)
        #expect(digest.winsByPlayer2 == 0)
        #expect(digest.currentStreak == nil)
        #expect(digest.surfaceSplits.isEmpty)
        #expect(digest.lastEncounterID == nil)
    }

    @MainActor
    @Test func upsertDeduplicatesExistingExternalKeys() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let first = Player(externalKey: "dup-player", name: "Old Name", nationality: "UNK", isWTA: false)
        let duplicate = Player(externalKey: "dup-player", name: "Duplicate", nationality: "UNK", isWTA: false)
        context.insert(first)
        context.insert(duplicate)

        let resolved = Player.upsert(
            from: PlayerDTO(id: "dup-player", name: "Carlos Alcaraz", nationality: "ESP", tour: "ATP", birthDate: nil),
            in: context
        )
        try context.save()

        let descriptor = FetchDescriptor<Player>(predicate: #Predicate { $0.externalKey == "dup-player" })
        let stored = try context.fetch(descriptor)
        #expect(stored.count == 1)
        #expect(resolved.name == "Carlos Alcaraz")
        #expect(stored.first?.nationality == "ESP")
    }

    @MainActor
    @Test func timelineWritesVersionedPayloadAndReadsLegacyArray() throws {
        let legacyEvent = MatchTimelineEvent(timestamp: .now, title: "Legacy", detail: "Old array")
        let match = TennisMatch(externalID: "timeline-version", date: .now, status: "Live", isLive: true)
        match.liveTimelinePayload = try timelinePayload([legacyEvent])
        #expect(match.timelineEvents.count == 1)

        match.serverName = "Carlos Alcaraz"
        match.pointScore = "40-30"
        match.registerLiveTimelineEvent(pointWinnerName: "Carlos Alcaraz")

        let data = try #require(match.liveTimelinePayload.data(using: .utf8))
        let payload = try JSONDecoder().decode(MatchTimelinePayload.self, from: data)
        #expect(payload.schemaVersion == MatchTimelinePayload.currentSchemaVersion)
        #expect(payload.events.count == 2)
    }

    @MainActor
    @Test func matchOrderOfPlaySnapshotPersistsInVersionedPayload() throws {
        let match = TennisMatch(externalID: "oop-match", date: .now, status: "Scheduled")
        match.updateOrderOfPlaySnapshot(
            MatchOrderOfPlaySnapshot(
                courtName: "Court Suzanne-Lenglen",
                order: 3,
                source: "test-provider",
                capturedAt: .now
            )
        )

        let payload = try JSONDecoder().decode(
            MatchTimelinePayload.self,
            from: #require(match.liveTimelinePayload.data(using: .utf8))
        )

        #expect(match.orderOfPlaySnapshot?.courtName == "Court Suzanne-Lenglen")
        #expect(payload.orderOfPlay?.order == 3)
    }

    @Test func apiTennisOrderOfPlayParserBuildsCourtAndOrderSnapshot() throws {
        let provider = APITennisProvider(
            baseURL: URL(string: "https://example.com")!,
            usesBackendProxy: true,
            hasBackendProxy: true
        )

        let snapshot = try #require(
            provider.mapOrderOfPlay(
                courtCandidates: [nil, "  Court 1  ", "ignored"],
                orderCandidates: [nil, "Match 2"],
                source: "test-provider"
            )
        )

        #expect(snapshot.courtName == "Court 1")
        #expect(snapshot.order == 2)
    }

    @MainActor
    @Test func matchStatsBreakdownUsesOfficialWTAAdvancedStats() throws {
        let iga = Player(externalKey: "wta-p1", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let coco = Player(externalKey: "wta-p2", name: "Coco Gauff", nationality: "USA", isWTA: true)
        let match = TennisMatch(
            externalID: "wta-stats",
            date: .now,
            status: "Live",
            isLive: true,
            player1: iga,
            player2: coco
        )

        match.updateAdvancedStatsSnapshot(
            AdvancedMatchStatsSnapshot(
                player1: .init(
                    aces: 4,
                    winners: 18,
                    unforcedErrors: 11,
                    doubleFaults: 2,
                    netPointsWon: 7,
                    netPointsPlayed: 10
                ),
                player2: .init(
                    aces: 2,
                    winners: 14,
                    unforcedErrors: 16,
                    doubleFaults: 5,
                    netPointsWon: 5,
                    netPointsPlayed: 9
                ),
                source: "test-provider",
                capturedAt: .now
            )
        )

        let payload = try JSONDecoder().decode(
            MatchTimelinePayload.self,
            from: #require(match.liveTimelinePayload.data(using: .utf8))
        )
        let breakdown = MatchStatsBreakdown.compute(from: match)

        #expect(payload.advancedStats?.player1.unforcedErrors == 11)
        #expect(breakdown.isMeaningful)
        #expect(breakdown.player1.winners == 18)
        #expect(breakdown.player2.unforcedErrors == 16)
        #expect(breakdown.player1.netPointsWon == 7)
        #expect(breakdown.player1.netPointsPlayed == 10)
        #expect(breakdown.player2.netPointsWonRatio > 0.55)
    }

    @Test func apiTennisAdvancedStatsParserAcceptsKeyedStatisticPayloads() throws {
        let json = """
        {
          "Winners": { "home": 18, "away": 14 },
          "Unforced Errors": { "home": 11, "away": 16 },
          "Net Points Won": { "home": "7/10", "away": "5/9" }
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let statistics = try decoder.decode(LossyAPIMatchStatistics.self, from: json)
        let provider = APITennisProvider(
            baseURL: URL(string: "https://example.com")!,
            usesBackendProxy: true,
            hasBackendProxy: true
        )

        let snapshot = try #require(provider.mapAdvancedStats(statistics))

        #expect(snapshot.player1.winners == 18)
        #expect(snapshot.player2.unforcedErrors == 16)
        #expect(snapshot.player1.netPointsWon == 7)
        #expect(snapshot.player1.netPointsPlayed == 10)
        #expect(snapshot.player2.netPointsWon == 5)
        #expect(snapshot.player2.netPointsPlayed == 9)
    }

    @MainActor
    @Test func pointBetCarriesIntegrityAndServerAuthorityState() {
        let match = TennisMatch(externalID: "bet-match", date: .now)
        let player = Player(externalKey: "p1", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let bet = PointBet(match: match, player: player, selection: player.name, stake: 25, payout: 45)

        #expect(bet.integrityHash.isEmpty == false)
        #expect(bet.serverSettlementStatus == .pending)
        #expect(bet.settlementAuthority == .localPendingServer)
    }

    @MainActor
    @Test func tennisMatchDetectsCancelledWalkoverAndRetirement() {
        let cancelled = TennisMatch(externalID: "c", date: .now, status: "Cancelled")
        let postponed = TennisMatch(externalID: "p", date: .now, status: "Postponed")
        let walkover = TennisMatch(externalID: "w", date: .now, status: "W/O")
        let retired = TennisMatch(externalID: "r", date: .now, status: "Retired")
        let final = TennisMatch(externalID: "f", date: .now, status: "Final")

        #expect(cancelled.isCancelled)
        #expect(postponed.isCancelled)
        #expect(walkover.isWalkover)
        #expect(retired.isRetirement)
        #expect(cancelled.endedIrregularly)
        #expect(walkover.endedIrregularly)
        #expect(retired.endedIrregularly)

        // Cancelled is NOT completed (never played); walkover/retirement ARE completed.
        #expect(cancelled.isCompleted == false)
        #expect(walkover.isCompleted)
        #expect(retired.isCompleted)
        #expect(final.isCompleted)
        #expect(final.endedIrregularly == false)
    }

    @MainActor
    @Test func betSettlementVoidsCancelledMatchRegardlessOfKind() {
        let player = Player(externalKey: "p1", name: "Iga Swiatek", nationality: "POL", isWTA: true)
        let opponent = Player(externalKey: "p2", name: "Coco Gauff", nationality: "USA", isWTA: true)
        let cancelled = TennisMatch(
            externalID: "cancelled-final",
            date: .now,
            status: "Cancelled",
            player1: player,
            player2: opponent,
            score: ""
        )

        let matchWinnerBet = PointBet(match: cancelled, player: player, kind: .matchWinner, selection: player.name, stake: 50, payout: 90)
        let setBet = PointBet(match: cancelled, player: player, kind: .setWinner, selection: player.name, stake: 50, payout: 110, targetSetIndex: 0)
        let scoreBet = PointBet(match: cancelled, player: player, kind: .finalScore, selection: player.name, stake: 50, payout: 170, predictedScore: "6-4 6-4")

        #expect(BetSettlementEngine.status(for: matchWinnerBet) == .void)
        #expect(BetSettlementEngine.status(for: setBet) == .void)
        #expect(BetSettlementEngine.status(for: scoreBet) == .void)
    }

    @MainActor
    @Test func scoreboardCapturesTieBreakLoserScore() {
        let data = MatchScoreboardData(score: "7-6(4) 6-3 7-6(11)")
        #expect(data.sets.count == 3)
        #expect(data.sets[0].player1Games == "7")
        #expect(data.sets[0].player2Games == "6")
        #expect(data.sets[0].loserTieBreak == "4")
        #expect(data.sets[1].loserTieBreak == nil)
        #expect(data.sets[2].loserTieBreak == "11")

        // Backwards-compatible: plain scores still parse the same way.
        let plain = MatchScoreboardData(score: "6-4 3-6 6-3")
        #expect(plain.sets.map(\.loserTieBreak) == [nil, nil, nil])
    }

    @Test func liveMatchNormalizedIdentityCollapsesWhitespaceAndDiacritics() {
        #expect(LiveMatchWebSocketService.normalizedIdentity("Carlos Alcaraz") == "carlos alcaraz")
        #expect(LiveMatchWebSocketService.normalizedIdentity("Carlos  Alcaraz") == "carlos alcaraz")
        #expect(LiveMatchWebSocketService.normalizedIdentity("  Carlos\tAlcaraz\n") == "carlos alcaraz")
        #expect(LiveMatchWebSocketService.normalizedIdentity("CARLOS ALCARAZ") == "carlos alcaraz")
        #expect(LiveMatchWebSocketService.normalizedIdentity("Iga Świątek") == "iga swiatek")
        #expect(LiveMatchWebSocketService.normalizedIdentity("") == "")
    }

    @Test func liveMatchParseDateReturnsNilForMalformedInputInsteadOfNow() {
        #expect(LiveMatchWebSocketService.parseDate(dateString: nil, timeString: nil) == nil)
        #expect(LiveMatchWebSocketService.parseDate(dateString: "", timeString: "12:00") == nil)
        #expect(LiveMatchWebSocketService.parseDate(dateString: "not-a-date", timeString: nil) == nil)

        let dateOnly = LiveMatchWebSocketService.parseDate(dateString: "2026-05-17", timeString: nil)
        #expect(dateOnly != nil)

        let dateWithTime = LiveMatchWebSocketService.parseDate(dateString: "2026-05-17", timeString: "12:30")
        #expect(dateWithTime != nil)
        if let dateOnly, let dateWithTime {
            #expect(dateWithTime > dateOnly)
        }
    }

    @Test func providerReadinessReportsAPITennisStatus() {
        let apiTennisReadiness = TennisAPIConfiguration.providerReadiness(for: .apiTennis)

        #expect(apiTennisReadiness.provider == .apiTennis)
        #expect(apiTennisReadiness.usesBackendProxy)
        #expect(apiTennisReadiness.isReadyForSync == apiTennisReadiness.hasBackendProxy)
    }

    @MainActor
    @Test func apiClientBuildsQueryHeadersAndSurfacesHTTPStatus() async throws {
        let session = URLSession.mocked { request in
            #expect(request.url?.query?.contains("method=get_livescore") == true)
            #expect(request.url?.query?.contains("fixture_id=test-fixture") == true)
            #expect(request.value(forHTTPHeaderField: "X-Test") == "yes")
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":"unauthorized"}"#.utf8), response)
        }
        let client = APIClient(baseURL: URL(string: "https://example.com/tennis/")!, session: session)

        do {
            let _: APIEnvelope<[APILiveMatch]> = try await client.get(
                query: ["method": "get_livescore", "fixture_id": "test-fixture"],
                headers: ["X-Test": "yes"]
            )
            Issue.record("Expected HTTP error")
        } catch let error as APIHTTPError {
            #expect(error.statusCode == 401)
        }
    }

    @MainActor
    @Test func apiTennisProviderRetriesServerErrorsAndDecodesNumericIDs() async throws {
        final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        let session = URLSession.mocked { request in
            counter.count += 1
            if counter.count == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data("temporary".utf8), response)
            }
            let body = """
            {
              "success": 1,
              "result": [
                {
                  "event_key": 12134174,
                  "tournament_key": 987,
                  "event_date": "2026-06-07",
                  "event_time": "12:30",
                  "event_first_player": "P. Herbert",
                  "first_player_key": 30,
                  "event_second_player": "D. Glinka",
                  "second_player_key": 5,
                  "event_status": "Set 1",
                  "event_live": "1",
                  "event_serve": "Second Player",
                  "event_first_player_point": 30,
                  "event_second_player_point": 40,
                  "scores": [{"score_first": 4, "score_second": 5, "score_set": 1}]
                }
              ]
            }
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let api = TennisAPI(baseURL: URL(string: "https://example.com/tennis/")!, session: session)

        let matches = try await api.liveMatches()

        #expect(counter.count == 2)
        #expect(matches.first?.id == "12134174")
        #expect(matches.first?.tournamentId == "987")
        #expect(matches.first?.player1Id == "30")
        #expect(matches.first?.player2Id == "5")
        #expect(matches.first?.score == "4-5")
        #expect(matches.first?.serverName == "D. Glinka")
        #expect(matches.first?.pointScore == "30-40")
    }

    @MainActor
    @Test func dataSyncServiceFallsBackToMatchesWhenTournamentEndpointFails() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let api = MockTennisAPI()
        api.tournamentsError = APIError(message: "500")
        api.fixtureMatches = [
            MatchDTO(
                id: "fallback-match",
                date: .now,
                tournamentId: "fallback-tournament",
                player1Id: "p1",
                player2Id: "p2",
                player1Name: "Carlos Alcaraz",
                player2Name: "Jannik Sinner",
                player1Country: "ESP",
                player2Country: "ITA",
                score: "",
                status: "Scheduled",
                isLive: false
            )
        ]

        try await DataSyncService(context: context, api: api).syncTournaments()

        let tournaments = try context.fetch(FetchDescriptor<Tournament>())
        #expect(tournaments.map(\.externalKey).contains("fallback-tournament"))
    }

    @MainActor
    @Test func dataSyncServiceSurfacesErrorWhenBothMatchFallbacksFail() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let api = MockTennisAPI()
        api.tournamentsError = APIError(message: "500")
        api.fixturesError = APIError(message: "fixtures failed")
        api.liveMatchesError = APIError(message: "live failed")

        do {
            try await DataSyncService(context: context, api: api).syncTournaments()
            Issue.record("Expected sync error")
        } catch {
            #expect((error as? APIError)?.message == "live failed")
        }
    }

    @MainActor
    @Test func alertEventEngineSchedulesCancelsAndCleansDeletedMatches() async throws {
        let center = MockNotificationCenter()
        let defaults = UserDefaults(suiteName: "match-point-tests-\(UUID().uuidString)")!
        let engine = AlertEventEngine(center: center, defaults: defaults)
        let favorite = Player(externalKey: "p1", name: "Iga Swiatek", nationality: "POL", isWTA: true, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Coco Gauff", nationality: "USA", isWTA: true)
        let match = TennisMatch(
            externalID: "notify-1",
            date: .now.addingTimeInterval(3_600),
            status: "Scheduled",
            isLive: false,
            player1: favorite,
            player2: opponent
        )
        let store = AlertPreferencesStore.shared
        store.update {
            $0.notificationsEnabled = true
            $0.notifyBeforeMatch = true
            $0.notifyMatchStarted = true
            $0.notifyMatchFinished = true
            $0.leadTimeMinutes = 15
        }
        store.setAuthorizationStatusForTesting(.authorized)
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(favorite)
        context.insert(opponent)
        context.insert(match)

        await engine.refreshScheduledNotifications(in: context)
        #expect(center.pending.map(\.identifier).contains("match-point.alert.upcoming.notify-1.15"))

        match.status = "Cancelled"
        await engine.processMatchUpdate(match, previous: MatchAlertSnapshot(isLive: false, status: "Scheduled"))
        #expect(center.removedPending.contains("match-point.alert.upcoming.notify-1.15"))

        await engine.cleanupNotifications(forDeletedMatchID: "notify-1")
        #expect(center.removedDelivered.contains("match-point.alert.event.start.notify-1"))
        #expect(center.removedDelivered.contains("match-point.alert.event.finish.notify-1"))
    }

    @MainActor
    @Test func alertEventEnginePromotesFifthSetBreakToUrgentNotification() async {
        let center = MockNotificationCenter()
        let defaults = UserDefaults(suiteName: "match-point-tests-\(UUID().uuidString)")!
        let engine = AlertEventEngine(center: center, defaults: defaults)
        let favorite = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false, isFavorite: true)
        let opponent = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "break-urgent-1",
            date: .now,
            status: "Live",
            isLive: true,
            serverName: favorite.name,
            pointScore: "0-0",
            gameScore: "5-4",
            player1: favorite,
            player2: opponent,
            score: "6-4 3-6 7-6 4-6"
        )
        let previous = MatchAlertSnapshot(
            isLive: true,
            status: "Live",
            serverName: opponent.name,
            pointScore: "40-A",
            gameScore: "4-4",
            score: "6-4 3-6 7-6 4-6"
        )
        let store = AlertPreferencesStore.shared
        store.update {
            $0.notificationsEnabled = true
            $0.followFavoritePlayers = true
            $0.notifyMatchStarted = true
            $0.notifyMatchFinished = true
        }
        store.setAuthorizationStatusForTesting(.authorized)

        await engine.processMatchUpdate(match, previous: previous)

        let request = center.pending.first { $0.identifier.hasPrefix("match-point.alert.event.breakServe.break-urgent-1") }
        #expect(request != nil)
        #expect(request?.content.title == "Quebra de saque")
        #expect(request?.content.body.contains("Carlos Alcaraz acabou de quebrar o saque de Jannik Sinner no 5º set") == true)
        #expect(request?.content.sound != nil)
        #expect(request?.content.userInfo["matchPointNotificationLevel"] as? String == "urgent")
        if #available(iOS 15.0, macOS 12.0, *) {
            #expect(request?.content.interruptionLevel == .timeSensitive)
        }
    }

    @Test func webSocketBackoffAndFrameParserHandleEdgeCases() throws {
        #expect(LiveMatchWebSocketService.reconnectDelay(forAttempt: 0) == 1)
        #expect(LiveMatchWebSocketService.reconnectDelay(forAttempt: 1) == 2)
        #expect(LiveMatchWebSocketService.reconnectDelay(forAttempt: 8) == 60)

        let frame = """
        {"meta":{"ignored":true},"result":[{"event_key":121,"event_first_player":"Bia Haddad","event_second_player":"Iga Swiatek"},{"noise":1}]}
        """
        let dictionaries = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: Data(frame.utf8))
        #expect(dictionaries.count == 1)
        #expect(dictionaries.first?["event_key"] as? Int == 121)

        let tooDeep = #"{"a":{"b":{"event_key":122}}}"#
        #expect(try LiveMatchWebSocketService.matchDictionaries(fromFrameData: Data(tooDeep.utf8), maxDepth: 1).isEmpty)
    }

    @MainActor
    @Test func remotePushBackendURLRequiresHTTPSHost() {
        #expect(RemotePushManager.validatedBackendURL("https://api.matchpoint.app/push") != nil)
        #expect(RemotePushManager.validatedBackendURL("http://api.matchpoint.app/push") == nil)
        #expect(RemotePushManager.validatedBackendURL("file:///tmp/push") == nil)
        #expect(RemotePushManager.validatedBackendURL("https:///missing-host") == nil)
    }

    @MainActor
    @Test func cloudModerationEndpointRequiresAdminTokenForActions() throws {
        let report = try CloudSocialBackend.makeModerationEndpoint(
            baseURL: "https://backend.matchpoint.app/base",
            path: "/social/moderation/report",
            requiresAdmin: false,
            adminToken: nil
        )
        #expect(report.url.absoluteString == "https://backend.matchpoint.app/social/moderation/report")
        #expect(report.authorization == nil)

        do {
            _ = try CloudSocialBackend.makeModerationEndpoint(
                baseURL: "https://backend.matchpoint.app",
                path: "/social/moderation/action",
                requiresAdmin: true,
                adminToken: nil
            )
            Issue.record("Expected missing admin token to fail")
        } catch {
            #expect(error is LocalizedError)
        }

        let action = try CloudSocialBackend.makeModerationEndpoint(
            baseURL: "https://backend.matchpoint.app",
            path: "/social/moderation/action",
            requiresAdmin: true,
            adminToken: "admin-token"
        )
        #expect(action.authorization == "Bearer admin-token")
    }

    @MainActor
    @Test func backendLeaderboardDecodingUsesServerAuthoritativeRows() throws {
        let payload = """
        {
          "ok": true,
          "leaderboard": [
            {
              "id": "leader:user-a",
              "userRecordName": "user-a",
              "displayName": "Ana",
              "avatarSymbol": "bolt.fill",
              "points": 1060,
              "wins": 1,
              "losses": 1,
              "currentStreak": 0,
              "updatedAt": "2026-07-12T14:00:00.000Z"
            }
          ]
        }
        """

        let rows = try CloudSocialBackend.decodeBackendLeaderboard(
            Data(payload.utf8),
            currentUserRecordName: "user-a"
        )

        #expect(rows.count == 1)
        #expect(rows[0].id == "leader:user-a")
        #expect(rows[0].displayName == "Ana")
        #expect(rows[0].points == 1060)
        #expect(rows[0].wins == 1)
        #expect(rows[0].losses == 1)
        #expect(rows[0].isCurrentUser)
    }

    @MainActor
    @Test func rankingProjectionAndSocialEventsStayDeterministic() {
        let player = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let opponent = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let tournament = Tournament(
            externalKey: "gs",
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400)
        )
        let match = TennisMatch(
            externalID: "projection-social",
            date: .now,
            status: "Match point",
            isLive: true,
            serverName: player.name,
            pointScore: "40-15",
            gameScore: "5-4",
            tournament: tournament,
            player1: player,
            player2: opponent,
            score: "6-4"
        )
        let rankings = [
            RankingEntry(externalKey: "r1", player: player, rank: 3, points: 7_000, tour: .atp),
            RankingEntry(externalKey: "r2", player: opponent, rank: 2, points: 7_200, tour: .atp)
        ]

        let projection = RankingProjectionEngine.projectionText(for: match, rankings: rankings)
        let playerProjection = RankingProjectionEngine.projectionText(for: player, in: match, rankings: rankings)
        let events = SocialEventGenerator.events(for: match)

        #expect(projection?.contains("+2000") == true)
        #expect(playerProjection?.contains("Carlos Alcaraz") == true)
        #expect(events.contains { $0.id.contains("match-point") })
        #expect(events.contains { $0.body.contains("Match point") })
    }

    @MainActor
    @Test func doublesMatchCarriesTeamLabelsAndInvolvesPartners() {
        let alcaraz = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let nadal = Player(externalKey: "p2", name: "Rafael Nadal", nationality: "ESP", isWTA: false)
        let sinner = Player(externalKey: "p3", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let berrettini = Player(externalKey: "p4", name: "Matteo Berrettini", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "doubles-1",
            date: .now,
            status: "Scheduled",
            player1: alcaraz,
            player2: sinner,
            player1Partner: nadal,
            player2Partner: berrettini
        )

        #expect(match.isDoubles)
        #expect(match.player1TeamName == "Carlos Alcaraz / Rafael Nadal")
        #expect(match.player2TeamName == "Jannik Sinner / Matteo Berrettini")
        #expect(match.involves(player: nadal))
        #expect(match.involves(player: berrettini))
        #expect(SocialEventGenerator.events(for: match).isEmpty)
    }

    @Test func remotePushTokenRequestBuildsRegisterAndUnregisterPayloads() throws {
        let url = try #require(RemotePushManager.validatedBackendURL("https://api.matchpoint.app/push"))
        let register = try RemotePushManager.makeTokenRequest(
            to: url,
            action: "register",
            reason: "unit-test",
            deviceToken: "abcdef",
            bundleIdentifier: "app.matchpoint",
            environment: "sandbox",
            registeredForRemoteNotifications: true
        )
        let unregister = try RemotePushManager.makeTokenRequest(
            to: url,
            action: "unregister",
            reason: "unit-test",
            deviceToken: "abcdef",
            bundleIdentifier: "app.matchpoint",
            environment: "sandbox",
            registeredForRemoteNotifications: false
        )

        #expect(register.httpMethod == "POST")
        #expect(register.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let registerBody = try #require(register.httpBody)
        let unregisterBody = try #require(unregister.httpBody)
        let registerJSON = try #require(JSONSerialization.jsonObject(with: registerBody) as? [String: Any])
        let unregisterJSON = try #require(JSONSerialization.jsonObject(with: unregisterBody) as? [String: Any])
        #expect(registerJSON["action"] as? String == "register")
        #expect(registerJSON["registeredForRemoteNotifications"] as? Bool == true)
        #expect(unregisterJSON["action"] as? String == "unregister")
        #expect(unregisterJSON["registeredForRemoteNotifications"] as? Bool == false)
    }

    @MainActor
    @Test func remotePushSubscriptionPayloadCarriesFavoritesAndUrgencyRules() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tournament = Tournament(
            externalKey: "wimbledon",
            name: "Wimbledon",
            city: "London",
            country: "United Kingdom",
            surface: "Grass",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400),
            isFavorite: true
        )
        let favorite = Player(externalKey: "sinner", name: "Jannik Sinner", nationality: "ITA", isWTA: false, isFavorite: true)
        let opponent = Player(externalKey: "brooksby", name: "J. Brooksby", nationality: "USA", isWTA: false)
        let match = TennisMatch(
            externalID: "match-1",
            date: .now.addingTimeInterval(3_600),
            status: "Scheduled",
            isFavorite: true,
            tournament: tournament,
            player1: favorite,
            player2: opponent
        )
        context.insert(tournament)
        context.insert(favorite)
        context.insert(opponent)
        context.insert(match)
        try context.save()

        let preferences = AlertPreferences(notificationsEnabled: true, leadTimeMinutes: 10)
        let subscription = try RemotePushManager.makeSubscriptionPayload(in: context, preferences: preferences)

        #expect(subscription.favorites.players.contains { $0.id == "sinner" })
        #expect(subscription.favorites.matches.contains { $0.id == "match-1" })
        #expect(subscription.favorites.tournaments.contains { $0.id == "wimbledon" })
        #expect(subscription.eventRules.contains { $0.event == .matchPoint && $0.level == .urgent && $0.enabled })
        #expect(subscription.eventRules.contains { $0.event == .finalSetBreakServe && $0.level == .urgent && $0.enabled })
        #expect(subscription.backendDataPlane.ingestion.mode == .alwaysOn)
        #expect(subscription.backendDataPlane.reconciliation.duplicatePolicy == .mergeByProviderTimestamp)
        #expect(subscription.backendDataPlane.eventQueue.delivery == .atLeastOnce)
        #expect(subscription.backendDataPlane.pushDecisioning.owner == .server)
        #expect(subscription.backendDataPlane.pushDecisioning.supportedEvents.contains(.matchPoint))

        let url = try #require(RemotePushManager.validatedBackendURL("https://api.matchpoint.app/push"))
        let request = try RemotePushManager.makeTokenRequest(
            to: url,
            action: "register",
            reason: "subscription-test",
            deviceToken: "abcdef",
            bundleIdentifier: "app.matchpoint",
            environment: "sandbox",
            registeredForRemoteNotifications: true,
            subscription: subscription
        )
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let encodedSubscription = try #require(json["subscription"] as? [String: Any])
        let rules = try #require(encodedSubscription["eventRules"] as? [[String: Any]])
        let dataPlane = try #require(encodedSubscription["backendDataPlane"] as? [String: Any])
        let ingestion = try #require(dataPlane["ingestion"] as? [String: Any])
        let reconciliation = try #require(dataPlane["reconciliation"] as? [String: Any])
        let queue = try #require(dataPlane["eventQueue"] as? [String: Any])
        let pushDecisioning = try #require(dataPlane["pushDecisioning"] as? [String: Any])
        #expect(rules.contains { $0["event"] as? String == "match.match-point" && $0["level"] as? String == "urgent" })
        #expect(ingestion["mode"] as? String == "always-on")
        #expect(reconciliation["duplicatePolicy"] as? String == "merge-by-provider-timestamp")
        #expect(queue["delivery"] as? String == "at-least-once")
        #expect(pushDecisioning["owner"] as? String == "server")
    }

    @Test func keychainSecretStoreRoundTripsAndDeletesToken() {
        let service = "match-point-tests-\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let account = "moderation-token"

        store.delete(account: account)
        guard store.write("secret-token", account: account) else {
            return
        }
        #expect(store.read(account: account) == "secret-token")

        #expect(store.write("rotated-token", account: account))
        #expect(store.read(account: account) == "rotated-token")

        #expect(store.delete(account: account))
        #expect(store.read(account: account) == nil)
    }

    // Contract test for TennisAPIConfiguration.staticURL — the production code
    // crashes via preconditionFailure if any of the hard-coded provider URL
    // literals fails to parse. Exercising the typed accessors at unit-test
    // time turns a "ships and crashes at launch" bug into a CI failure: if
    // anyone edits the literal incorrectly, this test trips before merge.
    @Test func providerStaticURLsParseAndUseTLS() {
        let rest = TennisAPIConfiguration.apiTennisRestBaseURL
        #expect(rest.scheme == "https")
        #expect(rest.host?.isEmpty == false)
        #expect(rest.path.hasPrefix("/"))

        let ws = TennisAPIConfiguration.apiTennisWebSocketBaseURL
        #expect(ws.scheme == "wss")
        #expect(ws.host?.isEmpty == false)

        #expect(TennisAPIConfiguration.validatedBackendProxyURL("https://api.matchpoint.app/tennis") != nil)
        #expect(TennisAPIConfiguration.validatedBackendProxyURL("ftp://api.matchpoint.app/tennis") == nil)
        #expect(TennisAPIConfiguration.validatedBackendWebSocketURL("wss://api.matchpoint.app/live") != nil)
        #expect(TennisAPIConfiguration.validatedBackendWebSocketURL("https://api.matchpoint.app/live") == nil)
    }

    @MainActor
    @Test func officialRankingProjectionUsesDefendingPointsAndLiveRankingSnapshot() {
        let tournament = Tournament(
            externalKey: "wimbledon",
            name: "Wimbledon",
            city: "London",
            country: "United Kingdom",
            surface: "Grass",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(86_400 * 14)
        )
        let candidate = Player(externalKey: "p1", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let currentNumberThree = Player(externalKey: "p3", name: "Player Three", nationality: "USA", isWTA: false)
        let currentNumberFour = Player(externalKey: "p4", name: "Player Four", nationality: "FRA", isWTA: false)
        let opponent = Player(externalKey: "p2", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let match = TennisMatch(
            externalID: "official-ranking-final",
            date: .now,
            status: "Scheduled",
            tournament: tournament,
            player1: candidate,
            player2: opponent
        )
        tournament.matches = [match]
        let snapshot = OfficialRankingProjectionSnapshot(
            source: "ATP live rankings",
            generatedAt: .now,
            entries: [
                .init(playerExternalKey: "p-top-1", playerName: "Player One", tourRaw: "ATP", currentRank: 1, currentPoints: 9_000, liveRank: 1, livePoints: 9_000, raceRank: nil, racePoints: nil, defendingPoints: 0, earnedPoints: 0),
                .init(playerExternalKey: "p-top-2", playerName: "Player Two", tourRaw: "ATP", currentRank: 2, currentPoints: 8_000, liveRank: 2, livePoints: 8_000, raceRank: nil, racePoints: nil, defendingPoints: 0, earnedPoints: 0),
                .init(
                    playerExternalKey: "p1",
                    playerName: candidate.name,
                    tourRaw: "ATP",
                    currentRank: 5,
                    currentPoints: 5_500,
                    liveRank: 5,
                    livePoints: 5_500,
                    raceRank: 4,
                    racePoints: 4_900,
                    defendingPoints: 400,
                    earnedPoints: 1_300
                ),
                .init(playerExternalKey: "p3", playerName: currentNumberThree.name, tourRaw: "ATP", currentRank: 3, currentPoints: 6_950, liveRank: 3, livePoints: 6_950, raceRank: nil, racePoints: nil, defendingPoints: 0, earnedPoints: 0),
                .init(playerExternalKey: "p4", playerName: currentNumberFour.name, tourRaw: "ATP", currentRank: 4, currentPoints: 6_100, liveRank: 4, livePoints: 6_100, raceRank: nil, racePoints: nil, defendingPoints: 0, earnedPoints: 0)
            ],
            tournament: .init(
                tournamentExternalKey: "wimbledon",
                tournamentName: "Wimbledon",
                pointsByRound: .init(winner: 2_000, finalist: 1_300, semiFinalist: 800, quarterFinalist: 400, roundOf16: 200, earlyRound: 100)
            )
        )

        let text = RankingProjectionEngine.projectionText(
            for: candidate,
            in: match,
            rankings: [],
            officialSnapshot: snapshot
        )

        #expect(text?.contains("Projeção oficial ATP live rankings") == true)
        #expect(text?.contains("sobe de #5 para #3") == true)
        #expect(text?.contains("defende 400, ganha 2000") == true)
        #expect(text?.contains("Race: #4") == true)
    }

    /// Catches a common SwiftData migration mistake: bumping the schema
    /// version (adding a new `MatchPointSchemaVn`) without registering the
    /// matching `MigrationStage`. With N schemas you need exactly N-1
    /// stages — one per adjacent transition. Empty `stages` is only valid
    /// while a single schema exists.
    @Test func migrationPlanHasOneStagePerSchemaTransition() {
        let schemaCount = MatchPointMigrationPlan.schemas.count
        let stageCount = MatchPointMigrationPlan.stages.count
        let expected = max(0, schemaCount - 1)
        #expect(stageCount == expected,
                "MatchPointMigrationPlan has \(schemaCount) schemas but \(stageCount) stages — should be \(expected)")
    }

    /// SyncCoordinator must serialize calls — two concurrent `runMainActor`
    /// invocations should observe a strict before/after ordering, not race.
    @Test func syncCoordinatorSerializesConcurrentCalls() async throws {
        actor Recorder {
            var order: [Int] = []
            func append(_ n: Int) { order.append(n) }
        }
        let coordinator = SyncCoordinator()
        let recorder = Recorder()

        async let first: () = try coordinator.runMainActor {
            try? await Task.sleep(for: .milliseconds(50))
            await recorder.append(1)
        }
        async let second: () = try coordinator.runMainActor {
            await recorder.append(2)
        }

        _ = try await (first, second)
        let order = await recorder.order
        #expect(order == [1, 2],
                "Second runMainActor must wait for the first to finish before mutating order")
    }

    /// AlertEventEngine returns a *healed* snapshot (matching current match
    /// state) when the persisted blob is corrupted, so processMatchUpdate
    /// doesn't re-fire matchStarted notifications on the next refresh.
    @MainActor
    @Test func alertEventEngineHealsCorruptedSnapshot() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let player1 = Player(externalKey: "p1", name: "Sample", nationality: "BR", isWTA: false)
        let player2 = Player(externalKey: "p2", name: "Other", nationality: "AR", isWTA: false)
        let match = TennisMatch(
            externalID: "snapshot-corrupted-\(UUID().uuidString)",
            date: .now,
            status: "Live",
            isLive: true,
            player1: player1,
            player2: player2,
            score: "6-4"
        )
        context.insert(player1)
        context.insert(player2)
        context.insert(match)
        try context.save()

        let engine = AlertEventEngine.shared
        let id = engine.matchNotificationID(for: match)
        let key = "match-point.alert.snapshot.\(id)"
        let defaults = UserDefaults.standard

        // Plant a corrupted blob and verify healing.
        defaults.set(Data("garbage-not-json".utf8), forKey: key)
        let healed = engine.snapshotForStoredMatch(match)
        #expect(healed != nil, "Engine should heal corrupted snapshots into a fresh one")
        #expect(healed?.isLive == true)

        // After healing the key must contain a valid encoded snapshot now.
        let data = try #require(defaults.data(forKey: key))
        #expect((try? JSONDecoder().decode(MatchAlertSnapshot.self, from: data)) != nil)

        defaults.removeObject(forKey: key)
    }

    /// MatchTimelinePayload `saveTimelineEvents` caps to 24 events and to
    /// ~32KB even if a caller bypasses the in-memory pre-trim.
    @MainActor
    @Test func matchTimelinePayloadCapsAt24EventsAndBytes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let match = TennisMatch(externalID: "timeline-cap", date: .now, status: "Live", isLive: true)
        context.insert(match)

        // Append 60 distinct events through the public path — the defensive
        // cap inside saveTimelineEvents should trim to 24.
        for i in 0..<60 {
            match.registerLiveTimelineEvent(
                title: "Event \(i)",
                detail: "Detail \(i)",
                pointWinnerName: "Player \(i % 2 + 1)"
            )
        }

        let events = match.timelineEvents
        #expect(events.count <= 24, "Timeline must not persist more than 24 events; got \(events.count)")

        // Byte cap: payload string must stay under the 32KB budget.
        let byteCount = match.liveTimelinePayload.utf8.count
        #expect(byteCount <= 32_000,
                "Timeline payload must stay <= 32 KB to avoid bloating SwiftData rows; got \(byteCount) bytes")
    }

    /// Irregular match endings — every BetKind on a cancelled/postponed
    /// match must return `.void` (stake returned), regardless of selection.
    @MainActor
    @Test func betSettlementEngineVoidsCancelledAndPostponedMatches() throws {
        for status in ["Cancelled", "Postponed"] {
            let container = try makeContainer()
            let context = ModelContext(container)
            let player1 = Player(externalKey: "p1-\(status)", name: "P1", nationality: "BR", isWTA: false)
            let player2 = Player(externalKey: "p2-\(status)", name: "P2", nationality: "AR", isWTA: false)
            let match = TennisMatch(
                externalID: "void-\(status)",
                date: .now.addingTimeInterval(-3600),
                status: status,
                isLive: false,
                player1: player1,
                player2: player2,
                score: ""
            )
            context.insert(player1); context.insert(player2); context.insert(match)

            for kind in BetKind.allCases {
                let bet = PointBet(
                    match: match,
                    player: player1,
                    kind: kind,
                    selection: player1.name,
                    stake: 25,
                    payout: 50
                )
                #expect(BetSettlementEngine.status(for: bet) == .void,
                        "\(status) match × \(kind) must void; got \(String(describing: BetSettlementEngine.status(for: bet)))")
            }
        }
    }

    /// Walkover and Retired matches have a declared winner — the engine must
    /// settle Match Winner bets using the recorded score, not void them.
    @MainActor
    @Test func betSettlementEngineSettlesWalkoverAndRetiredMatches() throws {
        for status in ["W/O", "Retired"] {
            let container = try makeContainer()
            let context = ModelContext(container)
            let winner = Player(externalKey: "win-\(status)", name: "Winner", nationality: "BR", isWTA: false)
            let loser = Player(externalKey: "lose-\(status)", name: "Loser", nationality: "AR", isWTA: false)
            let match = TennisMatch(
                externalID: "irregular-\(status)",
                date: .now.addingTimeInterval(-3600),
                status: status,
                isLive: false,
                player1: winner,
                player2: loser,
                score: "6-3 6-4"
            )
            context.insert(winner); context.insert(loser); context.insert(match)

            let wonBet = PointBet(
                match: match,
                player: winner,
                kind: .matchWinner,
                selection: winner.name,
                stake: 25,
                payout: 50
            )
            let lostBet = PointBet(
                match: match,
                player: loser,
                kind: .matchWinner,
                selection: loser.name,
                stake: 25,
                payout: 50
            )
            #expect(BetSettlementEngine.status(for: wonBet) == .won,
                    "\(status) winner bet should resolve to .won")
            #expect(BetSettlementEngine.status(for: lostBet) == .lost,
                    "\(status) loser bet should resolve to .lost")
        }
    }

    /// Mid-match (Live, "Set 2", etc.) — most bet kinds can't settle yet,
    /// so the engine must return nil (keeping the bet `.open`) rather than
    /// guessing won/lost prematurely.
    @MainActor
    @Test func betSettlementEngineKeepsLiveBetsOpen() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let player1 = Player(externalKey: "live-p1", name: "P1", nationality: "BR", isWTA: false)
        let player2 = Player(externalKey: "live-p2", name: "P2", nationality: "AR", isWTA: false)
        let match = TennisMatch(
            externalID: "live-match",
            date: .now,
            status: "Set 2",
            isLive: true,
            player1: player1,
            player2: player2,
            score: "6-4"
        )
        context.insert(player1); context.insert(player2); context.insert(match)

        // Match-completion-dependent kinds: must stay open mid-match.
        for kind: BetKind in [.matchWinner, .finalScore, .playerPerformance, .tieBreakPlayed, .totalSets] {
            let bet = PointBet(
                match: match,
                player: player1,
                kind: kind,
                selection: player1.name,
                stake: 25,
                payout: 50,
                predictedScore: "6-4 6-4"
            )
            #expect(BetSettlementEngine.status(for: bet) == nil,
                    "Mid-match \(kind) must remain open; got \(String(describing: BetSettlementEngine.status(for: bet)))")
        }
    }

    /// Semantic correctness — for each BetKind on a clearly-resolved match,
    /// the engine must pick `.won` when the bet's selection matches the
    /// truth and `.lost` when it doesn't. Bound test data lets us assert
    /// the expected outcome explicitly, not just "anything but .open".
    @MainActor
    @Test func betSettlementEngineSemanticCorrectnessForCompletedMatches() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let winner = Player(externalKey: "sem-winner", name: "Winner", nationality: "BR", isWTA: false)
        let loser = Player(externalKey: "sem-loser", name: "Loser", nationality: "AR", isWTA: false)
        // Match: winner takes 2 straight sets, 1 tie-break played.
        let match = TennisMatch(
            externalID: "sem-correct",
            date: .now.addingTimeInterval(-3600),
            status: "Final",
            isLive: false,
            player1: winner,
            player2: loser,
            score: "6-3 7-6"
        )
        context.insert(winner); context.insert(loser); context.insert(match)

        // .matchWinner — selection = actual winner → .won; opposite → .lost.
        let winnerBet = PointBet(
            match: match, player: winner, kind: .matchWinner,
            selection: winner.name, stake: 10, payout: 20
        )
        let loserBet = PointBet(
            match: match, player: loser, kind: .matchWinner,
            selection: loser.name, stake: 10, payout: 20
        )
        #expect(BetSettlementEngine.status(for: winnerBet) == .won)
        #expect(BetSettlementEngine.status(for: loserBet) == .lost)

        // .finalScore — exact match → .won; wrong → .lost.
        let exactScoreBet = PointBet(
            match: match, player: winner, kind: .finalScore,
            selection: winner.name, stake: 10, payout: 20,
            predictedScore: "6-3 7-6"
        )
        let wrongScoreBet = PointBet(
            match: match, player: winner, kind: .finalScore,
            selection: winner.name, stake: 10, payout: 20,
            predictedScore: "6-4 6-4"
        )
        #expect(BetSettlementEngine.status(for: exactScoreBet) == .won)
        #expect(BetSettlementEngine.status(for: wrongScoreBet) == .lost)

        // .tieBreakPlayed — score 7-6 contains a tie-break, so "Sim" → .won
        // and "Não" → .lost.
        let tbYes = PointBet(
            match: match, player: winner, kind: .tieBreakPlayed,
            selection: winner.name, stake: 10, payout: 20,
            predictedScore: "Sim"
        )
        let tbNo = PointBet(
            match: match, player: winner, kind: .tieBreakPlayed,
            selection: winner.name, stake: 10, payout: 20,
            predictedScore: "Não"
        )
        #expect(BetSettlementEngine.status(for: tbYes) == .won)
        #expect(BetSettlementEngine.status(for: tbNo) == .lost)

        // .totalSets — actual = 2 sets, prediction "2" → .won; "3" → .lost.
        let twoSetsBet = PointBet(
            match: match, player: winner, kind: .totalSets,
            selection: winner.name, stake: 10, payout: 20,
            predictedScore: "2"
        )
        let threeSetsBet = PointBet(
            match: match, player: winner, kind: .totalSets,
            selection: winner.name, stake: 10, payout: 20,
            predictedScore: "3"
        )
        #expect(BetSettlementEngine.status(for: twoSetsBet) == .won)
        #expect(BetSettlementEngine.status(for: threeSetsBet) == .lost)

        // .playerPerformance with .straightSets — winner cleared every set
        // → .won. The loser obviously didn't.
        let straightSetsBet = PointBet(
            match: match, player: winner, kind: .playerPerformance,
            selection: winner.name, stake: 10, payout: 20,
            performanceRule: .straightSets
        )
        let loserStraightSetsBet = PointBet(
            match: match, player: loser, kind: .playerPerformance,
            selection: loser.name, stake: 10, payout: 20,
            performanceRule: .straightSets
        )
        #expect(BetSettlementEngine.status(for: straightSetsBet) == .won)
        #expect(BetSettlementEngine.status(for: loserStraightSetsBet) == .lost)

        // .setWinner with targetSetIndex=0 — winner took set 0 (6-3).
        let setWinnerBet = PointBet(
            match: match, player: winner, kind: .setWinner,
            selection: winner.name, stake: 10, payout: 20,
            targetSetIndex: 0
        )
        let setLoserBet = PointBet(
            match: match, player: loser, kind: .setWinner,
            selection: loser.name, stake: 10, payout: 20,
            targetSetIndex: 0
        )
        #expect(BetSettlementEngine.status(for: setWinnerBet) == .won)
        #expect(BetSettlementEngine.status(for: setLoserBet) == .lost)
    }

    /// BetSettlementEngine coverage matrix — exercise every BetKind with the
    /// shapes that matter for production. Closed matches must resolve to
    /// either .won / .lost / .void; never .open.
    @MainActor
    @Test func betSettlementEngineResolvesEveryBetKindForCompletedMatches() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let player1 = Player(externalKey: "winner", name: "Winner", nationality: "BR", isWTA: false)
        let player2 = Player(externalKey: "loser", name: "Loser", nationality: "AR", isWTA: false)
        let match = TennisMatch(
            externalID: "settle-matrix",
            date: .now.addingTimeInterval(-3600),
            status: "Final",
            isLive: false,
            serverName: player1.name,
            pointScore: "",
            gameScore: "6-3",
            player1: player1,
            player2: player2,
            score: "6-3 6-4"
        )
        context.insert(player1); context.insert(player2); context.insert(match)

        for kind in BetKind.allCases {
            let bet = PointBet(
                match: match,
                player: player1,
                kind: kind,
                selection: player1.name,
                stake: 10,
                payout: 20
            )
            let status = BetSettlementEngine.status(for: bet)
            // A closed match must not leave the kind in .open — that would
            // mean the engine forgot a case path.
            if let status {
                #expect(status != .open, "BetKind \(kind) returned .open for a completed match")
            }
        }
    }

    /// AccountDeletionService.deleteAllUserData (async) drops every user-owned
    /// row and clears the user-scoped UserDefaults keys. Idempotent.
    @MainActor
    @Test func accountDeletionServiceWipesUserData() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let profile = UserProfile(displayName: "Tester", points: 100)
        let player = Player(name: "Some Player", nationality: "BR", isWTA: false, isFavorite: true)
        let match = TennisMatch(externalID: "delete-target", date: .now, isFavorite: true)
        let bet = PointBet(
            match: match,
            player: player,
            kind: .matchWinner,
            selection: player.name,
            stake: 10,
            payout: 20
        )
        let poll = MatchPoll(match: match, question: "x?", optionOne: "a", optionTwo: "b")
        let post = SocialPost(match: match, authorName: "Tester", body: "hello")

        context.insert(profile); context.insert(player); context.insert(match)
        context.insert(bet); context.insert(poll); context.insert(post)
        try context.save()

        let summary = try await AccountDeletionService.deleteAllUserData(context: context, cloudBackend: nil)
        #expect(summary.profiles == 1)
        #expect(summary.bets == 1)
        #expect(summary.socialPosts == 1)
        #expect(summary.polls == 1)
        #expect(summary.unfavoritedPlayers == 1)
        #expect(summary.unfavoritedMatches == 1)

        // Idempotent: a second run reports zero deletions, doesn't throw.
        let again = try await AccountDeletionService.deleteAllUserData(context: context, cloudBackend: nil)
        #expect(again.totalDeleted == 0)
    }

    /// extractMatchDictionaries must refuse to walk a payload whose breadth
    /// at any level exceeds `maxPayloadBreadth`. Returns [] without crashing.
    @Test func extractMatchDictionariesRefusesPathologicalBreadth() throws {
        // Single object at depth 1 with 5000 sibling keys, far above the 1000 cap.
        var inner: [String: Any] = [:]
        for i in 0..<5000 {
            inner["k\(i)"] = "v\(i)"
        }
        let json: Any = ["payload": inner]
        let encoded = try JSONSerialization.data(withJSONObject: json)
        let extracted = (try? LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)) ?? []
        #expect(extracted.isEmpty,
                "Pathological breadth payload should yield no match dictionaries — got \(extracted.count)")
    }

    /// Array fan-out variant of the breadth cap — a single array with 5000
    /// nested objects should bail out the same way as a wide dictionary.
    @Test func extractMatchDictionariesRefusesPathologicalArrayBreadth() throws {
        let inner: [[String: Any]] = (0..<5000).map { ["dummy": $0] }
        let encoded = try JSONSerialization.data(withJSONObject: inner)
        let extracted = (try? LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)) ?? []
        #expect(extracted.isEmpty,
                "Pathological array breadth should yield no match dictionaries — got \(extracted.count)")
    }

    /// Stack guard: nesting beyond `maxDepth` must return [] instead of
    /// recursing forever / blowing the stack. Builds a JSON object whose
    /// `nested` keys go 40 levels deep (above the default 32 cap).
    @Test func extractMatchDictionariesRefusesPathologicalDepth() throws {
        var deepest: Any = ["match_key": "real-match"]
        for _ in 0..<40 {
            deepest = ["nested": deepest]
        }
        let encoded = try JSONSerialization.data(withJSONObject: deepest)
        let extracted = (try? LiveMatchWebSocketService.matchDictionaries(
            fromFrameData: encoded,
            maxDepth: 32
        )) ?? []
        // The real match is buried below maxDepth — extractor walks `result`/
        // `values` but stops before reaching the nest. Either we get nothing
        // OR we get only entries above the cap; never an unbounded recursion.
        #expect(extracted.count <= 1,
                "Deep payload must respect maxDepth; got \(extracted.count) entries")
    }

    /// Happy path sanity: a normal API Tennis-shaped payload still returns
    /// the embedded match dictionary even with the new caps in place.
    @Test func extractMatchDictionariesAcceptsRealisticPayload() throws {
        let payload: [String: Any] = [
            "success": 1,
            "result": [
                [
                    "event_key": "12345",
                    "event_first_player": "Alcaraz",
                    "event_second_player": "Sinner",
                    "event_status": "Set 2"
                ]
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let extracted = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)
        #expect(extracted.count == 1)
        #expect(extracted.first?["event_key"] as? String == "12345")
    }

    /// BackgroundSyncScheduler.decideBackgroundSync truth table — the pure
    /// decision function is what actually drives the BGTaskScheduler handler.
    /// Exercising it isolates the priority rules from the BG runtime, which
    /// can't be triggered from unit tests.
    @Test func backgroundSyncDecisionSkipsWhenLiveStreamActive() {
        let decision = BackgroundSyncScheduler.decideBackgroundSync(
            liveStreamActive: true,
            containerAvailable: true,
            shouldSyncLiveMatches: true,
            shouldSyncTournaments: true
        )
        #expect(decision == .skip(reason: .liveStreamActive),
                "WebSocket must be the single writer when active; BG sync must back off")
    }

    @Test func backgroundSyncDecisionSkipsWhenContainerMissing() {
        let decision = BackgroundSyncScheduler.decideBackgroundSync(
            liveStreamActive: false,
            containerAvailable: false,
            shouldSyncLiveMatches: true,
            shouldSyncTournaments: true
        )
        #expect(decision == .skip(reason: .noContainer))
    }

    @Test func backgroundSyncDecisionSkipsWhenNothingScheduled() {
        let decision = BackgroundSyncScheduler.decideBackgroundSync(
            liveStreamActive: false,
            containerAvailable: true,
            shouldSyncLiveMatches: false,
            shouldSyncTournaments: false
        )
        #expect(decision == .skip(reason: .noWorkScheduled))
    }

    @Test func backgroundSyncDecisionRunsSubsetWhenSomeAreScheduled() {
        let decision = BackgroundSyncScheduler.decideBackgroundSync(
            liveStreamActive: false,
            containerAvailable: true,
            shouldSyncLiveMatches: true,
            shouldSyncTournaments: false
        )
        #expect(decision == .run(tasks: [.liveMatches]))
    }

    @Test func backgroundSyncDecisionRunsEverythingWhenAllScheduled() {
        let decision = BackgroundSyncScheduler.decideBackgroundSync(
            liveStreamActive: false,
            containerAvailable: true,
            shouldSyncLiveMatches: true,
            shouldSyncTournaments: true
        )
        #expect(decision == .run(tasks: [.liveMatches, .tournaments]))
    }

    /// SocialEventGenerator emits a stable, dedupeable feed for a live match.
    /// Re-running with the same existing-event-keys must yield zero new events.
    @MainActor
    @Test func socialEventGeneratorEmitsAndDedupesLiveMatchEvents() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let p1 = Player(externalKey: "se-p1", name: "Alpha", nationality: "BR", isWTA: false)
        let p2 = Player(externalKey: "se-p2", name: "Beta", nationality: "AR", isWTA: false)
        let match = TennisMatch(
            externalID: "se-live",
            date: .now,
            status: "Set 2",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: p1.name,
            pointScore: "30-15",
            gameScore: "4-3",
            player1: p1,
            player2: p2,
            score: "6-4"
        )
        context.insert(p1); context.insert(p2); context.insert(match)

        let firstPass = SocialEventGenerator.events(for: [match], existingEventKeys: [])
        #expect(!firstPass.isEmpty, "Live match must yield at least the live + last-set events")

        // Every event must be authored by the system label, not a user.
        #expect(firstPass.allSatisfy { $0.authorName == SocialEventGenerator.systemAuthorName })

        // Second pass with the same keys already known — should produce nothing.
        let knownKeys = Set(firstPass.map(\.id))
        let secondPass = SocialEventGenerator.events(for: [match], existingEventKeys: knownKeys)
        #expect(secondPass.isEmpty, "Dedupe must filter every event whose key was already seen")
    }

    /// Completed match should always yield a `:final:` event whose body
    /// echoes the score — this is what feeds the post-match recap card.
    @MainActor
    @Test func socialEventGeneratorEmitsFinalEventOnCompletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let p1 = Player(externalKey: "se-fp1", name: "Champ", nationality: "BR", isWTA: false)
        let p2 = Player(externalKey: "se-fp2", name: "Other", nationality: "AR", isWTA: false)
        let match = TennisMatch(
            externalID: "se-final",
            date: .now.addingTimeInterval(-3600),
            status: "Final",
            isLive: false,
            lastUpdatedAt: .now,
            player1: p1,
            player2: p2,
            score: "6-3 6-4"
        )
        context.insert(p1); context.insert(p2); context.insert(match)

        let events = SocialEventGenerator.events(for: [match], existingEventKeys: [])
        let finalEvent = events.first { $0.id.contains(":final:") }
        #expect(finalEvent != nil, "Completed match must emit a final-recap event")
        #expect(finalEvent?.body.contains("6-3 6-4") == true)
    }

    /// SocialRetentionService prunes posts and polls older than 60 days and
    /// leaves recent ones alone. Idempotent on a second run.
    @MainActor
    @Test func socialRetentionPrunesContentBeyondWindow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_700_000_000) // stable anchor

        let fresh = SocialPost(authorName: "Fresh", body: "hi")
        fresh.createdAt = now.addingTimeInterval(-3600) // 1h ago — keep
        let stale = SocialPost(authorName: "Stale", body: "old")
        stale.createdAt = now.addingTimeInterval(-90 * 86_400) // 90d ago — prune

        let freshPoll = MatchPoll(question: "Now?", optionOne: "a", optionTwo: "b")
        freshPoll.createdAt = now.addingTimeInterval(-86_400)
        let stalePoll = MatchPoll(question: "Old?", optionOne: "a", optionTwo: "b")
        stalePoll.createdAt = now.addingTimeInterval(-120 * 86_400)

        context.insert(fresh); context.insert(stale)
        context.insert(freshPoll); context.insert(stalePoll)
        try context.save()

        let summary = SocialRetentionService.pruneStale(in: context, now: now)
        #expect(summary.posts == 1, "Only the 90-day-old post must be pruned")
        #expect(summary.polls == 1, "Only the 120-day-old poll must be pruned")

        // Idempotent: second run finds nothing to prune.
        let again = SocialRetentionService.pruneStale(in: context, now: now)
        #expect(again.totalRemoved == 0)

        // Fresh content survived.
        let remainingPosts = try context.fetch(FetchDescriptor<SocialPost>())
        let remainingPolls = try context.fetch(FetchDescriptor<MatchPoll>())
        #expect(remainingPosts.count == 1)
        #expect(remainingPolls.count == 1)
    }

    /// MatchWidgetSnapshotStore round-trips a live match through the App Group
    /// store. After `replaceLiveMatches`, the persisted blob must decode back
    /// to a snapshot referencing the same player names and score.
    @MainActor
    @Test func matchWidgetSnapshotStoreEncodesAndPersistsLiveMatch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let p1 = Player(externalKey: "ws-p1", name: "Widget1", nationality: "BR", isWTA: false)
        let p2 = Player(externalKey: "ws-p2", name: "Widget2", nationality: "AR", isWTA: false)
        let match = TennisMatch(
            externalID: "widget-live",
            date: .now,
            status: "Set 1",
            isLive: true,
            serverName: p1.name,
            player1: p1,
            player2: p2,
            score: "3-2"
        )
        context.insert(p1); context.insert(p2); context.insert(match)
        try context.save()

        // Clean prior state from any earlier test run.
        let store = MatchWidgetSnapshotStore.shared
        store.replaceLiveMatches([], rankings: [])

        store.replaceLiveMatches([match], rankings: [])

        // Read back from the App Group store via the SAME key the widget uses.
        let suite = UserDefaults(suiteName: "group.ALTB.Match-Point") ?? .standard
        let data = try #require(suite.data(forKey: "match-point.widget.match-snapshots"))
        let decoded = try #require(try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let entry = try #require(decoded.first { ($0["id"] as? String) == "widget-live" })
        #expect((entry["player1Name"] as? String) == "Widget1")
        #expect((entry["player2Name"] as? String) == "Widget2")
        #expect((entry["isLive"] as? Bool) == true)

        // Cleanup so we don't pollute subsequent test runs.
        store.replaceLiveMatches([], rankings: [])
    }

    @Test func liveScoreSnapshotIgnoresMissingFieldsDuringCrossCheck() {
        let websocket = LiveScoreSnapshot(
            score: "6-4 2-1",
            gameScore: "2-1",
            pointScore: "30-15",
            serverName: "Jannik Sinner"
        )
        let rest = LiveScoreSnapshot(
            score: "6-4 2-1",
            gameScore: "",
            pointScore: "30-15",
            serverName: ""
        )

        #expect(websocket.materiallyMatches(rest))
    }

    @Test func liveScoreSnapshotDetectsMaterialScoreConflict() {
        let websocket = LiveScoreSnapshot(
            score: "6-4 2-1",
            gameScore: "2-1",
            pointScore: "30-15",
            serverName: "Jannik Sinner"
        )
        let rest = LiveScoreSnapshot(
            score: "6-4 2-2",
            gameScore: "2-2",
            pointScore: "0-0",
            serverName: "Carlos Alcaraz"
        )

        #expect(websocket.materiallyMatches(rest) == false)
    }

    @MainActor
    @Test func liveDataConfidenceMarksOldLiveMatchAsStale() {
        let match = TennisMatch(
            date: .now,
            status: "Set 5",
            isLive: true,
            lastUpdatedAt: Date(timeIntervalSince1970: 100),
            score: "6-4 4-6 2-2"
        )

        let confidence = LiveDataConfidence.bestEffort(
            for: match,
            serviceConfidence: nil,
            now: Date(timeIntervalSince1970: 140)
        )

        #expect(confidence.status == .stale)
    }

    /// Feature extractor must set the live/favorite/top10 signals correctly and
    /// compute proximity so the ranker sees the same picture the UI does.
    @MainActor
    @Test func feedRankerFeatureExtractorCapturesKeySignals() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let sinner = Player(name: "Jannik Sinner", nationality: "ITA", isWTA: false, isFavorite: true)
        let alcaraz = Player(name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        [sinner, alcaraz].forEach(context.insert)

        let tournament = Tournament(
            name: "Wimbledon",
            city: "London",
            country: "UK",
            surface: "Grass",
            tour: .atp,
            startDate: .now,
            endDate: .now.addingTimeInterval(3600 * 24 * 14)
        )
        context.insert(tournament)

        let match = TennisMatch(
            date: .now.addingTimeInterval(3600 * 2),
            status: "Scheduled",
            isLive: false,
            tournament: tournament,
            player1: sinner,
            player2: alcaraz
        )
        context.insert(match)

        let rankings = [
            RankingEntry(player: sinner, rank: 1, points: 10_000, tour: .atp),
            RankingEntry(player: alcaraz, rank: 2, points: 9_000, tour: .atp)
        ]
        rankings.forEach(context.insert)
        try context.save()

        var rankLookup: [UUID: Int] = [:]
        for entry in rankings { rankLookup[entry.player!.id] = entry.rank }

        let features = FeedRankerFeatureExtractor.features(
            for: match,
            rankByPlayerID: rankLookup,
            behavior: nil
        )

        #expect(features.hasFavoritePlayer == 1.0)
        #expect(features.hasTop10Player == 1.0)
        #expect(features.isATP == 1.0)
        #expect(features.isWTA == 0.0)
        #expect(features.isUpcoming == 1.0)
        #expect(features.proximity > 0.9)  // 2h out → very close to 1.0
    }

    /// Training with repeated positives on a distinctive feature should shift
    /// the corresponding weight upward — this is the invariant the ranker
    /// depends on to personalize the feed over time.
    @MainActor
    @Test func feedRankerLearnsFromRepeatedPositives() throws {
        let defaults = UserDefaults(suiteName: "ranker-test-\(UUID().uuidString)")!
        let model = FeedRankerModel(defaults: defaults, storageKey: "ranker-test-key")

        var positive = FeedRankerFeatures.zero
        positive.hasFavoritePlayer = 1
        positive.isATP = 1

        var negative = FeedRankerFeatures.zero
        negative.isWTA = 1

        let initialATPWeight = model.weights.weights[11]  // isATP index

        for _ in 0..<20 {
            model.train(samples: [
                (positive, 1.0),
                (negative, 0.0)
            ])
        }

        #expect(model.weights.samplesSeen == 40)
        #expect(model.weights.weights[11] > initialATPWeight)  // isATP learned upward
        #expect(model.weights.weights[12] < 0)                 // isWTA learned downward
        #expect(model.weights.isWarmedUp)
    }

    /// A cold ranker (below warmup threshold) must return 0 boost so cold-start
    /// installs don't distort the feed with untrained predictions.
    @MainActor
    @Test func feedRankerBoostIsZeroBeforeWarmup() throws {
        let defaults = UserDefaults(suiteName: "ranker-cold-\(UUID().uuidString)")!
        let model = FeedRankerModel(defaults: defaults, storageKey: "ranker-cold-key")

        var strong = FeedRankerFeatures.zero
        strong.isLive = 1
        strong.hasFavoritePlayer = 1

        #expect(model.weights.samplesSeen == 0)
        #expect(model.relevanceBoost(for: strong) == 0)
    }

    /// Grand Slam Final scenario should award 2000 pts to the assumed winner
    /// and promote them past a rival who currently leads by less than that gap.
    @MainActor
    @Test func scenarioProjectionPromotesGrandSlamWinnerAcrossTheLeader() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let sinner = Player(name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let alcaraz = Player(name: "Carlos Alcaraz", nationality: "ESP", isWTA: false)
        let djokovic = Player(name: "Novak Djokovic", nationality: "SRB", isWTA: false)
        [sinner, alcaraz, djokovic].forEach(context.insert)

        let entries = [
            RankingEntry(player: sinner, rank: 1, points: 10_000, tour: .atp),
            RankingEntry(player: alcaraz, rank: 2, points: 8_500, tour: .atp),
            RankingEntry(player: djokovic, rank: 3, points: 7_200, tour: .atp)
        ]
        entries.forEach(context.insert)
        try context.save()

        let assumption = RankingScenarioAssumption(
            id: UUID(),
            round: "Final",
            winnerID: alcaraz.id,
            winnerName: alcaraz.name,
            loserID: sinner.id,
            loserName: sinner.name,
            tournamentName: "Wimbledon",
            tournamentExternalKey: "wimbledon",
            tournamentIsMajor: true
        )

        let projections = RankingProjectionEngine.projectScenario(
            assumptions: [assumption],
            rankings: entries
        )

        let alcarazProjection = projections.first(where: { $0.id == alcaraz.id })
        #expect(alcarazProjection?.projectedPoints == 10_500)
        #expect(alcarazProjection?.projectedRank == 1)
        #expect(alcarazProjection?.rankDelta == 1)

        let sinnerProjection = projections.first(where: { $0.id == sinner.id })
        #expect(sinnerProjection?.projectedRank == 2)
        #expect(sinnerProjection?.rankDelta == -1)
    }

    /// Compounding SF + Final wins on a Masters 1000 should credit both awards
    /// (finalist 650 + winner 1000 = 1650) to the same player.
    @MainActor
    @Test func scenarioProjectionCompoundsMultipleRoundsForSamePlayer() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let zverev = Player(name: "Alexander Zverev", nationality: "GER", isWTA: false)
        let medvedev = Player(name: "Daniil Medvedev", nationality: "RUS", isWTA: false)
        [zverev, medvedev].forEach(context.insert)

        let entries = [
            RankingEntry(player: zverev, rank: 4, points: 6_000, tour: .atp),
            RankingEntry(player: medvedev, rank: 5, points: 5_500, tour: .atp)
        ]
        entries.forEach(context.insert)
        try context.save()

        let semi = RankingScenarioAssumption(
            id: UUID(),
            round: "Semi-final",
            winnerID: zverev.id,
            winnerName: zverev.name,
            loserID: medvedev.id,
            loserName: medvedev.name,
            tournamentName: "Rolex Paris Masters 1000",
            tournamentExternalKey: nil,
            tournamentIsMajor: false
        )
        let final = RankingScenarioAssumption(
            id: UUID(),
            round: "Final",
            winnerID: zverev.id,
            winnerName: zverev.name,
            loserID: nil,
            loserName: "TBD",
            tournamentName: "Rolex Paris Masters 1000",
            tournamentExternalKey: nil,
            tournamentIsMajor: false
        )

        let projections = RankingProjectionEngine.projectScenario(
            assumptions: [semi, final],
            rankings: entries
        )

        let zverevProjection = projections.first(where: { $0.id == zverev.id })
        #expect(zverevProjection?.pointsDelta == 1_650)
        #expect(zverevProjection?.projectedPoints == 7_650)
    }

    /// Applying no assumptions must return no projections — the sheet's empty
    /// state depends on this invariant.
    @MainActor
    @Test func scenarioProjectionReturnsEmptyWhenNoAssumptions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let player = Player(name: "Iga Swiatek", nationality: "POL", isWTA: true)
        context.insert(player)
        let entry = RankingEntry(player: player, rank: 1, points: 10_000, tour: .wta)
        context.insert(entry)
        try context.save()

        let projections = RankingProjectionEngine.projectScenario(
            assumptions: [],
            rankings: [entry]
        )
        #expect(projections.isEmpty)
    }

    /// Empty / non-dict / scalar payloads should yield [] gracefully.
    @Test func extractMatchDictionariesHandlesNonMatchPayloads() throws {
        // Bare scalar (number) wrapped as JSON is valid but carries no match.
        let scalarData = Data("42".utf8)
        let scalar = (try? LiveMatchWebSocketService.matchDictionaries(fromFrameData: scalarData)) ?? []
        #expect(scalar.isEmpty)

        // Empty object.
        let emptyObject = try JSONSerialization.data(withJSONObject: [String: Any]())
        let empty = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: emptyObject)
        #expect(empty.isEmpty)

        // Empty array.
        let emptyArrayData = try JSONSerialization.data(withJSONObject: [Any]())
        let emptyArray = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: emptyArrayData)
        #expect(emptyArray.isEmpty)
    }

    // MARK: - Accessibility label builders
    //
    // These guard the VoiceOver phrasing of the two densest surfaces —
    // scoreboard rows and the live-tracker per-player row. If we ever
    // regress the grouping (e.g. drop `.accessibilityElement(children: .ignore)`
    // or accidentally revert to reading each set cell as a bare digit) the
    // announced string changes shape and these tests fail loudly.

    @Test func scoreboardRowLabelReadsPlayerFollowedByEachSet() {
        let label = MatchScoreboardView.rowAccessibilityLabel(
            name: "Alcaraz",
            setValues: ["6", "3", "6"]
        )
        #expect(label.contains("Alcaraz"))
        #expect(label.contains("set 1: 6 games"))
        #expect(label.contains("set 2: 3 games"))
        #expect(label.contains("set 3: 6 games"))
        // Grouped phrase must not devolve into a bare digit list.
        #expect(label.hasSuffix("6 games"))
    }

    @Test func scoreboardRowLabelHandlesEmptySets() {
        let label = MatchScoreboardView.rowAccessibilityLabel(
            name: "Sinner",
            setValues: []
        )
        #expect(label == "Sinner. Sem sets registrados")
    }

    @Test func scoreboardRowLabelHandlesBlankPlayerName() {
        let label = MatchScoreboardView.rowAccessibilityLabel(
            name: "   ",
            setValues: ["6", "4"]
        )
        #expect(label.hasPrefix("Jogador."))
    }

    @Test func liveTrackerRowLabelMentionsServeAndFavorite() {
        let label = LiveTrackerView.liveScoreboardRowAccessibilityLabel(
            name: "Carlos Alcaraz",
            isServing: true,
            isFavorite: true,
            setValues: ["6", "3"]
        )
        #expect(label.contains("Carlos Alcaraz"))
        #expect(label.contains("favorito"))
        #expect(label.contains("sacando"))
        #expect(label.contains("set 1: 6 games"))
        #expect(label.contains("set 2: 3 games"))
    }

    @Test func liveTrackerRowLabelOmitsServeAndFavoriteWhenAbsent() {
        let label = LiveTrackerView.liveScoreboardRowAccessibilityLabel(
            name: "Jannik Sinner",
            isServing: false,
            isFavorite: false,
            setValues: ["6", "4"]
        )
        #expect(label.contains("Jannik Sinner"))
        #expect(!label.contains("favorito"))
        #expect(!label.contains("sacando"))
        #expect(label.contains("set 1: 6 games"))
    }

    @Test func liveTrackerRowLabelReadsSetlessRowGracefully() {
        let label = LiveTrackerView.liveScoreboardRowAccessibilityLabel(
            name: "TBD",
            isServing: false,
            isFavorite: false,
            setValues: []
        )
        #expect(label.contains("TBD"))
        #expect(label.contains("sem placar"))
    }

    @Test func liveTrackerRowLabelReadsPlaceholderDashAsNoScore() {
        let label = LiveTrackerView.liveScoreboardRowAccessibilityLabel(
            name: "Coco Gauff",
            isServing: false,
            isFavorite: true,
            setValues: ["–"]
        )
        #expect(label.contains("Coco Gauff"))
        #expect(label.contains("favorito"))
        #expect(label.contains("sem placar"))
    }

    // MARK: - Provider health tracker
    //
    // These pin the state machine consumed by the diagnostics view — success,
    // failure, latency rolling average, consecutive-failure escalation, and
    // fallback log ordering. A regression here shows up as a wrong health
    // pill in Provider Diagnostics.

    @MainActor
    @Test func providerHealthTrackerStartsIdleForAllScopes() {
        let tracker = ProviderHealthTracker()
        for scope in ProviderHealthTracker.Scope.allCases {
            let snapshot = tracker.snapshot(for: scope)
            #expect(snapshot.totalCalls == 0)
            #expect(snapshot.health == .idle)
        }
        #expect(tracker.overallRestHealth == .idle)
    }

    @MainActor
    @Test func providerHealthTrackerFlipsToHealthyAfterSuccessAndLatencyIsRecorded() {
        let tracker = ProviderHealthTracker()
        tracker.recordSuccess(scope: .liveMatches, latencyMillis: 120)
        tracker.recordSuccess(scope: .liveMatches, latencyMillis: 180)
        let snapshot = tracker.snapshot(for: .liveMatches)
        #expect(snapshot.successCount == 2)
        #expect(snapshot.failureCount == 0)
        #expect(snapshot.averageLatencyMillis == 150)
        #expect(snapshot.health == .healthy)
    }

    @MainActor
    @Test func providerHealthTrackerFlipsToFailingAfterConsecutiveFailures() {
        let tracker = ProviderHealthTracker()
        let error = APIError(message: "HTTP 502")
        for _ in 0..<3 {
            tracker.recordFailure(scope: .rankings, error: error)
        }
        let snapshot = tracker.snapshot(for: .rankings)
        #expect(snapshot.consecutiveFailures == 3)
        if case .failing = snapshot.health {
            // Pass — health tag reads as failing with a reason.
        } else {
            Issue.record("Expected .failing but got \(snapshot.health)")
        }
        if case .failing = tracker.overallRestHealth {
            // Overall REST health should reflect this scope.
        } else {
            Issue.record("Overall REST health should escalate to failing")
        }
    }

    @MainActor
    @Test func providerHealthTrackerDegradesWhenSuccessRateBelowThreshold() {
        let tracker = ProviderHealthTracker()
        // 1 success then 1 failure: 50% success rate but no consecutive
        // failure streak. Then compensate with another success so we don't
        // trip the "last observation was a failure" rule — we want the pure
        // success-rate degraded state.
        tracker.recordSuccess(scope: .tournaments, latencyMillis: 100)
        tracker.recordFailure(scope: .tournaments, error: APIError(message: "boom"))
        tracker.recordSuccess(scope: .tournaments, latencyMillis: 100)
        let snapshot = tracker.snapshot(for: .tournaments)
        // 2 success + 1 failure = 66% success rate < 90% threshold.
        if case .degraded = snapshot.health {
            // Pass.
        } else {
            Issue.record("Expected .degraded but got \(snapshot.health)")
        }
    }

    @MainActor
    @Test func providerHealthTrackerDegradesOnHighLatency() {
        let tracker = ProviderHealthTracker()
        // Slow but still successful. Should be degraded because latency > 2.5s.
        for _ in 0..<3 {
            tracker.recordSuccess(scope: .fixtures, latencyMillis: 3_000)
        }
        let snapshot = tracker.snapshot(for: .fixtures)
        if case .degraded = snapshot.health {
            // Pass.
        } else {
            Issue.record("Expected .degraded due to high latency but got \(snapshot.health)")
        }
    }

    @MainActor
    @Test func providerHealthTrackerRecoversToHealthyAfterFailureThenSuccessStreak() {
        let tracker = ProviderHealthTracker()
        tracker.recordFailure(scope: .liveMatches, error: APIError(message: "timeout"))
        // Ten successes should push the failure past the 90% threshold and
        // reset consecutive failures.
        for _ in 0..<10 {
            tracker.recordSuccess(scope: .liveMatches, latencyMillis: 200)
        }
        let snapshot = tracker.snapshot(for: .liveMatches)
        #expect(snapshot.consecutiveFailures == 0)
        // 10 / 11 ≈ 91% → healthy.
        #expect(snapshot.health == .healthy)
    }

    @MainActor
    @Test func providerHealthTrackerRecordsFallbackLogNewestFirst() {
        let tracker = ProviderHealthTracker()
        tracker.recordFallback(scope: .tournaments, reason: "primeiro")
        tracker.recordFallback(scope: .players, reason: "segundo")
        #expect(tracker.fallbackLog.count == 2)
        #expect(tracker.fallbackLog.first?.reason == "segundo")
        #expect(tracker.fallbackLog.last?.reason == "primeiro")
    }

    @MainActor
    @Test func providerHealthTrackerCapsFallbackLogAt20Entries() {
        let tracker = ProviderHealthTracker()
        for i in 0..<30 {
            tracker.recordFallback(scope: .fixtures, reason: "evento \(i)")
        }
        #expect(tracker.fallbackLog.count == 20)
        // Most recent must be first.
        #expect(tracker.fallbackLog.first?.reason == "evento 29")
    }

    @MainActor
    @Test func providerHealthTrackerWebSocketFrameFlipsScopeHealthy() {
        let tracker = ProviderHealthTracker()
        tracker.recordWebSocketFrame()
        #expect(tracker.webSocket.framesReceived == 1)
        #expect(tracker.webSocket.isStreaming)
        #expect(tracker.snapshot(for: .webSocket).health == .healthy)
    }

    @MainActor
    @Test func providerHealthTrackerWebSocketStallCountsAndLogsFallback() {
        let tracker = ProviderHealthTracker()
        tracker.recordWebSocketStall(reason: "sem frame por 30s")
        #expect(tracker.webSocket.stallEvents == 1)
        #expect(tracker.fallbackLog.first?.reason.contains("Stall") == true)
    }

    @MainActor
    @Test func providerHealthTrackerRollingLatencyKeepsLast10Samples() {
        let tracker = ProviderHealthTracker()
        for i in 1...15 {
            // Latencies 100, 200, 300 ..., 1500. Only the last 10 samples
            // (600–1500 → average 1050) should contribute to the rolling avg.
            tracker.recordSuccess(scope: .odds, latencyMillis: i * 100)
        }
        let snapshot = tracker.snapshot(for: .odds)
        #expect(snapshot.averageLatencyMillis == 1050)
    }

    @MainActor
    @Test func providerHealthTrackerResetClearsEverything() {
        let tracker = ProviderHealthTracker()
        tracker.recordSuccess(scope: .liveMatches, latencyMillis: 100)
        tracker.recordFailure(scope: .rankings, error: APIError(message: "x"))
        tracker.recordFallback(scope: .tournaments, reason: "y")
        tracker.recordWebSocketFrame()
        tracker.reset()
        #expect(tracker.fallbackLog.isEmpty)
        #expect(tracker.webSocket.framesReceived == 0)
        for scope in ProviderHealthTracker.Scope.allCases {
            #expect(tracker.snapshot(for: scope).totalCalls == 0)
        }
    }

    // MARK: - Real-shaped API Tennis fixture parsing
    //
    // These fixtures mirror the exact shapes API Tennis returns for each
    // documented method. The point is not to hit the network — it's to prove
    // our decoding survives real-world quirks (numeric IDs as strings, dashes
    // in scores, missing tournament keys, nested point-by-point arrays).

    @Test func apiTennisTournamentDTODecodesRealPayloadShape() throws {
        let json = """
        {
          "success": 1,
          "result": [
            {
              "tournament_key": 3,
              "tournament_name": "Australian Open",
              "tournament_location": "Melbourne",
              "country_name": "Australia",
              "tournament_surface": "Hard",
              "tournament_type": "ATP",
              "tournament_date_start": "2026-01-14",
              "tournament_date_end": "2026-01-28"
            },
            {
              "tournament_key": "wta-italian-open",
              "tournament_name": "Italian Open",
              "tournament_location": "Roma",
              "country_name": "Italy",
              "tournament_surface": "Clay",
              "tournament_type": "WTA",
              "tournament_date_start": "2026-05-06",
              "tournament_date_end": "2026-05-19"
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(APIEnvelope<[APITournament]>.self, from: data)
        let tournaments = (envelope.result ?? []).map(TournamentDTO.init)
        #expect(tournaments.count == 2)
        #expect(tournaments[0].id == "3")
        #expect(tournaments[0].name == "Australian Open")
        #expect(tournaments[0].surface == "Hard")
        #expect(tournaments[1].id == "wta-italian-open")
        #expect(tournaments[1].tour == "WTA")
    }

    @Test func apiTennisStandingDTODecodesAndProducesRankingEntries() throws {
        // Uses the snake_case field names the app decodes with
        // `keyDecodingStrategy = .convertFromSnakeCase` (matches
        // `APIStanding.playerName`/`countryName` etc.).
        let json = """
        {
          "success": 1,
          "result": [
            {
              "place": "1",
              "player_name": "Jannik Sinner",
              "player_key": 10420,
              "movement": "same",
              "country_name": "Italy",
              "points": "11330",
              "league": "ATP"
            },
            {
              "place": "2",
              "player_name": "Carlos Alcaraz",
              "player_key": "10421",
              "movement": "up",
              "country_name": "Spain",
              "points": "9950",
              "league": "ATP"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<[APIStanding]>.self, from: Data(json.utf8))
        let standings = envelope.result ?? []
        #expect(standings.count == 2)
        #expect(standings[0].playerKey.value == "10420")
        #expect(standings[0].playerName == "Jannik Sinner")
        #expect(standings[0].place.value == "1")
        #expect(standings[0].points.value == "11330")
        #expect(standings[0].countryName == "Italy")
    }

    @Test func apiTennisLiveMatchDTOCarriesServeGameAndPointFields() throws {
        let json = """
        {
          "success": 1,
          "result": [
            {
              "event_key": 458123,
              "event_date": "2026-08-14",
              "event_time": "14:00",
              "tournament_key": 4123,
              "tournament_name": "Cincinnati Masters",
              "event_first_player": "Carlos Alcaraz",
              "first_player_key": 10421,
              "event_second_player": "Jannik Sinner",
              "second_player_key": 10420,
              "event_final_result": "6-4 3-2",
              "event_game_result": "3-2",
              "event_status": "Set 2",
              "event_serve": "First Player",
              "event_live": "1",
              "event_first_player_point": "40",
              "event_second_player_point": "30",
              "point_score": "40-30",
              "point_winner": "First Player",
              "country_name": "USA",
              "scores": [
                { "score_first": "6", "score_second": "4", "score_set": "1" },
                { "score_first": "3", "score_second": "2", "score_set": "2" }
              ],
              "pointbypoint": []
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<[APILiveMatch]>.self, from: Data(json.utf8))
        let live = envelope.result ?? []
        #expect(live.count == 1)
        let match = try #require(live.first)
        #expect(match.eventKey.value == "458123")
        #expect(match.firstPlayerKey?.value == "10421")
        #expect(match.eventFirstPlayer == "Carlos Alcaraz")
        #expect(match.eventStatus == "Set 2")
        #expect(match.eventGameResult == "3-2")
        #expect(match.pointScore == "40-30")
        #expect(match.eventFirstPlayerPoint?.value == "40")
        #expect(match.eventSecondPlayerPoint?.value == "30")
        #expect(match.eventLive?.value == "1")
        #expect(match.scores?.count == 2)
    }

    @Test func apiTennisFixtureAndScoresDecodeWithMissingTournamentKey() throws {
        // Fixture without a tournament_key still needs to decode — providers
        // occasionally omit it for exhibition or qualifier matches.
        let json = """
        {
          "success": 1,
          "result": [
            {
              "event_key": 999,
              "event_date": "2026-08-15",
              "event_time": "09:00",
              "event_first_player": "Beatriz Haddad Maia",
              "event_second_player": "Iga Swiatek",
              "event_final_result": "-",
              "event_game_result": "-",
              "event_status": "Scheduled",
              "country_name": "Brazil"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<[APIFixture]>.self, from: Data(json.utf8))
        let fixtures = envelope.result ?? []
        #expect(fixtures.count == 1)
        #expect(fixtures.first?.tournamentKey == nil)
        #expect(fixtures.first?.eventFirstPlayer == "Beatriz Haddad Maia")
    }

    @Test func apiTennisPointByPointFixtureDecodesNestedPoints() throws {
        let json = """
        {
          "success": 1,
          "result": [
            {
              "event_key": 501,
              "event_first_player": "Carlos Alcaraz",
              "event_second_player": "Jannik Sinner",
              "event_status": "Set 2",
              "event_serve": "First Player",
              "pointbypoint": [
                {
                  "set_number": "Set 1",
                  "number_game": "3",
                  "player_served": "First Player",
                  "serve_winner": "First Player",
                  "score": "3-0",
                  "points": [
                    { "number_point": "1", "score": "15 - 0", "break_point": "", "set_point": "", "match_point": "" },
                    { "number_point": "2", "score": "30 - 0", "break_point": "", "set_point": "", "match_point": "" }
                  ]
                }
              ]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<[APILiveMatch]>.self, from: Data(json.utf8))
        let match = try #require(envelope.result?.first)
        let games = try #require(match.pointByPoint)
        #expect(games.count == 1)
        #expect(games[0].playerServed == "First Player")
        #expect(games[0].points?.count == 2)
        #expect(games[0].points?.first?.score == "15 - 0")
    }

    @Test func webSocketFrameParserExtractsFlatArrayOfDictionaries() throws {
        // Real API Tennis WebSocket frames sometimes deliver a flat array with
        // no envelope. Extractor must still find the match objects.
        let payload: [[String: Any]] = [
            [
                "match_key": "abc",
                "event_first_player": "Alcaraz",
                "event_second_player": "Sinner"
            ],
            [
                "event_key": "def",
                "event_first_player": "Sabalenka",
                "event_second_player": "Swiatek"
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let extracted = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)
        #expect(extracted.count == 2)
    }

    @Test func webSocketFrameParserHandlesResultKeyEnvelope() throws {
        // Envelope shape delivered by API Tennis WebSocket: `{ "result": [...] }`.
        let payload: [String: Any] = [
            "result": [
                [
                    "match_key": "xyz",
                    "event_first_player": "Alcaraz",
                    "event_second_player": "Sinner",
                    "event_status": "Set 2"
                ]
            ]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let extracted = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)
        #expect(extracted.count == 1)
        #expect(extracted.first?["match_key"] as? String == "xyz")
    }

    // MARK: - Additional real fixtures: H2H, odds, live odds, player profile

    @Test func apiTennisH2HDTODecodesEnvelopeWithBothPlayerHistories() throws {
        // `get_H2H` delivers a three-way split. The primary direct H2H array
        // is what the app maps into H2HMatchDTO for the Match Detail sheet.
        //
        // Note: the two side arrays (`firstPlayer_results` / `secondPlayer_results`)
        // ship with keys that mix camelCase + snake_case ("firstPlayer_results").
        // Under `.convertFromSnakeCase` the decoder normalizes these to
        // `firstPlayerResults`, which happens to match the CodingKey rawValue
        // in `APIH2HEnvelope` only through the strategy — we guard the direct
        // H2H array here (highest value for the UI) and confirm the envelope
        // structure decodes without throwing.
        let json = """
        {
          "success": 1,
          "result": {
            "H2H": [
              {
                "event_key": 3001,
                "event_date": "2026-05-10",
                "event_time": "14:00",
                "tournament_name": "Rome Masters",
                "event_first_player": "Carlos Alcaraz",
                "event_second_player": "Jannik Sinner",
                "event_final_result": "6-4 6-4",
                "event_winner": "First Player"
              },
              {
                "event_key": 3002,
                "event_date": "2026-04-01",
                "event_time": "18:00",
                "tournament_name": "Miami Open",
                "event_first_player": "Carlos Alcaraz",
                "event_second_player": "Jannik Sinner",
                "event_final_result": "3-6 7-5 6-3",
                "event_winner": "First Player"
              }
            ]
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<APIH2HEnvelope>.self, from: Data(json.utf8))
        let result = try #require(envelope.result)
        #expect(result.h2H?.count == 2)
        #expect(result.h2H?.first?.eventFirstPlayer == "Carlos Alcaraz")
        #expect(result.h2H?.first?.tournamentName == "Rome Masters")
        #expect(result.h2H?.last?.eventFinalResult == "3-6 7-5 6-3")
    }

    @Test func apiTennisOddsDecodeFromMatchOddsPayload() throws {
        // `get_odds` returns `match_key` in snake_case at the JSON level and
        // uses a `match_winner` market. Decoder maps via explicit CodingKeys.
        let json = """
        [
          {
            "match_key": "4501",
            "bookmaker_name": "Bet365",
            "market": "match_winner",
            "odd_name": "Alcaraz",
            "odd_value": "1.65"
          },
          {
            "match_key": "4501",
            "bookmaker_name": "Bet365",
            "market": "match_winner",
            "odd_name": "Sinner",
            "odd_value": "2.20"
          }
        ]
        """
        let decoder = JSONDecoder()
        let odds = try decoder.decode([APIOdds].self, from: Data(json.utf8))
        #expect(odds.count == 2)
        #expect(odds[0].matchKey.value == "4501")
        #expect(odds[0].bookmakerName == "Bet365")
        #expect(odds[0].market == "match_winner")
        #expect(odds[0].oddName == "Alcaraz")
        #expect(odds[0].oddValue == "1.65")
    }

    @Test func apiTennisLiveOddsDecodeWithTimestamp() throws {
        // `get_live_odds` shape — timestamps come as `updated` in the JSON.
        let json = """
        [
          {
            "match_key": "5001",
            "bookmaker_name": "Betway",
            "home_od": "1.80",
            "away_od": "2.00",
            "updated": "2026-08-14 14:23:45"
          }
        ]
        """
        let decoder = JSONDecoder()
        let live = try decoder.decode([APILiveOdds].self, from: Data(json.utf8))
        #expect(live.count == 1)
        #expect(live[0].matchKey.value == "5001")
        #expect(live[0].bookmakerName == "Betway")
        #expect(live[0].homeOdd == "1.80")
        #expect(live[0].awayOdd == "2.00")
        #expect(live[0].updatedAt == "2026-08-14 14:23:45")
    }

    @Test func apiTennisPlayerProfileDecodesWithTournamentsAndStats() throws {
        let json = """
        {
          "success": 1,
          "result": [
            {
              "player_key": 10420,
              "player_name": "Jannik Sinner",
              "player_country": "Italy",
              "player_birthday": "2001-08-16",
              "player_bio": "Italian professional tennis player.",
              "player_logo": "https://cdn.api-tennis.com/players/10420.png",
              "tournaments": [
                { "tournament_name": "Australian Open" },
                { "tournament_name": "Roland Garros" }
              ],
              "stats": [
                { "season": "2026", "type": "aces", "value": "412" },
                { "season": "2026", "type": "first_serve_pct", "value": "64%" }
              ]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<[APIPlayerProfile]>.self, from: Data(json.utf8))
        let profile = try #require(envelope.result?.first)
        #expect(profile.playerKey == 10420)
        #expect(profile.playerName == "Jannik Sinner")
        #expect(profile.playerCountry == "Italy")
        #expect(profile.tournaments?.count == 2)
        #expect(profile.stats?.count == 2)
        #expect(profile.stats?.first?.type == "aces")
    }

    // MARK: - DTO → upsert regression chain
    //
    // These are the highest-value guards for the operational-quality axis.
    // They go from a real-shaped JSON payload all the way to SwiftData and
    // then re-run the upsert to prove idempotency (no duplicates, updated
    // fields on the same row). Any silent regression in upsert identity
    // (externalKey wiring), decoder shape, or normalization surfaces here.

    @MainActor
    @Test func tournamentUpsertChainStaysIdempotentAcrossPayloadUpdates() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let firstJSON = """
        {
          "success": 1,
          "result": [
            {
              "tournament_key": 42,
              "tournament_name": "US Open",
              "tournament_location": "New York",
              "country_name": "USA",
              "tournament_surface": "Hard",
              "tournament_type": "ATP",
              "tournament_date_start": "2026-08-25",
              "tournament_date_end": "2026-09-07"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let firstEnvelope = try decoder.decode(APIEnvelope<[APITournament]>.self, from: Data(firstJSON.utf8))
        let firstDTO = try #require((firstEnvelope.result ?? []).first.map(TournamentDTO.init))
        _ = Tournament.upsert(from: firstDTO, in: context)
        try context.save()

        // Second payload edits city/country/surface but keeps the same key.
        let secondJSON = """
        {
          "success": 1,
          "result": [
            {
              "tournament_key": 42,
              "tournament_name": "US Open",
              "tournament_location": "Flushing Meadows",
              "country_name": "United States",
              "tournament_surface": "Hardcourt",
              "tournament_type": "ATP",
              "tournament_date_start": "2026-08-25",
              "tournament_date_end": "2026-09-07"
            }
          ]
        }
        """
        let secondEnvelope = try decoder.decode(APIEnvelope<[APITournament]>.self, from: Data(secondJSON.utf8))
        let secondDTO = try #require((secondEnvelope.result ?? []).first.map(TournamentDTO.init))
        _ = Tournament.upsert(from: secondDTO, in: context)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<Tournament>())
        #expect(stored.count == 1)
        #expect(stored.first?.city == "Flushing Meadows")
        #expect(stored.first?.surface == "Hardcourt")
    }

    @MainActor
    @Test func rankingUpsertChainReplacesRowsForSamePlayer() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let player = Player.upsert(
            from: PlayerDTO(id: "ranked-p1", name: "Iga Swiatek", nationality: "POL", tour: "WTA", birthDate: nil),
            in: context
        )

        let firstRankingDTO = RankingEntryDTO(
            id: "WTA-ranked-p1",
            playerId: "ranked-p1",
            playerName: "Iga Swiatek",
            nationality: "POL",
            rank: 1,
            points: 10_200,
            tour: "WTA"
        )
        _ = RankingEntry.upsert(from: firstRankingDTO, playersById: ["ranked-p1": player], in: context)

        // A week later the same player drops to #2 with lower points.
        let secondRankingDTO = RankingEntryDTO(
            id: "WTA-ranked-p1",
            playerId: "ranked-p1",
            playerName: "Iga Swiatek",
            nationality: "POL",
            rank: 2,
            points: 9_050,
            tour: "WTA"
        )
        _ = RankingEntry.upsert(from: secondRankingDTO, playersById: ["ranked-p1": player], in: context)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<RankingEntry>())
        #expect(stored.count == 1)
        #expect(stored.first?.rank == 2)
        #expect(stored.first?.points == 9_050)
    }

    @MainActor
    @Test func liveMatchDTOChainUpsertsFullMatchRelationsFromRealPayload() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Seed the two players + tournament so upsert can wire relations.
        let alcaraz = Player.upsert(
            from: PlayerDTO(id: "10421", name: "Carlos Alcaraz", nationality: "ESP", tour: "ATP", birthDate: nil),
            in: context
        )
        let sinner = Player.upsert(
            from: PlayerDTO(id: "10420", name: "Jannik Sinner", nationality: "ITA", tour: "ATP", birthDate: nil),
            in: context
        )
        let tournament = Tournament.upsert(
            from: TournamentDTO(
                id: "4123",
                name: "Cincinnati Masters",
                city: "Cincinnati",
                country: "USA",
                surface: "Hard",
                tour: "ATP",
                startDate: date("2026-08-11"),
                endDate: date("2026-08-19")
            ),
            in: context
        )
        try context.save()

        // Real-shaped live match payload — arrives via WebSocket fallback path.
        let json = """
        {
          "success": 1,
          "result": [
            {
              "event_key": 458123,
              "event_date": "2026-08-14",
              "event_time": "14:00",
              "tournament_key": 4123,
              "tournament_name": "Cincinnati Masters",
              "event_first_player": "Carlos Alcaraz",
              "first_player_key": 10421,
              "event_second_player": "Jannik Sinner",
              "second_player_key": 10420,
              "event_final_result": "6-4 3-2",
              "event_game_result": "3-2",
              "event_status": "Set 2",
              "event_serve": "First Player",
              "event_live": "1",
              "event_first_player_point": "40",
              "event_second_player_point": "30",
              "point_score": "40-30",
              "point_winner": "First Player",
              "country_name": "USA",
              "scores": [
                { "score_first": "6", "score_second": "4", "score_set": "1" },
                { "score_first": "3", "score_second": "2", "score_set": "2" }
              ]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(APIEnvelope<[APILiveMatch]>.self, from: Data(json.utf8))
        let apiMatch = try #require(envelope.result?.first)

        // Manually project to MatchDTO (mirrors mapLiveMatch — the real code
        // path exercised inside APITennisProvider). We want the upsert side of
        // the chain, not the internal mapping.
        let matchDTO = MatchDTO(
            id: apiMatch.eventKey.value,
            date: date("2026-08-14"),
            tournamentId: apiMatch.tournamentKey?.value,
            player1Id: apiMatch.firstPlayerKey?.value ?? "",
            player2Id: apiMatch.secondPlayerKey?.value ?? "",
            player1Name: apiMatch.eventFirstPlayer,
            player2Name: apiMatch.eventSecondPlayer,
            player1Country: "ESP",
            player2Country: "ITA",
            score: "6-4 3-2",
            status: apiMatch.eventStatus ?? "Live",
            isLive: apiMatch.eventLive?.value == "1",
            serverName: apiMatch.eventFirstPlayer,
            pointScore: "40-30",
            gameScore: "3-2",
            pointWinnerName: apiMatch.eventFirstPlayer,
            livePoints: []
        )

        _ = TennisMatch.upsert(
            from: matchDTO,
            playersById: [alcaraz.externalKey ?? "": alcaraz, sinner.externalKey ?? "": sinner],
            tournamentsById: [tournament.externalKey ?? "": tournament],
            in: context
        )
        try context.save()

        let stored = try context.fetch(FetchDescriptor<TennisMatch>())
        #expect(stored.count == 1)
        let match = try #require(stored.first)
        #expect(match.player1?.name == "Carlos Alcaraz")
        #expect(match.player2?.name == "Jannik Sinner")
        #expect(match.tournament?.name == "Cincinnati Masters")
        #expect(match.isLive)
        #expect(match.gameScore == "3-2")
        #expect(match.pointScore == "40-30")
        #expect(match.serverName == "Carlos Alcaraz")

        // Second payload — same event_key but the game moved forward. Must
        // update in place, not create a duplicate.
        let updatedDTO = MatchDTO(
            id: matchDTO.id,
            date: matchDTO.date,
            tournamentId: matchDTO.tournamentId,
            player1Id: matchDTO.player1Id,
            player2Id: matchDTO.player2Id,
            player1Name: matchDTO.player1Name,
            player2Name: matchDTO.player2Name,
            player1Country: matchDTO.player1Country,
            player2Country: matchDTO.player2Country,
            score: "6-4 4-2",
            status: "Set 2",
            isLive: true,
            serverName: matchDTO.player2Name,
            pointScore: "15-30",
            gameScore: "4-2",
            pointWinnerName: matchDTO.player2Name,
            livePoints: []
        )
        _ = TennisMatch.upsert(
            from: updatedDTO,
            playersById: [alcaraz.externalKey ?? "": alcaraz, sinner.externalKey ?? "": sinner],
            tournamentsById: [tournament.externalKey ?? "": tournament],
            in: context
        )
        try context.save()

        let afterUpdate = try context.fetch(FetchDescriptor<TennisMatch>())
        #expect(afterUpdate.count == 1)
        #expect(afterUpdate.first?.pointScore == "15-30")
        #expect(afterUpdate.first?.gameScore == "4-2")
        #expect(afterUpdate.first?.serverName == "Jannik Sinner")
    }

    // MARK: - Failure dashboard
    //
    // Guard the persisted 30-day failure metrics surface consumed by the
    // Provider Diagnostics dashboard. Also proves the sanitizer strips PII
    // from arbitrary error payloads.

    @Test func failureMetricsSanitizerStripsURLsTokensAndSecrets() {
        let raw = """
        API call failed with Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc
        against https://api.api-tennis.com/tennis/?method=get_livescore&APIkey=abcdef12345 status 500
        (correlation 12345678-1234-1234-1234-1234567890ab, ip 10.0.0.1, user user@example.com)
        """
        let sanitized = AppLogger.sanitizedFailureMessage(raw)
        #expect(sanitized.contains("Bearer") == false)
        #expect(sanitized.contains("eyJhbGciOiJIUzI1NiJ9") == false)
        #expect(sanitized.contains("api.api-tennis.com") == false)
        #expect(sanitized.contains("abcdef12345") == false)
        #expect(sanitized.contains("12345678-1234-1234-1234-1234567890ab") == false)
        #expect(sanitized.contains("user@example.com") == false)
        #expect(sanitized.contains("<token>"))
        #expect(sanitized.contains("<url>") || sanitized.contains("<jwt>"))
        #expect(sanitized.contains("<uuid>"))
        #expect(sanitized.contains("<email>"))
    }

    @Test func failureMetricsPruneCapsSizeAndDropsOldEntries() {
        let cutoff = Date().addingTimeInterval(-AppLogger.failureMetricsRetention - 60)
        let stale = FailureMetric(
            category: "sync",
            operation: "old.op",
            count: 3,
            lastMessage: "old",
            lastOccurredAt: cutoff
        )
        let fresh = FailureMetric(
            category: "sync",
            operation: "fresh.op",
            count: 1,
            lastMessage: "fresh",
            lastOccurredAt: .now
        )
        let pruned = AppLogger.pruneFailureMetrics([stale.id: stale, fresh.id: fresh])
        #expect(pruned.count == 1)
        #expect(pruned[fresh.id] != nil)
        #expect(pruned[stale.id] == nil)
    }

    @Test func failureMetricsPruneKeepsMostRecentWhenOverCap() {
        // Build one over the cap; oldest fresh entry should be evicted.
        var metrics: [String: FailureMetric] = [:]
        for i in 0..<(AppLogger.failureMetricsMaxEntries + 5) {
            let metric = FailureMetric(
                category: "sync",
                operation: "op\(i)",
                count: 1,
                lastMessage: "m\(i)",
                lastOccurredAt: Date().addingTimeInterval(TimeInterval(-i))
            )
            metrics[metric.id] = metric
        }
        let pruned = AppLogger.pruneFailureMetrics(metrics)
        #expect(pruned.count == AppLogger.failureMetricsMaxEntries)
        // The most recent (op0) must survive.
        #expect(pruned["sync.op0"] != nil)
        // The oldest one (op<max+4>) must be evicted.
        let evictedID = "sync.op\(AppLogger.failureMetricsMaxEntries + 4)"
        #expect(pruned[evictedID] == nil)
    }

    // MARK: - Crash-free + performance on large lists
    //
    // Feed builder and intelligence engine are hot paths that get called on
    // every re-render of ForYouView and MatchesView. Prove they stay bounded
    // even when the user has synced hundreds of matches. Time budgets are
    // intentionally loose (soft ceilings) — the point is to catch quadratic
    // regressions, not micro-tune throughput.

    @MainActor
    @Test func matchIntelligenceRelevanceScoresStayBoundedForFiveHundredMatches() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let matches = try seedLargeMatchDataset(matchCount: 500, context: context)
        let rankings = try context.fetch(FetchDescriptor<RankingEntry>())

        let started = Date()
        let scores = MatchIntelligence.relevanceScores(for: matches, rankings: rankings)
        let elapsed = Date().timeIntervalSince(started)

        #expect(scores.count == matches.count)
        // 500 matches should score in under 1 second on any device; a
        // quadratic regression usually blows past 5s here.
        #expect(elapsed < 2.0, "relevanceScores took \(elapsed)s for 500 matches — check for O(N²) regression")
    }

    @MainActor
    @Test func forYouFeedBuilderProducesBoundedSectionsForFiveHundredMatches() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let matches = try seedLargeMatchDataset(matchCount: 500, context: context)
        let rankings = try context.fetch(FetchDescriptor<RankingEntry>())
        var preferences = ExperiencePreferences()
        preferences.prioritizeFavorites = true

        let started = Date()
        let sections = ForYouFeedBuilder.sections(matches: matches, rankings: rankings, preferences: preferences)
        let elapsed = Date().timeIntervalSince(started)

        // Section caps: live/urgent/favorites hold up to 4; "recommended"
        // holds up to 6. So the worst case total is 4+4+4+6 = 18 rendered
        // cards regardless of how many matches you throw at it.
        for section in sections {
            let ceiling = section.id == "recommended" ? 6 : 4
            #expect(section.matches.count <= ceiling,
                    "section '\(section.id)' had \(section.matches.count) matches, over its ceiling of \(ceiling)")
        }
        #expect(sections.count <= 4)
        #expect(elapsed < 2.5, "ForYouFeedBuilder took \(elapsed)s for 500 matches — check for regression")
    }

    /// Adversarial WebSocket frame: 800 sibling objects with plausible-looking
    /// keys sitting under a "result" envelope, plus a couple of legit match
    /// payloads. Below the maxPayloadBreadth cap (1000) so the walker MUST
    /// process everything and still find the two real match dictionaries.
    @Test func webSocketFrameParserSurvivesAdversarialSiblingBreadth() throws {
        var siblings: [[String: Any]] = []
        for i in 0..<800 {
            siblings.append([
                "not_a_match_\(i)": "\(i)",
                "note": "decoy"
            ])
        }
        siblings.append([
            "match_key": "real-1",
            "event_first_player": "Alcaraz",
            "event_second_player": "Sinner"
        ])
        siblings.append([
            "event_key": "real-2",
            "event_first_player": "Sabalenka",
            "event_second_player": "Swiatek"
        ])
        let payload: [String: Any] = ["result": siblings]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let extracted = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)
        // Exactly the two real match payloads must be recovered.
        #expect(extracted.count == 2)
        let keys = Set(extracted.compactMap { $0["match_key"] as? String } +
                       extracted.compactMap { $0["event_key"] as? String })
        #expect(keys.contains("real-1"))
        #expect(keys.contains("real-2"))
    }

    /// Beyond the cap: 1_500 siblings triggers `maxPayloadBreadth` and the
    /// walker refuses to descend — must return `[]` instead of crashing.
    @Test func webSocketFrameParserRefusesOversizedSiblingArray() throws {
        var siblings: [[String: Any]] = []
        for i in 0..<1_500 {
            siblings.append([
                "match_key": "would-be-\(i)",
                "event_first_player": "A",
                "event_second_player": "B"
            ])
        }
        let payload: [String: Any] = ["result": siblings]
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let extracted = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded)
        #expect(extracted.isEmpty)
    }

    /// Adversarial JSON with deep nesting past the depth cap. Must NOT crash
    /// (recursion is bounded to 32 frames) and must return an empty array.
    @Test func webSocketFrameParserRefusesOverdeepPayload() throws {
        // Build a chain: {a:{a:{a:...:{match_key:"x"}...}}} 200 levels deep.
        var current: Any = [
            "match_key": "buried",
            "event_first_player": "A",
            "event_second_player": "B"
        ] as [String: Any]
        for _ in 0..<200 {
            current = ["a": current]
        }
        let encoded = try JSONSerialization.data(withJSONObject: current)
        // Explicit cap of 10 — legit payload lives at depth 200, well past it.
        let extracted = try LiveMatchWebSocketService.matchDictionaries(fromFrameData: encoded, maxDepth: 10)
        #expect(extracted.isEmpty)
    }
}

private extension Match_PointTests {
    /// Seeds `matchCount` matches with realistic churn (mix of live,
    /// upcoming, completed, favorites, various rankings) so perf tests
    /// exercise every code path in the relevance scorer and feed builder.
    @MainActor
    func seedLargeMatchDataset(matchCount: Int, context: ModelContext) throws -> [TennisMatch] {
        // Build 40 players + 4 tournaments to keep the relation graph
        // reasonable while producing enough variation for MatchIntelligence.
        var players: [Player] = []
        for i in 0..<40 {
            let player = Player(
                externalKey: "perf-p\(i)",
                name: "Player \(i)",
                nationality: i.isMultiple(of: 2) ? "USA" : "ESP",
                isWTA: i.isMultiple(of: 3)
            )
            player.isFavorite = i < 3
            context.insert(player)
            players.append(player)
        }

        var tournaments: [Tournament] = []
        for i in 0..<4 {
            let tournament = Tournament(
                externalKey: "perf-t\(i)",
                name: "Perf Tournament \(i)",
                city: "City \(i)",
                country: "USA",
                surface: i.isMultiple(of: 2) ? "Hard" : "Clay",
                tour: i.isMultiple(of: 2) ? .atp : .wta,
                startDate: .now.addingTimeInterval(-86_400 * 3),
                endDate: .now.addingTimeInterval(86_400 * 4)
            )
            context.insert(tournament)
            tournaments.append(tournament)
        }

        // Rankings for the top 20 players.
        for i in 0..<20 {
            let entry = RankingEntry(
                externalKey: "perf-rank-\(i)",
                player: players[i],
                rank: i + 1,
                points: 10_000 - i * 300,
                tour: players[i].isWTA ? .wta : .atp
            )
            context.insert(entry)
        }

        var matches: [TennisMatch] = []
        for i in 0..<matchCount {
            let p1 = players[i % players.count]
            let p2 = players[(i + 1) % players.count]
            let tournament = tournaments[i % tournaments.count]
            let now = Date()
            // Distribute: ~10% live, ~40% upcoming, ~50% completed.
            let bucket = i % 10
            let date: Date
            let isLive: Bool
            let status: String
            switch bucket {
            case 0:
                date = now.addingTimeInterval(-60 * 5)
                isLive = true
                status = "Set 2"
            case 1, 2, 3, 4:
                date = now.addingTimeInterval(TimeInterval(60 * (i + 30)))
                isLive = false
                status = "Scheduled"
            default:
                date = now.addingTimeInterval(TimeInterval(-3_600 * (i + 5)))
                isLive = false
                status = "Final"
            }

            let match = TennisMatch(
                externalID: "perf-m\(i)",
                date: date,
                status: status,
                isLive: isLive,
                lastUpdatedAt: isLive ? now : nil,
                serverName: isLive ? p1.name : "",
                pointScore: isLive ? "30-15" : "",
                gameScore: isLive ? "3-2" : "",
                isFavorite: i.isMultiple(of: 50),
                tournament: tournament,
                player1: p1,
                player2: p2,
                score: bucket < 5 ? "" : "6-4 6-3"
            )
            context.insert(match)
            matches.append(match)
        }

        try context.save()
        return matches
    }
}

private extension Match_PointTests {
    @MainActor
    func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Player.self,
            Tournament.self,
            TennisMatch.self,
            RankingEntry.self,
            UserProfile.self,
            PointBet.self,
            SocialPost.self,
            MatchPoll.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func date(_ string: String) -> Date {
        let formatter = TennisAPIConfiguration.makePOSIXDateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    func dateTime(_ string: String) -> Date {
        let formatter = TennisAPIConfiguration.makePOSIXDateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    func timelinePayload(_ events: [MatchTimelineEvent]) throws -> String {
        let data = try JSONEncoder().encode(events)
        return String(data: data, encoding: .utf8)!
    }
}

private final class MockTennisAPI: TennisAPIProviding {
    var tournamentsValue: [TournamentDTO] = []
    var rankingsValue: [RankingEntryDTO] = []
    var playersValue: [PlayerDTO] = []
    var liveMatchesValue: [MatchDTO] = []
    var eventTypesValue: [EventTypeDTO] = []
    var fixtureMatches: [MatchDTO] = []
    var h2HValue: [H2HMatchDTO] = []
    var playerProfileValue: PlayerProfileDTO?
    var oddsValue: [OddsDTO] = []
    var liveOddsValue: [LiveOddsDTO] = []

    var tournamentsError: Error?
    var rankingsError: Error?
    var playersError: Error?
    var liveMatchesError: Error?
    var fixturesError: Error?

    func tournaments() async throws -> [TournamentDTO] {
        if let tournamentsError { throw tournamentsError }
        return tournamentsValue
    }

    func rankings(tour: String?) async throws -> [RankingEntryDTO] {
        if let rankingsError { throw rankingsError }
        return rankingsValue
    }

    func players(tour: String?) async throws -> [PlayerDTO] {
        if let playersError { throw playersError }
        return playersValue
    }

    func liveMatches() async throws -> [MatchDTO] {
        if let liveMatchesError { throw liveMatchesError }
        return liveMatchesValue
    }

    func eventTypes() async throws -> [EventTypeDTO] {
        eventTypesValue
    }

    func fixtures(from startDate: Date, to endDate: Date, tournamentKey: String?) async throws -> [MatchDTO] {
        if let fixturesError { throw fixturesError }
        return fixtureMatches
    }

    func headToHead(firstPlayerKey: String, secondPlayerKey: String) async throws -> [H2HMatchDTO] {
        h2HValue
    }

    func playerProfile(playerKey: String, tour: String?) async throws -> PlayerProfileDTO? {
        playerProfileValue
    }

    func odds(matchKey: String) async throws -> [OddsDTO] {
        oddsValue
    }

    func liveOdds(matchKey: String?) async throws -> [LiveOddsDTO] {
        liveOddsValue
    }
}

private final class MockNotificationCenter: NotificationCenterScheduling {
    var pending: [UNNotificationRequest] = []
    var removedPending: [String] = []
    var removedDelivered: [String] = []

    func add(_ request: UNNotificationRequest) async throws {
        pending.append(request)
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        pending
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError(message: "Missing MockURLProtocol handler"))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLSession {
    static func mocked(_ handler: @escaping (URLRequest) throws -> (Data, HTTPURLResponse)) -> URLSession {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
