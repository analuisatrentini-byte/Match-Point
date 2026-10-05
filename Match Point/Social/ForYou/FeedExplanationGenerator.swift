import Combine
import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device natural-language rationale for a "For You" feed card.
/// Wraps `FoundationModels` when available; falls back to a deterministic
/// sentence built from the already-computed `MatchRelevanceReason` list so the
/// UI always has *some* explanation to show — the AI path is a progressive
/// enhancement, not a hard dependency.
@MainActor
final class FeedExplanationGenerator: ObservableObject {
    static let shared = FeedExplanationGenerator()

    enum Availability: Equatable {
        case ready
        case downloading
        case notEligible
        case appleIntelligenceOff
        case unsupported
        case unknown
    }

    @Published private(set) var availability: Availability = .unknown

    /// In-memory LRU cache keyed by (matchID, reasonsSignature). Bounded so
    /// long feed sessions don't leak.
    private struct CacheEntry {
        let text: String
        let signature: String
    }
    private var cache: [UUID: CacheEntry] = [:]
    private let cacheLimit = 32
    private var cacheOrder: [UUID] = []

    private var inFlight: Set<UUID> = []

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                availability = .ready
            case .unavailable(.deviceNotEligible):
                availability = .notEligible
            case .unavailable(.appleIntelligenceNotEnabled):
                availability = .appleIntelligenceOff
            case .unavailable(.modelNotReady):
                availability = .downloading
            case .unavailable:
                availability = .unknown
            }
        } else {
            availability = .unsupported
        }
#else
        availability = .unsupported
#endif
    }

    /// Returns a cached explanation if one exists for this match/reasons
    /// combination. Never triggers generation — callers use `generate` for
    /// that.
    func cachedExplanation(for matchID: UUID, reasonsSignature: String) -> String? {
        guard let entry = cache[matchID], entry.signature == reasonsSignature else { return nil }
        return entry.text
    }

    /// Generates (or returns cached) explanation for a card. On unavailable or
    /// error paths it falls back to a heuristic sentence assembled from the
    /// existing relevance reasons — the caller doesn't need to distinguish AI
    /// output from the fallback.
    func generate(
        for matchID: UUID,
        matchLabel: String,
        reasons: [MatchRelevanceReason],
        contextSummary: String
    ) async -> String {
        let signature = Self.signature(for: reasons)
        if let cached = cachedExplanation(for: matchID, reasonsSignature: signature) {
            return cached
        }
        guard !inFlight.contains(matchID) else {
            return fallbackText(matchLabel: matchLabel, reasons: reasons, contextSummary: contextSummary)
        }

        inFlight.insert(matchID)
        defer { inFlight.remove(matchID) }

        refreshAvailability()

        let text: String
        if availability == .ready {
            text = await runModel(
                matchLabel: matchLabel,
                reasons: reasons,
                contextSummary: contextSummary
            ) ?? fallbackText(matchLabel: matchLabel, reasons: reasons, contextSummary: contextSummary)
        } else {
            text = fallbackText(matchLabel: matchLabel, reasons: reasons, contextSummary: contextSummary)
        }

        insertCache(matchID: matchID, text: text, signature: signature)
        return text
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func insertCache(matchID: UUID, text: String, signature: String) {
        cache[matchID] = CacheEntry(text: text, signature: signature)
        if let existing = cacheOrder.firstIndex(of: matchID) {
            cacheOrder.remove(at: existing)
        }
        cacheOrder.append(matchID)
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func runModel(
        matchLabel: String,
        reasons: [MatchRelevanceReason],
        contextSummary: String
    ) async -> String? {
#if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { return nil }

        let reasonList = reasons
            .prefix(4)
            .map { "- \($0.label) (peso \($0.points))" }
            .joined(separator: "\n")

        let instructions = """
        Você explica em português brasileiro por que um card apareceu no feed \
        "Para Você" de um app de tênis. Regras: uma frase curta (máximo 22 \
        palavras), tom informal, evite jargão. Use os fatos fornecidos sem \
        inventar detalhes. Não use emojis nem gírias.
        """
        let prompt = """
        Partida: \(matchLabel)
        Contexto: \(contextSummary)
        Sinais que ativaram o card (em ordem de peso):
        \(reasonList)

        Escreva uma única frase começando com "Porque".
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.4)
            let response = try await session.respond(to: prompt, options: options)
            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            AppLogger.sync.warning("FoundationModels explanation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
#else
        return nil
#endif
    }

    private func fallbackText(matchLabel: String, reasons: [MatchRelevanceReason], contextSummary: String) -> String {
        let top = reasons.prefix(3).map(\.label)
        let context = contextSummary.isEmpty ? "" : " (\(contextSummary))"
        if top.isEmpty {
            return "Porque \(matchLabel)\(context) ainda tem contexto útil para ranking, forma ou favoritos."
        }
        return "Porque \(matchLabel)\(context) combina " + top.joined(separator: ", ") + "."
    }

    private static func signature(for reasons: [MatchRelevanceReason]) -> String {
        reasons.map { "\($0.symbol)|\($0.label)|\($0.points)" }.joined(separator: ";")
    }
}
