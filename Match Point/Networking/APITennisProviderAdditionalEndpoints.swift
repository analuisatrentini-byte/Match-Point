import Foundation

// MARK: - Additional API Tennis endpoints

extension APITennisProvider {

func eventTypes() async throws -> [EventTypeDTO] {
    try await instrumented(.rankings) {
        let response: APIEnvelope<[APIEvent]> = try await request(method: "get_events")
        return (response.result ?? []).map(EventTypeDTO.init)
    }
}

func fixtures(
    from startDate: Date,
    to endDate: Date,
    tournamentKey: String?
) async throws -> [MatchDTO] {
    try await instrumented(.fixtures) {
        var collected: [MatchDTO] = []
        var lastError: Error?

        for date in Self.fixtureDates(from: startDate, to: endDate) {
            var query: [String: String] = [
                "date_start": Self.fixtureDateFormatter.string(from: date),
                "date_stop": Self.fixtureDateFormatter.string(from: date)
            ]
            if let tournamentKey, !tournamentKey.isEmpty {
                query["tournament_key"] = tournamentKey
            }
            do {
                let response: APIEnvelope<[APIFixture]> = try await request(
                    method: "get_fixtures",
                    extraQuery: query
                )
                collected.append(contentsOf: (response.result ?? []).map(mapFixture))
            } catch {
                lastError = error
            }
        }

        if collected.isEmpty, let lastError {
            throw lastError
        }
        return collected
    }
}

func headToHead(firstPlayerKey: String, secondPlayerKey: String) async throws -> [H2HMatchDTO] {
    try await instrumented(.headToHead) {
        let response: APIEnvelope<APIH2HEnvelope> = try await request(
            method: "get_H2H",
            extraQuery: [
                "first_player_key": firstPlayerKey,
                "second_player_key": secondPlayerKey
            ]
        )
        guard let result = response.result else { return [] }
        let direct = result.h2H ?? []
        let firstWins = result.firstPlayerResults ?? []
        let secondWins = result.secondPlayerResults ?? []
        let combined = direct + firstWins + secondWins
        return combined.map(mapH2H)
    }
}

func playerProfile(playerKey: String, tour: String?) async throws -> PlayerProfileDTO? {
    try await instrumented(.playerProfile) {
        let response: APIEnvelope<[APIPlayerProfile]> = try await request(
            method: "get_players",
            extraQuery: [
                "player_key": playerKey
            ]
        )
        return response.result?.first.map { mapPlayerProfile($0, fallbackKey: playerKey) }
    }
}

func odds(matchKey: String) async throws -> [OddsDTO] {
    try await instrumented(.odds) {
        let response: APIEnvelope<[APIOdds]> = try await request(
            method: "get_odds",
            extraQuery: ["match_key": matchKey]
        )
        return (response.result ?? []).enumerated().map { index, odds in
            OddsDTO(
                id: "\(matchKey)-\(index)",
                matchKey: odds.matchKey.value,
                bookmakerName: odds.bookmakerName ?? "Unknown",
                market: odds.market ?? "match_winner",
                outcome: odds.oddName ?? "—",
                value: odds.oddValue ?? "—"
            )
        }
    }
}

func liveOdds(matchKey: String?) async throws -> [LiveOddsDTO] {
    try await instrumented(.liveOdds) {
        var query: [String: String] = [:]
        if let matchKey, !matchKey.isEmpty {
            query["match_key"] = matchKey
        }
        let response: APIEnvelope<[APILiveOdds]> = try await request(
            method: "get_live_odds",
            extraQuery: query
        )
        return (response.result ?? []).enumerated().map { index, odds in
            let matchKey = odds.matchKey.value
            return LiveOddsDTO(
                id: "\(matchKey)-\(odds.bookmakerName ?? "bk")-\(index)",
                matchKey: matchKey,
                bookmakerName: odds.bookmakerName ?? "Unknown",
                homeOdd: odds.homeOdd ?? "—",
                awayOdd: odds.awayOdd ?? "—",
                updatedAt: Self.parseLiveOddsTimestamp(odds.updatedAt) ?? .now
            )
        }
    }
}

private static let fixtureDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    // API Tennis expects UTC-aligned ISO dates for date_start/date_stop. Using
    // the user's local time zone shifts the calendar day forward or backward
    // around midnight and produces "incorrect date format" errors on the
    // server side, so we anchor the formatter to UTC.
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

private static func fixtureDates(from startDate: Date, to endDate: Date) -> [Date] {
    let calendar = Calendar(identifier: .gregorian)
    let start = calendar.startOfDay(for: min(startDate, endDate))
    let end = calendar.startOfDay(for: max(startDate, endDate))
    var dates: [Date] = []
    var cursor = start

    while cursor <= end {
        dates.append(cursor)
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
            break
        }
        cursor = next
    }

    return dates
}

private static func parseLiveOddsTimestamp(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let formatter = TennisAPIConfiguration.makePOSIXDateFormatter()
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm"] {
        formatter.dateFormat = format
        if let parsed = formatter.date(from: raw) {
            return parsed
        }
    }
    return nil
}

private func mapFixture(_ fixture: APIFixture) -> MatchDTO {
    let eventKey = fixture.eventKey.value
    let firstPlayerID = fixture.firstPlayerKey?.value ?? "p1-\(eventKey)"
    let secondPlayerID = fixture.secondPlayerKey?.value ?? "p2-\(eventKey)"
    let status = fixture.eventStatus ?? "Scheduled"
    let isLive = fixture.eventLive?.value == "1" || status.lowercased().contains("set") || status.lowercased() == "live"
    let firstPlayerName = fixture.eventFirstPlayer ?? "TBD"
    let secondPlayerName = fixture.eventSecondPlayer ?? "TBD"

    return MatchDTO(
        id: eventKey,
        date: parseDate(dateString: fixture.eventDate, timeString: fixture.eventTime) ?? .distantPast,
        tournamentId: fixture.tournamentKey?.value,
        player1Id: firstPlayerID,
        player2Id: secondPlayerID,
        player1Name: firstPlayerName,
        player2Name: secondPlayerName,
        player1Country: normalizeCountry(fixture.countryName),
        player2Country: normalizeCountry(fixture.countryName),
        score: displayScore(finalResult: fixture.eventFinalResult, gameResult: fixture.eventGameResult, scores: fixture.scores),
        status: status,
        isLive: isLive,
        serverName: serverName(from: fixture.eventServe, firstPlayer: firstPlayerName, secondPlayer: secondPlayerName),
        pointScore: pointScore(
            direct: fixture.pointScore ?? fixture.eventPointResult,
            first: fixture.eventFirstPlayerPoint?.value,
            second: fixture.eventSecondPlayerPoint?.value
        ),
        gameScore: fixture.eventGameResult ?? "",
        pointWinnerName: pointWinnerName(
            raw: fixture.pointWinner ?? fixture.eventPointWinner,
            firstPlayer: firstPlayerName,
            secondPlayer: secondPlayerName
        ),
        livePoints: livePointEvents(
            from: fixture.pointByPoint,
            matchDate: parseDate(dateString: fixture.eventDate, timeString: fixture.eventTime) ?? .distantPast,
            firstPlayer: firstPlayerName,
            secondPlayer: secondPlayerName
        ),
        advancedStats: mapAdvancedStats(fixture.statistics),
        orderOfPlay: mapOrderOfPlay(
            courtCandidates: [fixture.eventCourt, fixture.courtName, fixture.court, fixture.matchCourt, fixture.venue],
            orderCandidates: [fixture.orderOfPlay?.value, fixture.order?.value, fixture.matchOrder?.value, fixture.matchNumber?.value],
            source: "api-tennis"
        )
    )
}

private func mapH2H(_ match: APIH2HMatch) -> H2HMatchDTO {
    H2HMatchDTO(
        id: match.eventKey.value,
        date: parseDate(dateString: match.eventDate, timeString: match.eventTime) ?? .distantPast,
        tournamentName: match.tournamentName ?? "Torneio",
        firstPlayerName: match.eventFirstPlayer ?? "—",
        secondPlayerName: match.eventSecondPlayer ?? "—",
        winner: match.eventWinner ?? "",
        finalResult: match.eventFinalResult ?? ""
    )
}

private func mapPlayerProfile(_ profile: APIPlayerProfile, fallbackKey: String) -> PlayerProfileDTO {
    let key = profile.playerKey.map(String.init) ?? fallbackKey
    return PlayerProfileDTO(
        id: key,
        name: normalizePlayerName(profile.playerName),
        country: normalizeCountry(profile.playerCountry),
        birthDate: TournamentDTO.parseDate(profile.playerBirthday),
        bio: profile.playerBio,
        photoURL: profile.playerLogo.flatMap(URL.init(string:)),
        tournamentsPlayed: (profile.tournaments ?? []).compactMap(\.tournamentName),
        stats: (profile.stats ?? []).map {
            PlayerProfileDTO.Stat(
                season: $0.season ?? "",
                type: $0.type ?? "",
                value: $0.value ?? ""
            )
        }
    )
}
}
