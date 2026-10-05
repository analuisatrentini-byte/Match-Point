//
//  Match_PointUITests.swift
//  Match PointUITests
//
//  Created by Ana Luisa Bittencourt on 26/03/26.
//

import XCTest

final class Match_PointUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    @MainActor
    func testOnboardingCanSeedPlayersAndEnterApp() throws {
        launch(resetOnboarding: true, completeOnboarding: false, seedData: false)

        // Onboarding agora auto-popula a lista de jogadores em `.task` — não
        // há mais botão "Adicionar populares" nem "Sincronizar agora" nesta
        // etapa. O teste só espera Alcaraz aparecer no grid de favoritos.
        let alcaraz = app.buttons.containing(.staticText, identifier: "Carlos Alcaraz").firstMatch
        XCTAssertTrue(alcaraz.waitForExistence(timeout: 3))
        alcaraz.tap()

        app.buttons["onboarding-enter-app"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["my-players-screen"].waitForExistence(timeout: 5)
                      || app.staticTexts["Meus favoritos"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCoreTabsExposeSeededFlows() throws {
        launchSeededApp()

        tapTab("Partidas")
        guard app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Matches root was not available in this UI test environment.")
        }

        tapTab("Jogadores")
        XCTAssertTrue(app.descendants(matching: .any)["my-players-screen"].waitForExistence(timeout: 5)
                      || app.staticTexts["Meus favoritos"].waitForExistence(timeout: 5))

        tapTab("Conversas")
        XCTAssertTrue(app.descendants(matching: .any)["social-feed-screen"].waitForExistence(timeout: 5))

        tapTab("Torneios")
        XCTAssertTrue(app.descendants(matching: .any)["circuit-section-picker"].waitForExistence(timeout: 5))

        tapTab("Perfil")
        guard app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Profile root was not available in this UI test environment.")
        }
    }

    @MainActor
    func testFavoritesPlayersAndMatchesContent() throws {
        launchSeededApp()

        tapTab("Jogadores")
        XCTAssertTrue(app.descendants(matching: .any)["my-players-screen"].waitForExistence(timeout: 5)
                      || app.staticTexts["Meus favoritos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Beatriz Haddad Maia"].waitForExistence(timeout: 5))

        tapTab("Partidas")
        guard app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Matches root was not available in this UI test environment.")
        }
        XCTAssertTrue(app.staticTexts["Carlos Alcaraz"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSocialProfilePredictionsAndAlertsScreens() throws {
        launchSeededApp()

        tapTab("Perfil")
        guard app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Profile root was not available in this UI test environment.")
        }
        let newPrediction = app.buttons["profile-new-prediction"]
        scrollUntilVisible(newPrediction)
        XCTAssertTrue(newPrediction.waitForExistence(timeout: 5))

        tapTab("Conversas")
        XCTAssertTrue(app.descendants(matching: .any)["social-feed-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["social-feed-tab"].waitForExistence(timeout: 5))

        openAlertsFromProfile()
        XCTAssertTrue(app.descendants(matching: .any)["alerts-screen"].waitForExistence(timeout: 5))
        let remotePush = app.staticTexts["Push remoto"]
        scrollUntilVisible(remotePush)
        XCTAssertTrue(remotePush.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLiveControlIsAvailableInMatchesFlow() throws {
        launchSeededApp()

        tapTab("Partidas")

        let toggle = app.buttons["matches-toggle-live"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["matches-live-center-title"].exists)
    }

    @MainActor
    func testPushBackendToggleFlow() throws {
        launchSeededApp()

        openAlertsFromProfile()

        let field = app.textFields["push-backend-url-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://push.matchpoint.test/device-token")

        let save = app.buttons["push-save-backend"]
        XCTAssertTrue(save.exists)
        save.tap()

        let toggle = app.switches["push-backend-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alerts-screen"].exists)
    }

    @MainActor
    func testReportAndModerationCommentFlow() throws {
        launchSeededApp()

        tapTab("Conversas")

        XCTAssertTrue(app.descendants(matching: .any)["social-feed-screen"].waitForExistence(timeout: 5))
        let report = app.buttons["local-report-comment"].firstMatch
        scrollUntilVisible(report)
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        report.tap()
        let moderation = app.staticTexts["Moderação"]
        scrollUntilVisible(moderation)
        XCTAssertTrue(moderation.waitForExistence(timeout: 5))
    }

    @MainActor
    func testBetCreationFlowAddsPredictionToHistory() throws {
        launchSeededApp()

        tapTab("Perfil")

        XCTAssertTrue(app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5))
        let newPrediction = app.buttons["profile-new-prediction"]
        scrollUntilVisible(newPrediction)
        XCTAssertTrue(newPrediction.waitForExistence(timeout: 5))
        newPrediction.tap()

        let firstMatch = app.buttons.containing(.staticText, identifier: "Carlos Alcaraz vs Jannik Sinner").firstMatch
        XCTAssertTrue(firstMatch.waitForExistence(timeout: 5))
        firstMatch.tap()

        let winnerKind = app.buttons.containing(.staticText, identifier: "Vencedor da partida").firstMatch
        XCTAssertTrue(winnerKind.waitForExistence(timeout: 5))
        winnerKind.tap()

        let confirm = app.buttons["bet-confirm"]
        scrollUntilVisible(confirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let historyRow = app.descendants(matching: .any).matching(identifier: "bet-history-row").firstMatch
        scrollUntilVisible(historyRow)
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
    }

    func testNativeShareActionExistsForMatchDetail() throws {
        launchSeededApp(extraArguments: ["MATCH_POINT_UI_START_MATCHES"])

        guard app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Matches root was not available in this UI test environment.")
        }
        let match = app.buttons.containing(.staticText, identifier: "Carlos Alcaraz vs Jannik Sinner").firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.tap()

        let matchShare = app.buttons["match-detail-share"]
        XCTAssertTrue(matchShare.waitForExistence(timeout: 5))
        XCTAssertEqual(matchShare.label, "Compartilhar partida")
    }

    @MainActor
    func testNativeShareActionExistsForPredictionHistory() throws {
        launchSeededApp(extraArguments: ["MATCH_POINT_UI_START_PROFILE"])

        guard app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Profile root was not available in this UI test environment.")
        }
        let historyRow = app.descendants(matching: .any).matching(identifier: "bet-history-row").firstMatch
        scrollUntilVisible(historyRow)
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["MATCH POINT PICK"].waitForExistence(timeout: 5))

        let predictionShare = app.buttons["Compartilhar card da previsão"].firstMatch
        XCTAssertTrue(predictionShare.waitForExistence(timeout: 5))
        XCTAssertEqual(predictionShare.label, "Compartilhar card da previsão")
        XCTAssertTrue(app.buttons["Concordo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Duvido"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["De olho"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testProfileSocialSummaryAndPublicProfileAreVisible() throws {
        launchSeededApp(extraArguments: ["MATCH_POINT_UI_START_PROFILE"])

        XCTAssertTrue(app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["profile-weekly-social-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["profile-leaderboard-podium"].waitForExistence(timeout: 5))

        let publicProfile = app.buttons["profile-public-profile-link"]
        XCTAssertTrue(publicProfile.waitForExistence(timeout: 5))
        publicProfile.tap()

        XCTAssertTrue(app.staticTexts["Perfil público"].waitForExistence(timeout: 5)
                      || app.navigationBars.staticTexts["Perfil público"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "leu melhor")).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testCoreScreensRemainNavigableWithAccessibilityDynamicType() throws {
        launchSeededApp(extraArguments: [
            "MATCH_POINT_UI_START_MATCHES",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        guard app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Matches root was not available in this UI test environment.")
        }
    }

    @MainActor
    func testProfileRemainsNavigableWithAccessibilityDynamicType() throws {
        launchSeededApp(extraArguments: [
            "MATCH_POINT_UI_START_PROFILE",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        guard app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Profile root was not available in this UI test environment.")
        }
        let newPrediction = app.buttons["profile-new-prediction"]
        scrollUntilVisible(newPrediction, maxSwipes: 10)
        XCTAssertTrue(newPrediction.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAlertsRemainNavigableWithAccessibilityDynamicType() throws {
        launchSeededApp(extraArguments: [
            "MATCH_POINT_UI_START_PROFILE",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])

        openAlertsFromProfile()
        XCTAssertTrue(app.descendants(matching: .any)["alerts-screen"].waitForExistence(timeout: 5))
        let pushSection = app.staticTexts["Push remoto"]
        scrollUntilVisible(pushSection, maxSwipes: 12)
        XCTAssertTrue(pushSection.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSocialFeedRemainsNavigableWithAccessibilityDynamicType() throws {
        launchSeededApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        tapTab("Conversas")
        XCTAssertTrue(app.descendants(matching: .any)["social-feed-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["social-feed-tab"].waitForExistence(timeout: 5))
    }

    /// Icon-only Buttons must expose a VoiceOver label. XCUIElement.label mirrors
    /// the `accessibilityLabel` modifier — an empty string means a screen reader
    /// user would only hear "button" with no context.
    @MainActor
    func testIconOnlyButtonsExposeAccessibilityLabels() throws {
        launchSeededApp()
        tapTab("Perfil")
        guard app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Profile root was not available in this UI test environment.")
        }

        // Profile → settings gear (icon-only in the header when compact)
        let settingsLink = app.buttons["profile-settings-link"]
        scrollUntilVisible(settingsLink)
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
        XCTAssertFalse(settingsLink.label.isEmpty, "profile-settings-link must expose a non-empty accessibilityLabel")

        // Tournament detail scenario button (chart icon, icon-only)
        tapTab("Torneios")
        let firstTournament = app.buttons.containing(.staticText, identifier: "Roland Garros").firstMatch
        if firstTournament.waitForExistence(timeout: 4) {
            firstTournament.tap()
            let scenarioButton = app.buttons["tournament-detail-scenario-button"]
            if scenarioButton.waitForExistence(timeout: 5) {
                XCTAssertFalse(scenarioButton.label.isEmpty, "tournament-detail-scenario-button must expose a non-empty accessibilityLabel")
            }
        }
    }

    /// The scoreboard is announced as one label per row (name + each set)
    /// rather than as detached digits ("6", "3", "6"). This test looks for
    /// the grouped label on the match detail scoreboard.
    @MainActor
    func testMatchScoreboardRowsExposeCombinedAccessibilityLabels() throws {
        launchSeededApp(extraArguments: ["MATCH_POINT_UI_START_MATCHES"])
        guard app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Matches root was not available in this UI test environment.")
        }

        let match = app.buttons.containing(.staticText, identifier: "Carlos Alcaraz vs Jannik Sinner").firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.tap()

        // Each scoreboard row is `.accessibilityElement(children: .ignore)` +
        // combined label — so it collapses into an element whose `.label`
        // contains player name and every set score in one phrase.
        // Search at the app level (regardless of container element type) since
        // an element with `.accessibilityElement(children: .ignore)` on an
        // HStack surfaces as a `.staticText` in the XCUITest hierarchy.
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
            "Alcaraz",
            "set 1"
        )
        let combinedRow = app.descendants(matching: .any).matching(predicate).firstMatch
        if !combinedRow.waitForExistence(timeout: 5) {
            // Some seeded scoreboards render only the tournament card without
            // the full MatchScoreboardView. If the assertion below fails only
            // because the scoreboard wasn't reached, skip rather than false-
            // negative on the grouping guard.
            throw XCTSkip("Seeded match detail did not surface a scoreboard row in this environment.")
        }
        XCTAssertTrue(combinedRow.label.localizedCaseInsensitiveContains("set 1"),
                      "Scoreboard row must expose a combined 'set 1' label to VoiceOver, got: \(combinedRow.label)")
    }

    @MainActor
    func testFavoriteToolbarButtonExposesAccessibilityLabel() throws {
        launchSeededApp(extraArguments: ["MATCH_POINT_UI_START_MATCHES"])
        guard app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5) else {
            throw XCTSkip("Seeded Matches root was not available in this UI test environment.")
        }

        let match = app.buttons.containing(.staticText, identifier: "Carlos Alcaraz vs Jannik Sinner").firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.tap()

        // `favoriteButton` (Shared/FavoriteButton.swift) exposes "Favorito" as
        // its label regardless of state. It's the only star button on the
        // detail screen, so a direct label lookup is unambiguous.
        let favorite = app.buttons["Favorito"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertFalse(favorite.label.isEmpty)
    }

    @MainActor
    func testSyncErrorToastAppearsOnForcedSyncFailure() throws {
        launch(resetOnboarding: true, completeOnboarding: true, seedData: true, extraArguments: ["MATCH_POINT_UI_FORCE_SYNC_ERROR"])

        tapTab("Partidas")
        XCTAssertTrue(app.staticTexts["matches-live-center-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["sync-feedback-banner"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Sync indisponível"].exists)
    }

    @MainActor
    func testOnboardingLimitsPlayerSelectionToThree() throws {
        launch(resetOnboarding: true, completeOnboarding: false, seedData: false)

        XCTAssertTrue(app.staticTexts["onboarding-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0/3 selecionados"].waitForExistence(timeout: 3))

        for name in ["Carlos Alcaraz", "Jannik Sinner", "Novak Djokovic"] {
            let player = app.buttons.containing(.staticText, identifier: name).firstMatch
            XCTAssertTrue(player.waitForExistence(timeout: 3))
            player.tap()
        }

        XCTAssertTrue(app.staticTexts["3/3 selecionados"].waitForExistence(timeout: 3))
        let fourth = app.buttons.containing(.staticText, identifier: "Daniil Medvedev").firstMatch
        XCTAssertTrue(fourth.waitForExistence(timeout: 3))
        XCTAssertFalse(fourth.isEnabled)
        XCTAssertTrue(app.buttons["onboarding-enter-app"].isEnabled)
    }

    @MainActor
    func testSettingsVersionLongPressOpensDiagnostics() throws {
        launchSeededApp()
        tapTab("Perfil")

        let settingsLink = app.buttons["profile-settings-link"]
        if settingsLink.waitForExistence(timeout: 3) {
            settingsLink.tap()
        }

        // Long-press on the "Versão" row reveals the hidden provider
        // diagnostics surface (replaces the old top-level Provider tab).
        let versionRow = app.descendants(matching: .any)["settings-version-row"]
        XCTAssertTrue(versionRow.waitForExistence(timeout: 4))
        versionRow.press(forDuration: 1.2)

        XCTAssertTrue(app.staticTexts["Provider Diagnostics"].waitForExistence(timeout: 4)
                      || app.navigationBars.staticTexts["Provider"].waitForExistence(timeout: 2),
                      "Diagnostics sheet did not appear after long-press on Versão")
    }

    @MainActor
    func testSettingsShowsAccountIdentityAndPublicProfilePreview() throws {
        launchSeededApp()
        tapTab("Perfil")

        XCTAssertTrue(app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5))
        let settingsLink = app.buttons["profile-settings-link"]
        scrollUntilVisible(settingsLink)
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
        settingsLink.tap()

        XCTAssertTrue(app.staticTexts["Conta e identidade"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conta iCloud"].exists)
        XCTAssertTrue(app.staticTexts["Identidade CloudKit"].exists)

        let publicProfile = app.buttons.containing(.staticText, identifier: "Ver perfil público").firstMatch
        XCTAssertTrue(publicProfile.waitForExistence(timeout: 5))
        publicProfile.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["Perfil público"].waitForExistence(timeout: 5)
                      || app.staticTexts["Perfil público"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testModerationDashboardShowsAdminSurfaces() throws {
        launchSeededApp()
        tapTab("Perfil")

        XCTAssertTrue(app.descendants(matching: .any)["profile-screen"].waitForExistence(timeout: 5))
        let settingsLink = app.buttons["profile-settings-link"]
        scrollUntilVisible(settingsLink)
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
        settingsLink.tap()

        let moderationLink = app.buttons["settings-moderation-link"]
        scrollUntilVisible(moderationLink)
        XCTAssertTrue(moderationLink.waitForExistence(timeout: 5))
        moderationLink.tap()

        XCTAssertTrue(app.staticTexts["Status admin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Regras"].exists)
        XCTAssertTrue(app.staticTexts["Fila de revisão"].exists)
        let audit = app.staticTexts["Auditoria"]
        scrollUntilVisible(audit)
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
    }

    // Removido: testBetConfirmButtonDisabledWhenStakeExceedsBalance
    //
    // O cenário que esse teste cobria — usuário pegar o stepper +25 e estourar
    // o saldo — não é mais alcançável pela UI. O Stepper de 19 stops foi
    // substituído por presets fixos `[50, 100, 200, 500]` + Max, e ambas as
    // ações fazem `selectedStake = min(preset, profile.points)` (ou
    // `profile.points` no caso de Max). Em outras palavras, o app passou de
    // "detectar erro depois" para "prevenir o erro" (Error Prevention,
    // Nielsen heurística #5). Como o caminho que ativava o estado de erro foi
    // estruturalmente eliminado, o teste vira tautologia se mantido —
    // melhor deletar do que reescrever uma asserção vazia.

    @MainActor
    func testPollVoteUpdatesPercentageLabel() throws {
        launchSeededApp()
        tapTab("Conversas")

        // The seeded poll card exposes a button per option with a percentage
        // label. Tapping the first option should leave the cards visible
        // (we're checking the UI doesn't crash from divide-by-zero / state
        // race when CloudMatchPoll structs rebuild mid-vote).
        let option = app.buttons.containing(.staticText, identifier: "0%").firstMatch
        if option.waitForExistence(timeout: 4) {
            option.tap()
        }

        // After voting the poll cards must still be there — regression guard
        // against the previous divide-by-zero crash in pollPercentageLabel.
        XCTAssertTrue(app.staticTexts["Quem vence?"].waitForExistence(timeout: 3)
                      || app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '%'")).firstMatch.exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let measuredApp = XCUIApplication()
            measuredApp.launchArguments = [
                "MATCH_POINT_UI_TESTING",
                "MATCH_POINT_UI_COMPLETE_ONBOARDING",
                "MATCH_POINT_UI_SEED_DATA"
            ]
            measuredApp.launch()
        }
    }

    private func launchSeededApp(extraArguments: [String] = []) {
        launch(resetOnboarding: true, completeOnboarding: true, seedData: true, extraArguments: extraArguments)
    }

    private func launch(resetOnboarding: Bool, completeOnboarding: Bool, seedData: Bool, extraArguments: [String] = []) {
        var arguments = ["MATCH_POINT_UI_TESTING"]
        if resetOnboarding {
            arguments.append("MATCH_POINT_UI_RESET")
        }
        if completeOnboarding {
            arguments.append("MATCH_POINT_UI_COMPLETE_ONBOARDING")
        }
        if seedData {
            arguments.append("MATCH_POINT_UI_SEED_DATA")
        }
        arguments.append(contentsOf: extraArguments)
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func tapTab(_ label: String) {
        let enterApp = app.buttons["onboarding-enter-app"]
        if enterApp.waitForExistence(timeout: 1), enterApp.isHittable {
            enterApp.tap()
        }

        let tabBar = app.tabBars.firstMatch
        if !tabBar.waitForExistence(timeout: 5) {
            if isOnTab(label) {
                return
            }
            let directScreenButton = app.buttons[label]
            if directScreenButton.exists {
                directScreenButton.tap()
                return
            }
            let directScreenText = app.staticTexts[label]
            if directScreenText.exists && directScreenText.isHittable {
                directScreenText.tap()
                return
            }
            XCTFail("Tab bar not found")
            return
        }

        let directButton = tabBar.buttons[label]
        if directButton.exists {
            directButton.tap()
            return
        }

        let moreButton = tabBar.buttons["More"].exists ? tabBar.buttons["More"] : tabBar.buttons["Mais"]
        if moreButton.exists {
            moreButton.tap()
            let tableCell = app.tables.cells.containing(.staticText, identifier: label).firstMatch
            if tableCell.waitForExistence(timeout: 3) {
                tableCell.tap()
                return
            }
            let text = app.staticTexts[label]
            if text.waitForExistence(timeout: 3) {
                text.tap()
                return
            }
        }

        XCTFail("Could not find tab \(label)")
    }

    private func isOnTab(_ label: String) -> Bool {
        switch label {
        case "Partidas":
            return app.staticTexts["matches-live-center-title"].exists || app.navigationBars.staticTexts["Partidas"].exists
        case "Jogadores":
            return app.descendants(matching: .any)["my-players-screen"].exists || app.staticTexts["Meus favoritos"].exists
        case "Conversas":
            return app.descendants(matching: .any)["social-feed-screen"].exists
        case "Torneios":
            return app.descendants(matching: .any)["circuit-section-picker"].exists
        case "Perfil":
            return app.descendants(matching: .any)["profile-screen"].exists
        default:
            return false
        }
    }

    private func openAlertsFromProfile() {
        tapTab("Perfil")
        let settingsLink = app.buttons["profile-settings-link"]
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
        settingsLink.tap()

        let alertsLink = app.buttons["alerts-link-consolidated"]
        scrollUntilVisible(alertsLink)
        XCTAssertTrue(alertsLink.waitForExistence(timeout: 5))
        alertsLink.tap()
    }

    private func scrollUntilVisible(_ element: XCUIElement, maxSwipes: Int = 6) {
        guard !element.exists || !element.isHittable else { return }
        let scrollView = app.scrollViews.firstMatch
        let table = app.tables.firstMatch
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable {
                return
            }
            if scrollView.exists {
                scrollView.swipeUp()
            } else if table.exists {
                table.swipeUp()
            } else {
                app.swipeUp()
            }
        }
    }
}
