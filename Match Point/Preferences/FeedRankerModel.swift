import Combine
import Foundation
import OSLog

/// On-device learn-to-rank model for the "For You" feed. Uses logistic regression
/// with SGD updates: every time the user opens a match card, that match becomes
/// a positive sample and its unopened peers (matches shown alongside it) become
/// negative samples. Weights persist in UserDefaults and blend into
/// `MatchIntelligence.relevanceScore` as a bonus once the model has warmed up.
///
/// This is deliberately simple — a Swift-native linear model, no Core ML or
/// external framework. The signal is weak (implicit feedback from clicks) but
/// the model captures individual preference drift (ATP vs WTA, morning vs
/// evening, top-10 obsession vs underdog affinity) that the hand-tuned
/// `MatchIntelligence` weights can't personalize.
nonisolated struct FeedRankerFeatures: Codable, Equatable {
    var isLive: Double
    var isUpcoming: Double
    /// Normalized hours-until-start, capped at 24h. 0 = far away, 1 = imminent.
    var proximity: Double
    var hasFavoritePlayer: Double
    var isFavoriteTournament: Double
    var isFavoriteMatch: Double
    var hasTop10Player: Double
    var breakPointActive: Double
    /// Behavior affinity signals normalized to 0..1 (capped at count=10).
    var matchAffinity: Double
    var playerAffinity: Double
    var tournamentAffinity: Double
    var isATP: Double
    var isWTA: Double

    static let dimension = 13
    static let zero = FeedRankerFeatures(
        isLive: 0, isUpcoming: 0, proximity: 0,
        hasFavoritePlayer: 0, isFavoriteTournament: 0, isFavoriteMatch: 0,
        hasTop10Player: 0, breakPointActive: 0,
        matchAffinity: 0, playerAffinity: 0, tournamentAffinity: 0,
        isATP: 0, isWTA: 0
    )

    var vector: [Double] {
        [
            isLive, isUpcoming, proximity,
            hasFavoritePlayer, isFavoriteTournament, isFavoriteMatch,
            hasTop10Player, breakPointActive,
            matchAffinity, playerAffinity, tournamentAffinity,
            isATP, isWTA
        ]
    }
}

nonisolated struct FeedRankerWeights: Codable, Equatable {
    var weights: [Double]
    var bias: Double
    /// Total training samples processed. Used to gate the "warmed up" state so
    /// early cold-start predictions don't hijack the heuristic score.
    var samplesSeen: Int

    static let warmupSamples = 8

    static let initial: FeedRankerWeights = {
        // Non-zero seeds so a fresh install still nudges toward obvious signals
        // (live, favorites) before the user has trained anything. SGD refines
        // from here rather than starting flat.
        FeedRankerWeights(
            weights: [
                0.6,  // isLive
                0.3,  // isUpcoming
                0.2,  // proximity
                0.7,  // hasFavoritePlayer
                0.4,  // isFavoriteTournament
                0.5,  // isFavoriteMatch
                0.3,  // hasTop10Player
                0.4,  // breakPointActive
                0.2,  // matchAffinity
                0.4,  // playerAffinity
                0.2,  // tournamentAffinity
                0.0,  // isATP
                0.0   // isWTA
            ],
            bias: -1.0,
            samplesSeen: 0
        )
    }()

    var isWarmedUp: Bool { samplesSeen >= Self.warmupSamples }
}

@MainActor
final class FeedRankerModel: ObservableObject {
    static let shared = FeedRankerModel()

    @Published private(set) var weights: FeedRankerWeights

    /// SGD learning rate. Deliberately small — feedback is sparse and noisy, we
    /// don't want a single click to swing weights dramatically.
    private let learningRate: Double = 0.05
    /// L2 regularization. Keeps weights from drifting to extreme values when
    /// the training set is tiny.
    private let l2: Double = 0.001

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "match-point.feed-ranker.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        let loaded = Self.load(from: defaults, key: storageKey)
        self.weights = loaded
        FeedRankerBridge.updateCache(with: loaded)
    }

    /// Sigmoid probability that this feature vector represents a match the user
    /// would open. Returns 0..1.
    func probability(for features: FeedRankerFeatures) -> Double {
        let logit = zip(weights.weights, features.vector).reduce(0.0) { $0 + $1.0 * $1.1 } + weights.bias
        return 1.0 / (1.0 + exp(-logit))
    }

    /// Integer bonus in the range 0...maxBonus that callers can add to the
    /// heuristic relevance score. Returns 0 until the model has trained on at
    /// least `warmupSamples` samples so cold-start predictions don't distort
    /// the feed.
    func relevanceBoost(for features: FeedRankerFeatures, maxBonus: Int = 30) -> Int {
        guard weights.isWarmedUp else { return 0 }
        return Int((probability(for: features) * Double(maxBonus)).rounded())
    }

    /// Applies one SGD update per (features, label) pair. Callers typically
    /// pass one positive (the opened match) and 0-3 negatives (peer matches
    /// shown alongside but not opened).
    func train(samples: [(features: FeedRankerFeatures, label: Double)]) {
        guard !samples.isEmpty else { return }

        var draft = weights
        for sample in samples {
            let prediction = predictInternal(features: sample.features, weights: draft.weights, bias: draft.bias)
            let error = sample.label - prediction

            for index in 0..<draft.weights.count {
                let gradient = error * sample.features.vector[index]
                draft.weights[index] += learningRate * (gradient - l2 * draft.weights[index])
            }
            draft.bias += learningRate * error
            draft.samplesSeen += 1
        }

        weights = draft
        persist(draft)
        FeedRankerBridge.updateCache(with: draft)
    }

    func reset() {
        weights = FeedRankerWeights.initial
        defaults.removeObject(forKey: storageKey)
        FeedRankerBridge.updateCache(with: weights)
    }

    private func predictInternal(features: FeedRankerFeatures, weights: [Double], bias: Double) -> Double {
        let logit = zip(weights, features.vector).reduce(0.0) { $0 + $1.0 * $1.1 } + bias
        return 1.0 / (1.0 + exp(-logit))
    }

    private func persist(_ value: FeedRankerWeights) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: storageKey)
        } catch {
            AppLogger.sync.warning("Failed to persist feed ranker weights: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> FeedRankerWeights {
        guard let data = defaults.data(forKey: key) else { return .initial }
        do {
            let decoded = try JSONDecoder().decode(FeedRankerWeights.self, from: data)
            // Guard against a corrupt payload that would break the dot product.
            guard decoded.weights.count == FeedRankerFeatures.dimension else { return .initial }
            return decoded
        } catch {
            AppLogger.sync.warning("Failed to decode feed ranker weights: \(error.localizedDescription, privacy: .public)")
            return .initial
        }
    }
}

// MARK: - Feature extraction

enum FeedRankerFeatureExtractor {
    /// Builds a feature vector for a single match against the current ranking
    /// snapshot and behavior signals. Pure — safe to call from any actor.
    static func features(
        for match: TennisMatch,
        rankByPlayerID: [UUID: Int],
        behavior: BehaviorPersonalizationSnapshot?,
        now: Date = .now
    ) -> FeedRankerFeatures {
        var features = FeedRankerFeatures.zero

        features.isLive = match.isLive ? 1 : 0
        features.isUpcoming = match.isUpcoming ? 1 : 0
        features.isFavoriteMatch = match.isFavorite ? 1 : 0

        if match.isUpcoming {
            let hoursUntil = max(0, min(24, match.date.timeIntervalSince(now) / 3600))
            features.proximity = (24 - hoursUntil) / 24
        }

        let favoritePlayer = (match.player1?.isFavorite == true) || (match.player2?.isFavorite == true)
        features.hasFavoritePlayer = favoritePlayer ? 1 : 0

        features.isFavoriteTournament = match.tournament?.isFavorite == true ? 1 : 0

        let top10 = [match.player1, match.player2]
            .compactMap { $0 }
            .contains { player in
                if let rank = rankByPlayerID[player.id], rank <= 10 { return true }
                return false
            }
        features.hasTop10Player = top10 ? 1 : 0

        features.breakPointActive = MatchIntelligence.breakPointLabel(for: match) != "Sem break point" ? 1 : 0

        if let behavior {
            let matchAffinity = behavior.matchViews[match.behaviorKey]?.count ?? 0
            features.matchAffinity = min(1.0, Double(matchAffinity) / 10.0)

            let playerAffinity = [match.player1, match.player2]
                .compactMap { $0 }
                .compactMap { behavior.playerViews[$0.behaviorKey]?.count }
                .max() ?? 0
            features.playerAffinity = min(1.0, Double(playerAffinity) / 10.0)

            let tournamentAffinity = match.tournament.flatMap { behavior.tournamentViews[$0.behaviorKey]?.count } ?? 0
            features.tournamentAffinity = min(1.0, Double(tournamentAffinity) / 10.0)
        }

        // The tour signal captures preference between circuits — the model
        // learns from the click distribution whether the user leans ATP, WTA,
        // or both.
        let atp = (match.player1?.isWTA == false) || (match.player2?.isWTA == false) || (match.tournament?.tour == .atp)
        let wta = (match.player1?.isWTA == true) || (match.player2?.isWTA == true) || (match.tournament?.tour == .wta)
        features.isATP = atp ? 1 : 0
        features.isWTA = wta ? 1 : 0

        return features
    }
}

// MARK: - Actor-safe read bridge

/// Nonisolated snapshot of the ranker weights so `MatchIntelligence`'s scoring
/// path (called from sort comparators and background contexts) can read the
/// current model state without hopping to the main actor. The @MainActor
/// `FeedRankerModel` pushes updates here after every train / reset.
enum FeedRankerBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedWeights: FeedRankerWeights = .initial

    static func updateCache(with weights: FeedRankerWeights) {
        lock.lock()
        cachedWeights = weights
        lock.unlock()
    }

    static func snapshot() -> FeedRankerWeights {
        lock.lock()
        defer { lock.unlock() }
        return cachedWeights
    }

    static func currentBoost(
        for match: TennisMatch,
        rankByPlayerID: [UUID: Int],
        behavior: BehaviorPersonalizationSnapshot?
    ) -> Int {
        let snap = snapshot()
        guard snap.isWarmedUp else { return 0 }

        let features = FeedRankerFeatureExtractor.features(
            for: match,
            rankByPlayerID: rankByPlayerID,
            behavior: behavior
        )
        let logit = zip(snap.weights, features.vector).reduce(0.0) { $0 + $1.0 * $1.1 } + snap.bias
        let probability = 1.0 / (1.0 + exp(-logit))
        return Int((probability * 30.0).rounded())
    }
}
