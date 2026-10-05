import Foundation
import OSLog
import SwiftData

@MainActor
enum UITestSeedData {
    static func seedIfNeeded(in context: ModelContext) {
        let descriptor = FetchDescriptor<Player>()
        do {
            if try context.fetch(descriptor).isEmpty == false {
                return
            }
        } catch {
            AppLogger.persistence.error("Failed to inspect UI test seed data: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "uiTestSeed.fetchPlayers", error: error)
        }

        let alcaraz = Player(externalKey: "ui-alcaraz", name: "Carlos Alcaraz", nationality: "ESP", isWTA: false, isFavorite: true)
        let sinner = Player(externalKey: "ui-sinner", name: "Jannik Sinner", nationality: "ITA", isWTA: false)
        let bia = Player(externalKey: "ui-bia", name: "Beatriz Haddad Maia", nationality: "BRA", isWTA: true, isFavorite: true)
        let iga = Player(externalKey: "ui-iga", name: "Iga Swiatek", nationality: "POL", isWTA: true)

        let tournament = Tournament(
            externalKey: "ui-rg",
            name: "Roland Garros",
            city: "Paris",
            country: "France",
            surface: "Clay",
            tour: .atp,
            startDate: .now.addingTimeInterval(-86_400),
            endDate: .now.addingTimeInterval(86_400 * 7),
            isFavorite: true
        )

        let live = TennisMatch(
            externalID: "ui-live",
            date: .now.addingTimeInterval(-900),
            status: "Live",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: alcaraz.name,
            pointScore: "40-30",
            gameScore: "4-5",
            isFavorite: true,
            tournament: tournament,
            player1: alcaraz,
            player2: sinner,
            score: "6-4"
        )
        live.registerLiveTimelineEvent(pointWinnerName: alcaraz.name)

        let upcoming = TennisMatch(
            externalID: "ui-upcoming",
            date: .now.addingTimeInterval(3_600),
            status: "Scheduled",
            tournament: tournament,
            player1: bia,
            player2: iga
        )
        let completed = TennisMatch(
            externalID: "ui-completed",
            date: .now.addingTimeInterval(-7_200),
            status: "Final",
            isLive: false,
            tournament: tournament,
            player1: alcaraz,
            player2: sinner,
            score: "6-4 6-4"
        )

        let profile = UserProfile(displayName: "UI Fan", avatarSymbol: "tennisball.fill", points: 1_000)
        let bet = PointBet(match: live, player: alcaraz, selection: alcaraz.name, stake: 25, payout: 45)
        let settlementBet = PointBet(match: completed, player: alcaraz, selection: alcaraz.name, stake: 25, payout: 45)
        let post = SocialPost(match: live, authorName: "UI Fan", body: "Teste social ao vivo.", likes: 3, replyCount: 1, isPinned: true)
        let poll = MatchPoll(match: live, question: "Quem vence?", optionOne: alcaraz.name, optionTwo: sinner.name)

        [alcaraz, sinner, bia, iga].forEach(context.insert)
        context.insert(tournament)
        context.insert(live)
        context.insert(upcoming)
        context.insert(completed)
        context.insert(profile)
        context.insert(bet)
        context.insert(settlementBet)
        context.insert(post)
        context.insert(poll)
        [
            RankingEntry(externalKey: "ui-r1", player: sinner, rank: 2, points: 7_200, tour: .atp),
            RankingEntry(externalKey: "ui-r2", player: alcaraz, rank: 3, points: 7_000, tour: .atp),
            RankingEntry(externalKey: "ui-r3", player: iga, rank: 1, points: 9_000, tour: .wta),
            RankingEntry(externalKey: "ui-r4", player: bia, rank: 18, points: 2_400, tour: .wta)
        ].forEach(context.insert)

        do {
            try context.save()
        } catch {
            AppLogger.persistence.error("Failed to seed UI test data: \(AppLogger.message(for: error), privacy: .private)")
        }
    }
}
