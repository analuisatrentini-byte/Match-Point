import Combine
import Foundation
import OSLog
import SwiftUI

nonisolated enum MatchPresentationFilter: String, Codable, CaseIterable, Identifiable {
    case all = "Todas"
    case live = "Ao vivo"
    case upcoming = "Próximas"
    case forYou = "Para você"

    var id: String { rawValue }
}

nonisolated enum TourPresentationFilter: String, Codable, CaseIterable, Identifiable {
    case all = "Todos"
    case atp = "ATP"
    case wta = "WTA"

    var id: String { rawValue }
}

nonisolated enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Escuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

nonisolated enum SlamThemePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto       // Use the slam currently in season; classic gradient out of season.
    case classic    // Never override the semantic gradient picked at the call site.
    case australianOpen
    case rolandGarros
    case wimbledon
    case usOpen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automático (temporada)"
        case .classic: return "Clássico"
        case .australianOpen: return "Australian Open"
        case .rolandGarros: return "Roland Garros"
        case .wimbledon: return "Wimbledon"
        case .usOpen: return "US Open"
        }
    }

    func resolvedSeason(now: Date = Date()) -> SlamSeason? {
        switch self {
        case .auto: return SlamSeason.current(for: now)
        case .classic: return nil
        case .australianOpen: return .australianOpen
        case .rolandGarros: return .rolandGarros
        case .wimbledon: return .wimbledon
        case .usOpen: return .usOpen
        }
    }
}

nonisolated enum MatchBrainStylePreference: String, Codable, CaseIterable, Identifiable {
    case balanced
    case pressureMoments
    case starPower
    case underdogStories

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: return String(localized: "Equilibrado")
        case .pressureMoments: return String(localized: "Momentos de pressão")
        case .starPower: return String(localized: "Grandes nomes")
        case .underdogStories: return String(localized: "Zebras e viradas")
        }
    }
}

nonisolated enum MatchBrainViewingWindow: String, Codable, CaseIterable, Identifiable {
    case anytime
    case quickCheck
    case useHabit
    case morning
    case afternoon
    case evening
    case lateNight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anytime: return String(localized: "Qualquer horário")
        case .quickCheck: return String(localized: "Tenho 20 min agora")
        case .useHabit: return String(localized: "Meu horário usual")
        case .morning: return String(localized: "Manhã")
        case .afternoon: return String(localized: "Tarde")
        case .evening: return String(localized: "Noite")
        case .lateNight: return String(localized: "Madrugada")
        }
    }

    func contains(hour: Int, activeHours: [Int: Int] = [:]) -> Bool {
        switch self {
        case .anytime:
            return true
        case .quickCheck:
            return true
        case .useHabit:
            guard let preferred = activeHours.max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            })?.key else { return false }
            return abs(preferred - hour) <= 1
        case .morning:
            return (6..<12).contains(hour)
        case .afternoon:
            return (12..<18).contains(hour)
        case .evening:
            return (18..<23).contains(hour)
        case .lateNight:
            return hour >= 23 || hour < 6
        }
    }
}

nonisolated struct ExperiencePreferences: Codable, Equatable {
    var matchFilter: MatchPresentationFilter = .forYou
    var tourFilter: TourPresentationFilter = .all
    var prioritizeFavorites: Bool = true
    var showOnlyRelevantNow: Bool = false
    var themeMode: ThemeMode = .system
    var slamTheme: SlamThemePreference = .auto
    var matchBrainStyle: MatchBrainStylePreference = .balanced
    var matchBrainViewingWindow: MatchBrainViewingWindow = .anytime
    var spoilerFreeMode: Bool = false

    init(
        matchFilter: MatchPresentationFilter = .forYou,
        tourFilter: TourPresentationFilter = .all,
        prioritizeFavorites: Bool = true,
        showOnlyRelevantNow: Bool = false,
        themeMode: ThemeMode = .system,
        slamTheme: SlamThemePreference = .auto,
        matchBrainStyle: MatchBrainStylePreference = .balanced,
        matchBrainViewingWindow: MatchBrainViewingWindow = .anytime,
        spoilerFreeMode: Bool = false
    ) {
        self.matchFilter = matchFilter
        self.tourFilter = tourFilter
        self.prioritizeFavorites = prioritizeFavorites
        self.showOnlyRelevantNow = showOnlyRelevantNow
        self.themeMode = themeMode
        self.slamTheme = slamTheme
        self.matchBrainStyle = matchBrainStyle
        self.matchBrainViewingWindow = matchBrainViewingWindow
        self.spoilerFreeMode = spoilerFreeMode
    }

    private enum CodingKeys: String, CodingKey {
        case matchFilter, tourFilter, prioritizeFavorites, showOnlyRelevantNow, themeMode, slamTheme, matchBrainStyle, matchBrainViewingWindow, spoilerFreeMode
    }

    // Custom decoder keeps legacy appearance keys tolerant while the current app
    // no longer exposes user-selectable visual themes in Settings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchFilter = try container.decodeIfPresent(MatchPresentationFilter.self, forKey: .matchFilter) ?? .forYou
        tourFilter = try container.decodeIfPresent(TourPresentationFilter.self, forKey: .tourFilter) ?? .all
        prioritizeFavorites = try container.decodeIfPresent(Bool.self, forKey: .prioritizeFavorites) ?? true
        showOnlyRelevantNow = try container.decodeIfPresent(Bool.self, forKey: .showOnlyRelevantNow) ?? false
        themeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        slamTheme = try container.decodeIfPresent(SlamThemePreference.self, forKey: .slamTheme) ?? .auto
        matchBrainStyle = try container.decodeIfPresent(MatchBrainStylePreference.self, forKey: .matchBrainStyle) ?? .balanced
        matchBrainViewingWindow = try container.decodeIfPresent(MatchBrainViewingWindow.self, forKey: .matchBrainViewingWindow) ?? .anytime
        spoilerFreeMode = try container.decodeIfPresent(Bool.self, forKey: .spoilerFreeMode) ?? false
    }
}

@MainActor
final class ExperiencePreferencesStore: ObservableObject {
    static let shared = ExperiencePreferencesStore()

    @Published private(set) var preferences: ExperiencePreferences

    private let defaults: UserDefaults
    private let key = "match-point.experience-preferences"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do {
                preferences = try JSONDecoder().decode(ExperiencePreferences.self, from: data)
            } catch {
                AppLogger.persistence.error("Failed to decode ExperiencePreferences; using defaults: \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "preferences", operation: "ExperiencePreferences.decode", error: error)
                preferences = ExperiencePreferences()
            }
        } else {
            preferences = ExperiencePreferences()
        }
    }

    func update(_ mutate: (inout ExperiencePreferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        preferences = updated
        do {
            let encoded = try JSONEncoder().encode(updated)
            defaults.set(encoded, forKey: key)
        } catch {
            AppLogger.persistence.error("Failed to persist ExperiencePreferences: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "preferences", operation: "ExperiencePreferences.encode", error: error)
        }
    }
}
