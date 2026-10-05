import Combine
import Foundation
import OSLog

// MARK: - ResponsibleGamblingPreferences
//
// Guarda os limites que o próprio usuário configura pra si mesmo em relação
// ao uso do wizard de apostas (mesmo com pontos simbólicos, o hábito de
// escalar stake pode migrar pra jogo real). Tudo persistido em UserDefaults
// via `ResponsibleGamblingStore` — não sincroniza com nuvem, já que a
// configuração é pessoal por dispositivo.
//
// Cada campo é opcional (`nil` = sem limite ativo) pra permitir opt-in
// granular sem impor um valor default que virou "resistência silenciosa" —
// se o usuário não configura, nenhum bloqueio dispara, mas os avisos
// informativos ("uso simbólico") ainda aparecem.

nonisolated struct ResponsibleGamblingPreferences: Codable, Equatable {
    /// Máximo de pontos apostados em 24h. nil = sem limite.
    var dailyStakeLimit: Int?
    /// Máximo de pontos apostados em 7 dias.
    var weeklyStakeLimit: Int?
    /// Máximo de apostas colocadas em 24h.
    var dailyBetCountLimit: Int?
    /// Ativa cooldown após sequência de perdas — impede novas apostas por
    /// N horas se o usuário perdeu `n` apostas seguidas.
    var lossCooldownThreshold: Int?
    var lossCooldownHours: Int?
    /// Data até a qual o usuário se auto-excluiu de qualquer aposta nova.
    var selfExclusionUntil: Date?
    /// Marca se o usuário já leu o aviso obrigatório de risco. `false` → o
    /// primeiro placeBet dispara um sheet de acknowledgement.
    var acknowledgedRiskDisclosure: Bool

    init(
        dailyStakeLimit: Int? = nil,
        weeklyStakeLimit: Int? = nil,
        dailyBetCountLimit: Int? = nil,
        lossCooldownThreshold: Int? = nil,
        lossCooldownHours: Int? = nil,
        selfExclusionUntil: Date? = nil,
        acknowledgedRiskDisclosure: Bool = false
    ) {
        self.dailyStakeLimit = dailyStakeLimit
        self.weeklyStakeLimit = weeklyStakeLimit
        self.dailyBetCountLimit = dailyBetCountLimit
        self.lossCooldownThreshold = lossCooldownThreshold
        self.lossCooldownHours = lossCooldownHours
        self.selfExclusionUntil = selfExclusionUntil
        self.acknowledgedRiskDisclosure = acknowledgedRiskDisclosure
    }

    private enum CodingKeys: String, CodingKey {
        case dailyStakeLimit, weeklyStakeLimit, dailyBetCountLimit
        case lossCooldownThreshold, lossCooldownHours
        case selfExclusionUntil, acknowledgedRiskDisclosure
    }

    // Decoder tolerante a versões futuras — todos os campos são opcionais no
    // JSON, então adicionar novos limites não quebra usuários existentes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyStakeLimit = try c.decodeIfPresent(Int.self, forKey: .dailyStakeLimit)
        weeklyStakeLimit = try c.decodeIfPresent(Int.self, forKey: .weeklyStakeLimit)
        dailyBetCountLimit = try c.decodeIfPresent(Int.self, forKey: .dailyBetCountLimit)
        lossCooldownThreshold = try c.decodeIfPresent(Int.self, forKey: .lossCooldownThreshold)
        lossCooldownHours = try c.decodeIfPresent(Int.self, forKey: .lossCooldownHours)
        selfExclusionUntil = try c.decodeIfPresent(Date.self, forKey: .selfExclusionUntil)
        acknowledgedRiskDisclosure = try c.decodeIfPresent(Bool.self, forKey: .acknowledgedRiskDisclosure) ?? false
    }

    var hasAnyLimit: Bool {
        dailyStakeLimit != nil
            || weeklyStakeLimit != nil
            || dailyBetCountLimit != nil
            || lossCooldownThreshold != nil
            || selfExclusionUntil != nil
    }
}

// MARK: - ResponsibleGamblingDecision

enum ResponsibleGamblingDecision: Equatable {
    /// Aposta pode ser criada normalmente.
    case allowed
    /// Aposta acima do limite recente ou dentro do cooldown — deve ser
    /// bloqueada com mensagem clara pro usuário.
    case blocked(reason: BlockReason)
    /// Aposta é permitida mas o usuário está próximo do limite. Chamador
    /// pode mostrar um aviso e pedir confirmação explícita.
    case warned(reason: WarnReason)

    enum BlockReason: Equatable {
        case selfExclusion(until: Date)
        case dailyStakeExceeded(limit: Int, currentUse: Int)
        case weeklyStakeExceeded(limit: Int, currentUse: Int)
        case dailyBetCountExceeded(limit: Int, currentUse: Int)
        case lossCooldownActive(until: Date, consecutiveLosses: Int)
    }

    enum WarnReason: Equatable {
        /// Usuário ainda não confirmou o aviso obrigatório de risco.
        case pendingRiskDisclosure
        /// Já usou ≥ 80% do limite diário.
        case approachingDailyStakeLimit(percentUsed: Int)
        /// Stake individual é > 40% do saldo — comportamento clássico de tilt.
        case largeStakeRelativeToBalance(percentOfBalance: Int)
    }
}

// MARK: - ResponsibleGamblingGate
//
// Função pura (sem estado, sem side-effects) que decide se uma tentativa de
// aposta deve ser permitida, avisada ou bloqueada. Testável isoladamente —
// nenhuma dependência de View, Store ou SwiftData.

enum ResponsibleGamblingGate {
    static func evaluate(
        preferences: ResponsibleGamblingPreferences,
        existingBets: [PointBet],
        requestedStake: Int,
        currentBalance: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ResponsibleGamblingDecision {
        // 1. Auto-exclusão trumps everything.
        if let until = preferences.selfExclusionUntil, until > now {
            return .blocked(reason: .selfExclusion(until: until))
        }

        // 2. Cooldown por perdas consecutivas.
        if let threshold = preferences.lossCooldownThreshold,
           let hours = preferences.lossCooldownHours,
           threshold > 0, hours > 0 {
            let recentSorted = existingBets
                .filter { $0.status == .won || $0.status == .lost }
                .sorted { ($0.settledAt ?? .distantPast) > ($1.settledAt ?? .distantPast) }
            var streak = 0
            for bet in recentSorted {
                if bet.status == .lost { streak += 1 } else { break }
            }
            if streak >= threshold, let lastLoss = recentSorted.first?.settledAt {
                let cooldownEnds = lastLoss.addingTimeInterval(TimeInterval(hours) * 3600)
                if cooldownEnds > now {
                    return .blocked(reason: .lossCooldownActive(until: cooldownEnds, consecutiveLosses: streak))
                }
            }
        }

        // 3. Limite diário/semanal de stake.
        let dailyStakeUse = totalStake(in: existingBets, since: startOfDay(now: now, calendar: calendar))
        let weeklyStakeUse = totalStake(in: existingBets, since: startOfWeek(now: now, calendar: calendar))

        if let daily = preferences.dailyStakeLimit, dailyStakeUse + requestedStake > daily {
            return .blocked(reason: .dailyStakeExceeded(limit: daily, currentUse: dailyStakeUse))
        }
        if let weekly = preferences.weeklyStakeLimit, weeklyStakeUse + requestedStake > weekly {
            return .blocked(reason: .weeklyStakeExceeded(limit: weekly, currentUse: weeklyStakeUse))
        }

        // 4. Limite de número de apostas por dia.
        if let dailyCountLimit = preferences.dailyBetCountLimit {
            let placedToday = existingBets
                .filter { $0.createdAt >= startOfDay(now: now, calendar: calendar) }
                .count
            if placedToday + 1 > dailyCountLimit {
                return .blocked(reason: .dailyBetCountExceeded(limit: dailyCountLimit, currentUse: placedToday))
            }
        }

        // 5. Avisos "brandos" (não bloqueiam, mas o chamador pode mostrar
        //    confirmação extra).
        if !preferences.acknowledgedRiskDisclosure {
            return .warned(reason: .pendingRiskDisclosure)
        }
        if let daily = preferences.dailyStakeLimit, daily > 0 {
            let projected = dailyStakeUse + requestedStake
            let percent = Int((Double(projected) / Double(daily)) * 100)
            if percent >= 80 {
                return .warned(reason: .approachingDailyStakeLimit(percentUsed: percent))
            }
        }
        if currentBalance > 0 {
            let percentOfBalance = Int((Double(requestedStake) / Double(currentBalance)) * 100)
            if percentOfBalance >= 40 {
                return .warned(reason: .largeStakeRelativeToBalance(percentOfBalance: percentOfBalance))
            }
        }

        return .allowed
    }

    private static func totalStake(in bets: [PointBet], since date: Date) -> Int {
        bets
            .filter { $0.createdAt >= date }
            .reduce(0) { $0 + $1.stake }
    }

    private static func startOfDay(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    private static func startOfWeek(now: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return calendar.date(from: components) ?? calendar.startOfDay(for: now)
    }
}

// MARK: - ResponsibleGamblingStore
//
// Segue o mesmo padrão de AlertPreferencesStore/ExperiencePreferencesStore:
// singleton `.shared`, persistência em UserDefaults como JSON, expõe as
// preferências como @Published pra a UI observar.

@MainActor
final class ResponsibleGamblingStore: ObservableObject {
    static let shared = ResponsibleGamblingStore()

    @Published private(set) var preferences: ResponsibleGamblingPreferences

    private let defaults: UserDefaults
    private let preferencesKey = "match-point.responsible-gambling-preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: preferencesKey) {
            do {
                self.preferences = try JSONDecoder().decode(ResponsibleGamblingPreferences.self, from: data)
            } catch {
                AppLogger.persistence.error("Failed to decode ResponsibleGamblingPreferences; using defaults")
                AppLogger.recordFailure(category: "preferences", operation: "ResponsibleGamblingPreferences.decode", error: error)
                self.preferences = ResponsibleGamblingPreferences()
            }
        } else {
            self.preferences = ResponsibleGamblingPreferences()
        }
    }

    func update(_ mutate: (inout ResponsibleGamblingPreferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        preferences = updated
        do {
            let encoded = try JSONEncoder().encode(updated)
            defaults.set(encoded, forKey: preferencesKey)
        } catch {
            AppLogger.persistence.error("Failed to persist ResponsibleGamblingPreferences")
            AppLogger.recordFailure(category: "preferences", operation: "ResponsibleGamblingPreferences.encode", error: error)
        }
    }

    func acknowledgeRiskDisclosure() {
        update { $0.acknowledgedRiskDisclosure = true }
    }

    /// Bloqueia novas apostas por `days` dias a partir de agora — não permite
    /// reverter sem passar o prazo (padrão do responsible gambling: uma vez
    /// autoexcluído, só o tempo desfaz).
    func triggerSelfExclusion(days: Int, now: Date = .now) {
        guard days > 0 else { return }
        let target = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        update { $0.selfExclusionUntil = target }
    }
}
