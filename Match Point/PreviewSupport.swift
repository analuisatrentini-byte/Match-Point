import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
enum MatchPointPreviewData {
    static let modelTypes: [any PersistentModel.Type] = [
        Player.self,
        Tournament.self,
        TennisMatch.self,
        RankingEntry.self,
        UserProfile.self,
        PointBet.self,
        SocialPost.self,
        MatchPoll.self
    ]

    static func seed(_ container: ModelContainer) {
        seed(ModelContext(container))
    }

    private static func seed(_ context: ModelContext) {
        let alcaraz = Player(externalKey: "preview-alcaraz", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false, isFavorite: true)
        let sinner = Player(externalKey: "preview-sinner", name: "Jannik Sinner", nationality: "ITA", isWTA: false, isFavorite: true)
        let bia = Player(externalKey: "preview-bia", name: "Beatriz Haddad Maia", nationality: "BRA", isWTA: true, isFavorite: true)
        let iga = Player(externalKey: "preview-iga", name: "Iga Swiatek", nationality: "POL", isWTA: true)

        let tournament = Tournament(
            externalKey: "preview-rg",
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: .now.addingTimeInterval(-86_400 * 3),
            endDate: .now.addingTimeInterval(86_400 * 8),
            isFavorite: true
        )
        let wtaTournament = Tournament(
            externalKey: "preview-rome",
            name: "Rome WTA 1000",
            city: "Rome",
            country: "Italy",
            surface: "Clay",
            tour: .wta,
            startDate: .now.addingTimeInterval(-86_400),
            endDate: .now.addingTimeInterval(86_400 * 5)
        )

        let live = TennisMatch(
            externalID: "preview-live",
            date: .now.addingTimeInterval(-1_200),
            status: "Live",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: "Carlos Alcaraz",
            pointScore: "30-40",
            gameScore: "4-5",
            isFavorite: true,
            tournament: tournament,
            player1: alcaraz,
            player2: sinner,
            score: "6-4 3-6"
        )
        live.liveTimelinePayload = previewTimeline()

        let upcoming = TennisMatch(
            externalID: "preview-upcoming",
            date: .now.addingTimeInterval(7_200),
            status: "Scheduled",
            tournament: wtaTournament,
            player1: bia,
            player2: iga
        )
        let completed = TennisMatch(
            externalID: "preview-completed",
            date: .now.addingTimeInterval(-86_400),
            status: "Final",
            tournament: tournament,
            player1: sinner,
            player2: alcaraz,
            score: "7-6 4-6 6-3"
        )

        let profile = UserProfile(displayName: "Ana Match", avatarSymbol: "tennisball.fill", points: 1_420)
        let wonBet = PointBet(match: completed, player: sinner, kind: .matchWinner, selection: sinner.name, stake: 50, payout: 90, status: .won)
        let openBet = PointBet(match: live, player: alcaraz, kind: .holdServe, selection: alcaraz.name, stake: 25, payout: 38)
        let post = SocialPost(match: live, authorName: "Ana Match", body: "Esse break point pode mudar o set.", likes: 12, replyCount: 2, isPinned: true)
        let poll = MatchPoll(match: live, question: "Quem leva o próximo set?", optionOne: alcaraz.name, optionTwo: sinner.name, optionThree: "Tie-break")

        [alcaraz, sinner, bia, iga].forEach(context.insert)
        [tournament, wtaTournament].forEach(context.insert)
        [live, upcoming, completed].forEach(context.insert)
        [
            RankingEntry(externalKey: "preview-r1", player: sinner, rank: 2, points: 8_700, tour: .atp),
            RankingEntry(externalKey: "preview-r2", player: alcaraz, rank: 3, points: 7_950, tour: .atp),
            RankingEntry(externalKey: "preview-r3", player: iga, rank: 1, points: 9_100, tour: .wta),
            RankingEntry(externalKey: "preview-r4", player: bia, rank: 18, points: 2_400, tour: .wta)
        ].forEach(context.insert)
        context.insert(profile)
        context.insert(wonBet)
        context.insert(openBet)
        context.insert(post)
        context.insert(poll)
        try? context.save()
    }

    private static func previewTimeline() -> String {
        let events = [
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-90), title: "Jannik Sinner winner", detail: "Ponto Jannik Sinner"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-70), title: "Carlos Alcaraz saque", detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-50), title: "Carlos Alcaraz saque", detail: "Saque: Carlos Alcaraz • winner Carlos Alcaraz"),
            MatchTimelineEvent(timestamp: .now.addingTimeInterval(-30), title: "Break point", detail: "Saque: Carlos Alcaraz • Pontos: 30-40")
        ]
        let data = try? JSONEncoder().encode(events)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

#Preview("Onboarding") {
    OnboardingView {}
        .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
            if case .success(let container) = result {
                MatchPointPreviewData.seed(container)
            }
        }
        .environmentObject(AlertPreferencesStore.shared)
        .environmentObject(ExperiencePreferencesStore.shared)
        .environmentObject(ProductAnalyticsStore.shared)
        .environmentObject(CloudSocialBackend.previewStub())
}

#Preview("Profile") {
    NavigationStack {
        ProfileView()
    }
    .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
        if case .success(let container) = result {
            MatchPointPreviewData.seed(container)
        }
    }
    .environmentObject(AlertPreferencesStore.shared)
    .environmentObject(ExperiencePreferencesStore.shared)
    .environmentObject(BehaviorPersonalizationStore.shared)
    .environmentObject(ProductAnalyticsStore.shared)
    .environmentObject(ResponsibleGamblingStore.shared)
    .environmentObject(CloudSocialBackend.previewStub(seedingData: true))
}

#Preview("Live Tracker") {
    NavigationStack {
        LiveTrackerView()
    }
    .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
        if case .success(let container) = result {
            MatchPointPreviewData.seed(container)
        }
    }
}

#Preview("Match Point Social") {
    NavigationStack {
        SocialFeedView()
    }
    .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
        if case .success(let container) = result {
            MatchPointPreviewData.seed(container)
        }
    }
    .environmentObject(CloudSocialBackend.previewStub(seedingData: true))
}
