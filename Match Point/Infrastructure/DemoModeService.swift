import Combine
import Foundation
import OSLog
import SwiftData

// MARK: - Demo Mode
//
// Match Point can run in three data modes:
//
// 1. Production sync — a backend proxy is configured, so
//    `DataSyncService` pulls real tournaments, matches, players and rankings.
// 2. Empty install — the user finished onboarding but the provider hasn't
//    been reached (still syncing, no network, etc.). Empty states with
//    contextual CTAs show the demo mode escape hatch.
// 3. Demo mode — provider isn't ready (or the user explicitly chose demo),
//    so the app materializes a realistic dataset (Alcaraz vs. Sinner live,
//    Bia vs. Iga upcoming, Sinner vs. Alcaraz completed, plus rankings /
//    social artifacts) so every screen has real content in the first 30
//    seconds. Users leaving demo mode always get their data preserved.
//
// `DemoModeService` owns the state machine that decides when to seed and
// exposes user-facing toggles for Settings / empty states.

@MainActor
final class DemoModeService: ObservableObject {
    static let shared = DemoModeService()

    /// Whether demo data is currently seeded in the model context. Views bind
    /// to this so they can hide the "Ativar modo demo" CTA once seeded.
    @Published private(set) var isDemoActive: Bool

    /// True when the user explicitly disabled demo mode (either during
    /// onboarding or via Settings). Prevents future auto-seeds until the user
    /// re-enables it explicitly.
    @Published private(set) var isDemoDismissed: Bool

    private let defaults: UserDefaults
    private static let dismissedKey = "match-point.demo.dismissed"
    private static let activeKey = "match-point.demo.active"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isDemoActive = defaults.bool(forKey: Self.activeKey)
        self.isDemoDismissed = defaults.bool(forKey: Self.dismissedKey)
    }

    /// Runs on app launch AFTER the model container is available. Seeds demo
    /// data when: (a) the provider has no configured key and (b) the user
    /// hasn't dismissed demo mode and (c) there is no meaningful production
    /// data yet. Keeps first-launch users off the empty-state cliff.
    func bootstrapIfNeeded(in context: ModelContext, hasConfiguredProvider: Bool) {
        // Users with a configured provider still deserve a smooth first
        // moment. But once a real sync brings production data, we should not
        // pollute the store with demo entries — so we require the context to
        // be empty of production content before seeding.
        guard !isDemoDismissed else { return }
        guard !hasProductionContent(in: context) else {
            if isDemoActive {
                clearDemoEntities(in: context)
                setActive(false)
            }
            return
        }
        guard !hasConfiguredProvider || isDemoActive else { return }
        seedDemoData(in: context)
    }

    /// Explicit user toggle from Settings / empty state / onboarding.
    func enableDemoMode(in context: ModelContext) {
        setDismissed(false)
        seedDemoData(in: context)
    }

    /// User asked to leave demo mode. Removes only entries we seeded, so any
    /// production data the user layered on top (favorites, bets, etc.) stays.
    func disableDemoMode(in context: ModelContext) {
        clearDemoEntities(in: context)
        setActive(false)
        setDismissed(true)
    }

    /// Mark demo mode as dismissed without touching the store — used when the
    /// user has real data streaming in and just wants the "enable demo" CTA
    /// to disappear.
    func acknowledgeRealData() {
        setDismissed(true)
    }

    // MARK: - Seeding

    private func seedDemoData(in context: ModelContext) {
        // Idempotent: skip if the canonical live match already exists.
        let liveKey = DemoSeedIdentifiers.liveMatchExternalID
        let descriptor = FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.externalID == liveKey }
        )
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            setActive(true)
            return
        }

        let payload = DemoModeSeed.materialize()
        for player in payload.players { context.insert(player) }
        for tournament in payload.tournaments { context.insert(tournament) }
        for match in payload.matches { context.insert(match) }
        for entry in payload.rankings { context.insert(entry) }
        if let profile = payload.profile { context.insert(profile) }
        for post in payload.posts { context.insert(post) }
        for poll in payload.polls { context.insert(poll) }
        for bet in payload.bets { context.insert(bet) }

        do {
            try context.save()
            setActive(true)
        } catch {
            AppLogger.persistence.error("Demo mode seed failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "demoMode.seed", error: error)
        }
    }

    private func clearDemoEntities(in context: ModelContext) {
        let playerKeys = DemoSeedIdentifiers.playerExternalKeys
        let tournamentKeys = DemoSeedIdentifiers.tournamentExternalKeys
        let matchKeys = DemoSeedIdentifiers.matchExternalKeys
        let rankingKeys = DemoSeedIdentifiers.rankingExternalKeys

        removeAll(TennisMatch.self, in: context) { match in
            guard let key = match.externalID else { return false }
            return matchKeys.contains(key)
        }
        removeAll(Tournament.self, in: context) { tournament in
            guard let key = tournament.externalKey else { return false }
            return tournamentKeys.contains(key)
        }
        removeAll(Player.self, in: context) { player in
            guard let key = player.externalKey else { return false }
            return playerKeys.contains(key)
        }
        removeAll(RankingEntry.self, in: context) { entry in
            guard let key = entry.externalKey else { return false }
            return rankingKeys.contains(key)
        }
        removeAll(SocialPost.self, in: context) { post in
            guard let key = post.eventKey else { return false }
            return DemoSeedIdentifiers.postEventKeys.contains(key)
        }
        removeAll(MatchPoll.self, in: context) { poll in
            DemoSeedIdentifiers.pollQuestions.contains(poll.question)
        }
        removeAll(PointBet.self, in: context) { bet in
            DemoSeedIdentifiers.betSelectionMarkers.contains(bet.selection)
                && matchKeys.contains(bet.match?.externalID ?? "")
        }
        removeAll(UserProfile.self, in: context) { profile in
            profile.externalKey == DemoSeedIdentifiers.profileExternalKey
        }

        try? context.save()
    }

    private func removeAll<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext,
        matching predicate: (Model) -> Bool
    ) {
        do {
            let all = try context.fetch(FetchDescriptor<Model>())
            for model in all where predicate(model) {
                context.delete(model)
            }
        } catch {
            AppLogger.persistence.error("Failed to fetch \(String(describing: type)) during demo teardown: \(AppLogger.message(for: error), privacy: .private)")
        }
    }

    /// Returns true when the store already contains real production data
    /// (players with non-demo external keys, tournaments, or matches).
    private func hasProductionContent(in context: ModelContext) -> Bool {
        let playerDescriptor = FetchDescriptor<Player>()
        let matchDescriptor = FetchDescriptor<TennisMatch>()
        let tournamentDescriptor = FetchDescriptor<Tournament>()
        let demoKeys = DemoSeedIdentifiers.playerExternalKeys
        let onboardingSeedKeys = OnboardingSeedIdentifiers.playerExternalKeys

        if let players = try? context.fetch(playerDescriptor) {
            let realPlayers = players.filter { player in
                guard let key = player.externalKey else { return true }
                if demoKeys.contains(key) { return false }
                if onboardingSeedKeys.contains(key) { return false }
                return true
            }
            if !realPlayers.isEmpty { return true }
        }
        if let tournaments = try? context.fetch(tournamentDescriptor) {
            let realTournaments = tournaments.filter { tournament in
                guard let key = tournament.externalKey else { return true }
                return !DemoSeedIdentifiers.tournamentExternalKeys.contains(key)
            }
            if !realTournaments.isEmpty { return true }
        }
        if let matches = try? context.fetch(matchDescriptor) {
            let realMatches = matches.filter { match in
                guard let key = match.externalID else { return true }
                return !DemoSeedIdentifiers.matchExternalKeys.contains(key)
            }
            if !realMatches.isEmpty { return true }
        }
        return false
    }

    // MARK: - Persistence

    private func setActive(_ value: Bool) {
        isDemoActive = value
        defaults.set(value, forKey: Self.activeKey)
    }

    private func setDismissed(_ value: Bool) {
        isDemoDismissed = value
        defaults.set(value, forKey: Self.dismissedKey)
    }
}

// MARK: - Seed identifiers

/// Constants used by both the seed writer and the teardown path so we never
/// leak demo entries into the production store.
enum DemoSeedIdentifiers {
    static let liveMatchExternalID = "demo-live"
    static let upcomingMatchExternalID = "demo-upcoming"
    static let completedMatchExternalID = "demo-completed"

    static let matchExternalKeys: Set<String> = [
        liveMatchExternalID,
        upcomingMatchExternalID,
        completedMatchExternalID
    ]

    static let tournamentExternalKeys: Set<String> = [
        "demo-rg",
        "demo-rome"
    ]

    static let playerExternalKeys: Set<String> = [
        "demo-alcaraz",
        "demo-sinner",
        "demo-bia",
        "demo-iga",
        "demo-djokovic",
        "demo-sabalenka"
    ]

    static let rankingExternalKeys: Set<String> = [
        "demo-rk-1", "demo-rk-2", "demo-rk-3", "demo-rk-4", "demo-rk-5", "demo-rk-6"
    ]

    static let profileExternalKey = "demo-profile"

    static let postEventKeys: Set<String> = [
        "review:4:demo-live-cheer",
        "review:5:demo-live-story",
        "review:5:demo-completed-story"
    ]

    static let pollQuestions: Set<String> = [
        "Quem leva o próximo set?"
    ]

    static let betSelectionMarkers: Set<String> = [
        "Carlos Alcaraz",
        "Jannik Sinner"
    ]
}

/// Onboarding seed players (`OnboardingView.popularPlayerSeeds`). They live
/// in the local store so the onboarding grid always has options, but they
/// count as "no production data" for the demo bootstrap check.
enum OnboardingSeedIdentifiers {
    static let playerExternalKeys: Set<String> = [
        "seed-carlos-alcaraz", "seed-jannik-sinner", "seed-novak-djokovic",
        "seed-daniil-medvedev", "seed-iga-swiatek", "seed-aryna-sabalenka",
        "seed-coco-gauff", "seed-beatriz-haddad-maia", "seed-naomi-osaka",
        "seed-rafael-nadal", "seed-alexander-zverev", "seed-elena-rybakina"
    ]
}

// MARK: - Seed payload

/// Materializes the demo dataset as inserts-only value types (no side
/// effects). Everything a first-launch user needs to see the app come alive:
/// a favorite player, a live match with timeline, an upcoming favorite match,
/// a completed head-to-head, rankings, one settled bet + one open bet, and a
/// pinned social story.
@MainActor
enum DemoModeSeed {
    struct Payload {
        let players: [Player]
        let tournaments: [Tournament]
        let matches: [TennisMatch]
        let rankings: [RankingEntry]
        let profile: UserProfile?
        let posts: [SocialPost]
        let polls: [MatchPoll]
        let bets: [PointBet]
    }

    static func materialize(now: Date = .now) -> Payload {
        let alcaraz = Player(
            externalKey: "demo-alcaraz",
            name: "Carlos Alcaraz",
            nationality: "ESP",
            isWTA: false,
            isFavorite: true
        )
        let sinner = Player(
            externalKey: "demo-sinner",
            name: "Jannik Sinner",
            nationality: "ITA",
            isWTA: false
        )
        let bia = Player(
            externalKey: "demo-bia",
            name: "Beatriz Haddad Maia",
            nationality: "BRA",
            isWTA: true,
            isFavorite: true
        )
        let iga = Player(
            externalKey: "demo-iga",
            name: "Iga Swiatek",
            nationality: "POL",
            isWTA: true
        )
        let djokovic = Player(
            externalKey: "demo-djokovic",
            name: "Novak Djokovic",
            nationality: "SRB",
            isWTA: false
        )
        let sabalenka = Player(
            externalKey: "demo-sabalenka",
            name: "Aryna Sabalenka",
            nationality: "BLR",
            isWTA: true
        )

        let rolandGarros = Tournament(
            externalKey: "demo-rg",
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: now.addingTimeInterval(-86_400 * 3),
            endDate: now.addingTimeInterval(86_400 * 8),
            isFavorite: true
        )
        let rome = Tournament(
            externalKey: "demo-rome",
            name: "Rome WTA 1000",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: .wta,
            startDate: now.addingTimeInterval(-86_400 * 2),
            endDate: now.addingTimeInterval(86_400 * 5)
        )

        let live = TennisMatch(
            externalID: DemoSeedIdentifiers.liveMatchExternalID,
            date: now.addingTimeInterval(-1_500),
            status: "Live",
            isLive: true,
            lastUpdatedAt: now,
            serverName: "Carlos Alcaraz",
            pointScore: "30-40",
            gameScore: "4-5",
            liveTimelinePayload: liveTimelinePayload(now: now),
            isFavorite: true,
            tournament: rolandGarros,
            player1: alcaraz,
            player2: sinner,
            score: "6-4 3-6"
        )

        let upcoming = TennisMatch(
            externalID: DemoSeedIdentifiers.upcomingMatchExternalID,
            date: now.addingTimeInterval(60 * 55),
            status: "Scheduled",
            tournament: rome,
            player1: bia,
            player2: iga
        )

        let completed = TennisMatch(
            externalID: DemoSeedIdentifiers.completedMatchExternalID,
            date: now.addingTimeInterval(-86_400),
            status: "Final",
            tournament: rolandGarros,
            player1: sinner,
            player2: alcaraz,
            score: "7-6 4-6 6-3"
        )

        let rankings: [RankingEntry] = [
            RankingEntry(externalKey: "demo-rk-1", player: sinner, rank: 2, points: 8_700, tour: .atp),
            RankingEntry(externalKey: "demo-rk-2", player: alcaraz, rank: 3, points: 7_950, tour: .atp),
            RankingEntry(externalKey: "demo-rk-3", player: djokovic, rank: 5, points: 6_600, tour: .atp),
            RankingEntry(externalKey: "demo-rk-4", player: iga, rank: 1, points: 9_100, tour: .wta),
            RankingEntry(externalKey: "demo-rk-5", player: sabalenka, rank: 2, points: 8_400, tour: .wta),
            RankingEntry(externalKey: "demo-rk-6", player: bia, rank: 18, points: 2_400, tour: .wta)
        ]

        let profile = UserProfile(
            externalKey: DemoSeedIdentifiers.profileExternalKey,
            displayName: "Match Point Demo",
            avatarSymbol: "tennisball.fill",
            points: 1_420
        )

        let wonBet = PointBet(
            match: completed,
            player: sinner,
            kind: .matchWinner,
            selection: sinner.name,
            stake: 50,
            payout: 90,
            status: .won
        )
        let openBet = PointBet(
            match: live,
            player: alcaraz,
            kind: .holdServe,
            selection: alcaraz.name,
            stake: 25,
            payout: 38,
            status: .open
        )

        let liveStory = SocialPost(
            match: live,
            authorName: "Ana Match",
            body: "Intensidade de final\n\nMesmo em andamento, já tem cara de partida para rever: muita variação, pressão no saque e rallies longos.",
            likes: 12,
            eventKey: "review:5:demo-live-story",
            isPinned: true
        )
        let cheer = SocialPost(
            match: live,
            authorName: "Match Point Fan",
            body: "Energia ótima\n\nNão é perfeita tecnicamente, mas entrega tensão e personalidade do começo ao fim.",
            likes: 5,
            eventKey: "review:4:demo-live-cheer"
        )
        let story = SocialPost(
            match: completed,
            authorName: "Clara",
            body: "Vitória com assinatura\n\nSinner controlou os momentos grandes e fechou como quem sabia exatamente o roteiro da partida.",
            likes: 24,
            eventKey: "review:5:demo-completed-story"
        )

        let poll = MatchPoll(
            match: live,
            question: "Quem leva o próximo set?",
            optionOne: alcaraz.name,
            optionTwo: sinner.name,
            optionThree: "Vai ao tie-break",
            votesOne: 32,
            votesTwo: 27,
            votesThree: 11
        )

        return Payload(
            players: [alcaraz, sinner, bia, iga, djokovic, sabalenka],
            tournaments: [rolandGarros, rome],
            matches: [live, upcoming, completed],
            rankings: rankings,
            profile: profile,
            posts: [liveStory, cheer, story],
            polls: [poll],
            bets: [wonBet, openBet]
        )
    }

    private static func liveTimelinePayload(now: Date) -> String {
        let events = [
            MatchTimelineEvent(
                timestamp: now.addingTimeInterval(-140),
                title: "Carlos Alcaraz saque",
                detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz"
            ),
            MatchTimelineEvent(
                timestamp: now.addingTimeInterval(-100),
                title: "Rally longo",
                detail: "Ponto Jannik Sinner após 12 bolas"
            ),
            MatchTimelineEvent(
                timestamp: now.addingTimeInterval(-70),
                title: "Ace",
                detail: "Ace de Carlos Alcaraz na segunda"
            ),
            MatchTimelineEvent(
                timestamp: now.addingTimeInterval(-40),
                title: "Break point",
                detail: "Sinner tem chance de quebrar em 4-5"
            )
        ]
        let data = try? JSONEncoder().encode(events)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
