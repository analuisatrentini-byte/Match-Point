import Foundation

nonisolated struct APIEnvelope<Result: Decodable>: Decodable {
    let success: Int
    let result: Result?
    let error: String?
    let message: String?

    var apiMessage: String? {
        error ?? message
    }
}

nonisolated struct APIString: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = ""
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let int = try? container.decode(Int.self) {
            self.value = String(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = double.rounded(.towardZero) == double ? String(Int(double)) : String(double)
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool ? "1" : "0"
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string-compatible API value."
                )
            )
        }
    }
}

nonisolated struct TournamentDTO: Decodable, Identifiable {
    let id: String
    let name: String
    let city: String
    let country: String
    let surface: String
    let tour: String
    let startDate: Date
    let endDate: Date

    init(from apiModel: APITournament) {
        id = apiModel.tournamentKey.value
        name = apiModel.tournamentName
        city = apiModel.tournamentLocation ?? "TBD"
        country = apiModel.countryName ?? "TBD"
        surface = apiModel.tournamentSurface ?? "Unknown"
        tour = apiModel.tournamentType ?? "ATP"
        startDate = Self.parseDate(apiModel.tournamentDateStart)
        endDate = Self.parseDate(apiModel.tournamentDateEnd)
    }

    init(
        id: String,
        name: String,
        city: String,
        country: String,
        surface: String,
        tour: String,
        startDate: Date,
        endDate: Date
    ) {
        self.id = id
        self.name = name
        self.city = city
        self.country = country
        self.surface = surface
        self.tour = tour
        self.startDate = startDate
        self.endDate = endDate
    }

    static func parseDate(_ string: String?) -> Date {
        TennisAPIConfiguration.parseAPIDate(string, formats: [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "dd-MM-yyyy",
            "dd.MM.yyyy",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]) ?? .distantPast
    }
}

struct PlayerDTO: Identifiable {
    let id: String
    let name: String
    let nationality: String
    let tour: String
    let birthDate: Date?
}

struct MatchDTO: Identifiable {
    let id: String
    let date: Date
    let tournamentId: String?
    let player1Id: String
    let player2Id: String
    let player1Name: String
    let player2Name: String
    let player1Country: String
    let player2Country: String
    let score: String
    let status: String
    let isLive: Bool
    let serverName: String
    let pointScore: String
    let gameScore: String
    let pointWinnerName: String?
    let livePoints: [LivePointDTO]
    let advancedStats: AdvancedMatchStatsSnapshot?
    let orderOfPlay: MatchOrderOfPlaySnapshot?

    init(
        id: String,
        date: Date,
        tournamentId: String?,
        player1Id: String,
        player2Id: String,
        player1Name: String,
        player2Name: String,
        player1Country: String,
        player2Country: String,
        score: String,
        status: String,
        isLive: Bool,
        serverName: String = "",
        pointScore: String = "",
        gameScore: String = "",
        pointWinnerName: String? = nil,
        livePoints: [LivePointDTO] = [],
        advancedStats: AdvancedMatchStatsSnapshot? = nil,
        orderOfPlay: MatchOrderOfPlaySnapshot? = nil
    ) {
        self.id = id
        self.date = date
        self.tournamentId = tournamentId
        self.player1Id = player1Id
        self.player2Id = player2Id
        self.player1Name = player1Name
        self.player2Name = player2Name
        self.player1Country = player1Country
        self.player2Country = player2Country
        self.score = score
        self.status = status
        self.isLive = isLive
        self.serverName = serverName
        self.pointScore = pointScore
        self.gameScore = gameScore
        self.pointWinnerName = pointWinnerName
        self.livePoints = livePoints
        self.advancedStats = advancedStats
        self.orderOfPlay = orderOfPlay
    }
}

struct LivePointDTO: Equatable {
    let timestamp: Date
    let title: String
    let detail: String
    let pointWinnerName: String?
    let serverName: String?
    let pointScore: String?
    let gameScore: String?
}

struct RankingEntryDTO: Identifiable {
    let id: String
    let playerId: String
    let playerName: String
    let nationality: String
    let rank: Int
    let points: Int
    let tour: String
}

nonisolated struct EventTypeDTO: Identifiable, Decodable {
    let id: String
    let type: String

    init(id: String, type: String) {
        self.id = id
        self.type = type
    }

    init(from apiModel: APIEvent) {
        self.id = apiModel.eventTypeKey.value
        self.type = apiModel.eventTypeType
    }
}

struct H2HMatchDTO: Identifiable {
    let id: String
    let date: Date
    let tournamentName: String
    let firstPlayerName: String
    let secondPlayerName: String
    let winner: String
    let finalResult: String
}

struct OddsDTO: Identifiable {
    let id: String
    let matchKey: String
    let bookmakerName: String
    let market: String
    let outcome: String
    let value: String
}

struct LiveOddsDTO: Identifiable {
    let id: String
    let matchKey: String
    let bookmakerName: String
    let homeOdd: String
    let awayOdd: String
    let updatedAt: Date
}

struct PlayerProfileDTO: Identifiable {
    let id: String
    let name: String
    let country: String
    let birthDate: Date?
    let bio: String?
    let photoURL: URL?
    let tournamentsPlayed: [String]
    let stats: [PlayerProfileDTO.Stat]

    struct Stat {
        let season: String
        let type: String
        let value: String
    }
}

nonisolated struct APITournament: Decodable {
    let tournamentKey: APIString
    let tournamentName: String
    let tournamentLocation: String?
    let countryName: String?
    let tournamentSurface: String?
    let tournamentType: String?
    let tournamentDateStart: String?
    let tournamentDateEnd: String?
}

nonisolated struct APIStanding: Decodable {
    let playerKey: APIString
    let playerName: String
    let countryName: String?
    let place: APIString
    let points: APIString
}

nonisolated struct APILiveMatch: Decodable {
    let eventKey: APIString
    let tournamentKey: APIString?
    let tournamentName: String?
    let eventDate: String?
    let eventTime: String?
    let eventFirstPlayer: String
    let firstPlayerKey: APIString?
    let eventSecondPlayer: String
    let secondPlayerKey: APIString?
    let eventFinalResult: String?
    let eventGameResult: String?
    let eventStatus: String?
    let eventServe: String?
    let eventLive: APIString?
    let eventPointResult: String?
    let pointScore: String?
    let eventFirstPlayerPoint: APIString?
    let eventSecondPlayerPoint: APIString?
    let pointWinner: String?
    let eventPointWinner: String?
    let pointByPoint: [APIPointByPointGame]?
    let countryName: String?
    let scores: [APIScore]?
    let statistics: LossyAPIMatchStatistics?
    let eventCourt: String?
    let courtName: String?
    let court: String?
    let venue: String?
    let matchCourt: String?
    let orderOfPlay: APIString?
    let order: APIString?
    let matchOrder: APIString?
    let matchNumber: APIString?

    enum CodingKeys: String, CodingKey {
        case eventKey
        case tournamentKey
        case tournamentName
        case eventDate
        case eventTime
        case eventFirstPlayer
        case firstPlayerKey
        case eventSecondPlayer
        case secondPlayerKey
        case eventFinalResult
        case eventGameResult
        case eventStatus
        case eventServe
        case eventLive
        case eventPointResult
        case pointScore
        case eventFirstPlayerPoint
        case eventSecondPlayerPoint
        case pointWinner
        case eventPointWinner
        case pointByPoint = "pointbypoint"
        case countryName
        case scores
        case statistics
        case eventCourt
        case courtName
        case court
        case venue
        case matchCourt
        case orderOfPlay
        case order
        case matchOrder
        case matchNumber
    }
}

nonisolated struct APIEvent: Decodable {
    let eventTypeKey: APIString
    let eventTypeType: String
}

nonisolated struct APIFixture: Decodable {
    let eventKey: APIString
    let tournamentKey: APIString?
    let tournamentName: String?
    let eventDate: String?
    let eventTime: String?
    let eventFirstPlayer: String?
    let firstPlayerKey: APIString?
    let eventSecondPlayer: String?
    let secondPlayerKey: APIString?
    let eventFinalResult: String?
    let eventGameResult: String?
    let eventStatus: String?
    let countryName: String?
    let tournamentRound: String?
    let tournamentSeason: String?
    let eventWinner: String?
    let eventType: String?
    let eventServe: String?
    let eventLive: APIString?
    let eventPointResult: String?
    let pointScore: String?
    let eventFirstPlayerPoint: APIString?
    let eventSecondPlayerPoint: APIString?
    let pointWinner: String?
    let eventPointWinner: String?
    let pointByPoint: [APIPointByPointGame]?
    let scores: [APIScore]?
    let statistics: LossyAPIMatchStatistics?
    let eventCourt: String?
    let courtName: String?
    let court: String?
    let venue: String?
    let matchCourt: String?
    let orderOfPlay: APIString?
    let order: APIString?
    let matchOrder: APIString?
    let matchNumber: APIString?

    enum CodingKeys: String, CodingKey {
        case eventKey
        case tournamentKey
        case tournamentName
        case eventDate
        case eventTime
        case eventFirstPlayer
        case firstPlayerKey
        case eventSecondPlayer
        case secondPlayerKey
        case eventFinalResult
        case eventGameResult
        case eventStatus
        case countryName
        case tournamentRound
        case tournamentSeason
        case eventWinner
        case eventType
        case eventServe
        case eventLive
        case eventPointResult
        case pointScore
        case eventFirstPlayerPoint
        case eventSecondPlayerPoint
        case pointWinner
        case eventPointWinner
        case pointByPoint = "pointbypoint"
        case scores
        case statistics
        case eventCourt
        case courtName
        case court
        case venue
        case matchCourt
        case orderOfPlay
        case order
        case matchOrder
        case matchNumber
    }
}

nonisolated struct APIScore: Decodable {
    let scoreFirst: APIString?
    let scoreSecond: APIString?
    let scoreSet: APIString?
}

nonisolated struct APIPointByPointGame: Decodable {
    let setNumber: String?
    let numberGame: APIString?
    let playerServed: String?
    let serveWinner: String?
    let serveLost: String?
    let score: String?
    let points: [APIPointByPointPoint]?
}

nonisolated struct APIPointByPointPoint: Decodable {
    let numberPoint: APIString?
    let score: String?
    let breakPoint: String?
    let setPoint: String?
    let matchPoint: String?
}

nonisolated struct APIMatchStatistic: Decodable {
    let type: String
    let firstPlayer: APIString?
    let secondPlayer: APIString?

    init(type: String, firstPlayer: APIString?, secondPlayer: APIString?) {
        self.type = type
        self.firstPlayer = firstPlayer
        self.secondPlayer = secondPlayer
    }

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case statisticName
        case statisticType
        case firstPlayer
        case secondPlayer
        case home
        case away
        case player1
        case player2
        case valueFirst
        case valueSecond
        case statisticFirst
        case statisticSecond
        case statisticHome
        case statisticAway
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type))
            ?? (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .statisticName))
            ?? (try? container.decode(String.self, forKey: .statisticType))
            ?? ""
        firstPlayer = Self.decodeFirstValue(from: container, keys: [.firstPlayer, .home, .player1, .valueFirst, .statisticFirst, .statisticHome])
        secondPlayer = Self.decodeFirstValue(from: container, keys: [.secondPlayer, .away, .player2, .valueSecond, .statisticSecond, .statisticAway])
    }

    private static func decodeFirstValue(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> APIString? {
        for key in keys {
            if let value = try? container.decode(APIString.self, forKey: key), !value.value.isEmpty {
                return value
            }
        }
        return nil
    }
}

nonisolated struct LossyAPIMatchStatistics: Decodable {
    let values: [APIMatchStatistic]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([APIMatchStatistic].self) {
            self.values = values
        } else if let keyed = try? container.decode([String: APIMatchStatistic].self) {
            self.values = keyed.map { key, value in
                if value.type.isEmpty {
                    return APIMatchStatistic(type: key, firstPlayer: value.firstPlayer, secondPlayer: value.secondPlayer)
                }
                return value
            }
        } else {
            self.values = []
        }
    }
}

nonisolated struct APIH2HEnvelope: Decodable {
    let firstPlayerResults: [APIH2HMatch]?
    let secondPlayerResults: [APIH2HMatch]?
    let h2H: [APIH2HMatch]?

    enum CodingKeys: String, CodingKey {
        case firstPlayerResults = "firstPlayer_results"
        case secondPlayerResults = "secondPlayer_results"
        case h2H = "H2H"
    }
}

nonisolated struct APIH2HMatch: Decodable {
    let eventKey: APIString
    let eventDate: String?
    let eventTime: String?
    let tournamentName: String?
    let eventFirstPlayer: String?
    let eventSecondPlayer: String?
    let eventFinalResult: String?
    let eventWinner: String?
}

nonisolated struct APIOdds: Decodable {
    let matchKey: APIString
    let bookmakerName: String?
    let market: String?
    let oddName: String?
    let oddValue: String?

    enum CodingKeys: String, CodingKey {
        case matchKey = "match_key"
        case bookmakerName = "bookmaker_name"
        case market
        case oddName = "odd_name"
        case oddValue = "odd_value"
    }
}

nonisolated struct APILiveOdds: Decodable {
    let matchKey: APIString
    let bookmakerName: String?
    let homeOdd: String?
    let awayOdd: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case matchKey = "match_key"
        case bookmakerName = "bookmaker_name"
        case homeOdd = "home_od"
        case awayOdd = "away_od"
        case updatedAt = "updated"
    }
}

nonisolated struct APIPlayerProfile: Decodable {
    let playerKey: Int?
    let playerName: String
    let playerCountry: String?
    let playerBirthday: String?
    let playerBio: String?
    let playerLogo: String?
    let tournaments: [APIPlayerTournament]?
    let stats: [APIPlayerStat]?
}

nonisolated struct APIPlayerTournament: Decodable {
    let tournamentName: String?
}

nonisolated struct APIPlayerStat: Decodable {
    let season: String?
    let type: String?
    let value: String?
}
