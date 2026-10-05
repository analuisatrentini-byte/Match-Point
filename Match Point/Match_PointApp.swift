//
//  Match_PointApp.swift
//  Match Point
//
//  Created by Ana Luisa Bittencourt on 26/03/26.
//

import SwiftUI
import SwiftData
import UserNotifications
import OSLog
import Combine

@main
struct Match_PointApp: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor private var remotePushManager: RemotePushManager
#else
    @StateObject private var remotePushManager = RemotePushManager()
#endif
    @ObservedObject private var alertStore = AlertPreferencesStore.shared
    @ObservedObject private var experienceStore = ExperiencePreferencesStore.shared
    @ObservedObject private var behaviorStore = BehaviorPersonalizationStore.shared
    @ObservedObject private var analyticsStore = ProductAnalyticsStore.shared
    @ObservedObject private var responsibleGamblingStore = ResponsibleGamblingStore.shared
    @StateObject private var persistenceStore = PersistenceBootstrapStore()
    // Single CloudSocialBackend instance shared across the app. Each view
    // that needs to read the feed / leaderboard / current iCloud state
    // consumes it via `@EnvironmentObject` instead of creating its own
    // copy (five separate instances used to issue parallel CloudKit fetches
    // on every tab switch and held divergent published state).
    @StateObject private var cloudBackend = CloudSocialBackend()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("MATCH_POINT_UI_RESET") {
            UserDefaults.standard.removeObject(forKey: "match-point.onboarding-completed")
        }
        if arguments.contains("MATCH_POINT_UI_COMPLETE_ONBOARDING") {
            UserDefaults.standard.set(true, forKey: "match-point.onboarding-completed")
        }
        #endif
        AppleSportsAppearance.applyGlobalChrome()

        BackgroundSyncScheduler.register {
            guard case .ready(let container, _) = PersistenceBootstrapStore.current?.state else { return nil }
            return container
        }
    }

    var body: some Scene {
        WindowGroup {
            switch persistenceStore.state {
            case .ready(let container, _):
                // O overlay global "Sessão temporária: dados não serão salvos
                // ao fechar." foi removido. Razões:
                //
                //  • Em modo normal (caminho mais comum) o `if isTemporary`
                //    nunca renderizava, mas o `.overlay` ficava no view graph
                //    do app inteiro — ruído visual desnecessário.
                //  • Em modo temporário, o usuário JÁ aceitou o trade-off
                //    explicitamente em `PersistenceRecoveryView` ("Abrir
                //    sessão temporária"). Repetir o aviso fixo no topo de
                //    todas as telas era nag.
                //  • Loop visual: a capsule pinned no topo cobria controles
                //    e quebrava o gradient Apple Sports.
                //
                // Trade-off aceito: usuários que cairem no fallback temporário
                // (raro — só se filesystem falhar) podem esquecer que a
                // sessão é volátil. Aceitável porque a tela de recovery já
                // foi explícita.
                ContentView()
                    .environmentObject(alertStore)
                    .environmentObject(experienceStore)
                    .environmentObject(behaviorStore)
                    .environmentObject(analyticsStore)
                    .environmentObject(responsibleGamblingStore)
                    .environmentObject(remotePushManager)
                    .environmentObject(cloudBackend)
                    .task {
                        // Short debounce so refreshSystemState runs after the
                        // ContentView attaches but skipped entirely if the
                        // window scene is torn down before that elapses.
                        do {
                            try await Task.sleep(for: .seconds(1))
                        } catch {
                            return
                        }
                        remotePushManager.refreshSystemState()

                        // Remove legacy seeded records from earlier builds that
                        // exposed sample data before the production API key was
                        // configured.
                        let context = ModelContext(container)
                        DemoModeService.shared.disableDemoMode(in: context)
                    }
                    .modelContainer(container)
            case .failed(let failure):
                PersistenceRecoveryView(
                    failure: failure,
                    retry: persistenceStore.retryPersistentStore,
                    useTemporarySession: persistenceStore.useTemporarySession
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await behaviorStore.recordDeliveredNotificationsAsIgnored()
                }
            }
            if newPhase == .background {
                BackgroundSyncScheduler.scheduleNext()
            }
        }
    }
}

@MainActor
final class PersistenceBootstrapStore: ObservableObject {
    enum State {
        case ready(ModelContainer, isTemporary: Bool)
        case failed(PersistenceBootstrapFailure)
    }

    static private(set) weak var current: PersistenceBootstrapStore?

    @Published private(set) var state: State

    init() {
        do {
            let container = try Self.makeContainerResult(allowTemporaryFallback: false)
            state = .ready(container.container, isTemporary: container.isTemporary)
        } catch let failure as PersistenceBootstrapFailure {
            state = .failed(failure)
        } catch {
            state = .failed(PersistenceBootstrapFailure(error: error, attemptedTemporaryFallback: false))
        }
        Self.current = self
    }

    func retryPersistentStore() {
        do {
            let container = try Self.makeContainerResult(allowTemporaryFallback: false)
            state = .ready(container.container, isTemporary: container.isTemporary)
        } catch let failure as PersistenceBootstrapFailure {
            state = .failed(failure)
            AppLogger.persistence.error("Persistent store retry failed: \(failure.message, privacy: .private)")
        } catch {
            let failure = PersistenceBootstrapFailure(error: error, attemptedTemporaryFallback: false)
            state = .failed(failure)
            AppLogger.persistence.error("Persistent store retry failed: \(failure.message, privacy: .private)")
        }
    }

    func useTemporarySession() {
        do {
            let container = try Self.makeContainerResult(allowTemporaryFallback: true)
            state = .ready(container.container, isTemporary: true)
            AppLogger.persistence.warning("User explicitly opened a temporary in-memory persistence session.")
        } catch let failure as PersistenceBootstrapFailure {
            state = .failed(failure)
        } catch {
            state = .failed(PersistenceBootstrapFailure(error: error, attemptedTemporaryFallback: true))
        }
    }

    static func makeContainerResult(allowTemporaryFallback: Bool) throws -> (container: ModelContainer, isTemporary: Bool) {
        let schema = MatchPointModelSchema.schema
        let env = ProcessInfo.processInfo.environment
        let isPreview = env["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || env["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
        #if DEBUG
        let isUITesting = ProcessInfo.processInfo.arguments.contains("MATCH_POINT_UI_TESTING")
        #else
        let isUITesting = false
        #endif
        let shouldUseMemory = isPreview || isUITesting || allowTemporaryFallback
        if !shouldUseMemory {
            try ensureApplicationSupportDirectoryExists()
        }
        let primaryConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: shouldUseMemory,
            cloudKitDatabase: .none
        )

        do {
            if shouldUseMemory {
                return (
                    try ModelContainer(for: schema, configurations: [primaryConfig]),
                    true
                )
            }

            // Threading the explicit MigrationPlan turns a future schema bump
            // into a typed change (add a VersionedSchema + a MigrationStage)
            // instead of relying on SwiftData's implicit lightweight migration,
            // which silently picks a strategy that may not preserve user data.
            return (
                try ModelContainer(
                    for: schema,
                    migrationPlan: MatchPointMigrationPlan.self,
                    configurations: [primaryConfig]
                ),
                false
            )
        } catch {
            AppLogger.persistence.error("ModelContainer bootstrap failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "modelContainer.bootstrap", error: error)
            throw PersistenceBootstrapFailure(error: error, attemptedTemporaryFallback: shouldUseMemory)
        }
    }

    private static func ensureApplicationSupportDirectoryExists() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

struct PersistenceBootstrapFailure: Error, Equatable, UserPresentableError {
    let message: String
    let attemptedTemporaryFallback: Bool

    init(error: Error, attemptedTemporaryFallback: Bool) {
        self.message = AppLogger.message(for: error)
        self.attemptedTemporaryFallback = attemptedTemporaryFallback
    }

    var userFacing: UserFacingSyncFeedback {
        UserFacingSyncFeedback(
            kind: .configuration,
            title: "Banco de dados local indisponível",
            message: attemptedTemporaryFallback
                ? "Sessão temporária em memória — dados não serão salvos: \(message)"
                : "Não foi possível abrir o armazenamento local: \(message)",
            recoverySuggestion: "Reinicie o app; se persistir, abra o painel de diagnóstico e revise espaço/permissão de armazenamento."
        )
    }
}

struct PersistenceRecoveryView: View {
    let failure: PersistenceBootstrapFailure
    let retry: () -> Void
    let useTemporarySession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(.largeTitle, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Não foi possível abrir seus dados")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text("O app não vai trocar para banco em memória sem avisar, porque isso faria os dados sumirem ao fechar.")
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
                .multilineTextAlignment(.center)

            Text(failure.message)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            Button(action: retry) {
                Label("Tentar abrir novamente", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive, action: useTemporarySession) {
                Label("Abrir sessão temporária", systemImage: "memorychip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Use a sessão temporária apenas para diagnosticar. Dados criados nela não serão persistidos.")
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 460)
    }
}
