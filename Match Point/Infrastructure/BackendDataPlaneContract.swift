import Foundation

/// Versioned contract the mobile app expects from the always-on backend.
/// The app still renders local fallbacks, but production data freshness, audit
/// history and remote push decisions belong to this server-side data plane.
nonisolated struct BackendDataPlaneContract: Codable, Equatable {
    var schemaVersion: Int = 1
    var ingestion: Ingestion
    var reconciliation: Reconciliation
    var audit: Audit
    var eventQueue: EventQueue
    var pushDecisioning: PushDecisioning

    static let continuousTennisIngestion = BackendDataPlaneContract(
        ingestion: .init(
            mode: .alwaysOn,
            providers: [.apiTennisREST, .apiTennisWebSocket],
            livePollFallbackSeconds: 30,
            fixtureRefreshSeconds: 300,
            rankingRefreshSeconds: 3_600
        ),
        reconciliation: .init(
            identityKeys: [
                .init(entity: .match, field: "externalID"),
                .init(entity: .player, field: "externalKey"),
                .init(entity: .tournament, field: "externalKey"),
                .init(entity: .rankingEntry, field: "externalKey")
            ],
            duplicatePolicy: .mergeByProviderTimestamp,
            idempotencyWindowSeconds: 86_400
        ),
        audit: .init(
            scoreHistoryRetentionDays: 365,
            captureRawProviderFrames: true,
            redactSecrets: true
        ),
        eventQueue: .init(
            topics: [.matchStateChanged, .pointStateChanged, .subscriptionChanged, .pushDelivery],
            delivery: .atLeastOnce,
            maxRetrySeconds: 900
        ),
        pushDecisioning: .init(
            owner: .server,
            supportedEvents: [
                .upcoming,
                .walkOn,
                .started,
                .finished,
                .breakServe,
                .finalSetBreakServe,
                .setPoint,
                .matchPoint,
                .tiebreak,
                .delayed,
                .interrupted,
                .courtChanged
            ],
            requiresDeviceOptIn: true,
            requiresFavoriteScope: true
        )
    )
}

nonisolated extension BackendDataPlaneContract {
    struct Ingestion: Codable, Equatable {
        enum Mode: String, Codable {
            case alwaysOn = "always-on"
        }

        enum Provider: String, Codable {
            case apiTennisREST = "api-tennis.rest"
            case apiTennisWebSocket = "api-tennis.websocket"
        }

        var mode: Mode
        var providers: [Provider]
        var livePollFallbackSeconds: Int
        var fixtureRefreshSeconds: Int
        var rankingRefreshSeconds: Int
    }

    struct Reconciliation: Codable, Equatable {
        enum Entity: String, Codable {
            case match
            case player
            case tournament
            case rankingEntry
        }

        enum DuplicatePolicy: String, Codable {
            case mergeByProviderTimestamp = "merge-by-provider-timestamp"
        }

        struct IdentityKey: Codable, Equatable {
            var entity: Entity
            var field: String
        }

        var identityKeys: [IdentityKey]
        var duplicatePolicy: DuplicatePolicy
        var idempotencyWindowSeconds: Int
    }

    struct Audit: Codable, Equatable {
        var scoreHistoryRetentionDays: Int
        var captureRawProviderFrames: Bool
        var redactSecrets: Bool
    }

    struct EventQueue: Codable, Equatable {
        enum Topic: String, Codable {
            case matchStateChanged = "match.state.changed"
            case pointStateChanged = "match.point.changed"
            case subscriptionChanged = "push.subscription.changed"
            case pushDelivery = "push.delivery"
        }

        enum Delivery: String, Codable {
            case atLeastOnce = "at-least-once"
        }

        var topics: [Topic]
        var delivery: Delivery
        var maxRetrySeconds: Int
    }

    struct PushDecisioning: Codable, Equatable {
        enum Owner: String, Codable {
            case server
        }

        var owner: Owner
        var supportedEvents: [RemotePushEventRule.Event]
        var requiresDeviceOptIn: Bool
        var requiresFavoriteScope: Bool
    }
}
