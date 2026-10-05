import CloudKit
import Combine
import Foundation
import OSLog

// State + DTOs moved to CloudSocialModels.swift.

@MainActor
final class CloudSocialBackend: ObservableObject {
    private enum DefaultsKey {
        static let moderationBackendURL = "match-point.social.moderation-backend-url"
        // Legacy UserDefaults key kept only so we can migrate any existing plaintext
        // token into the Keychain on first read, then wipe it.
        static let legacyModerationAdminToken = "match-point.social.moderation-admin-token"
    }

    private enum KeychainKey {
        static let moderationAdminToken = "moderation-admin-token"
    }

    private static let keychain = KeychainSecretStore(service: "match-point.social")

    @Published private(set) var state: CloudBackendState = .idle
    @Published private(set) var posts: [CloudSocialPost] = []
    @Published private(set) var polls: [CloudMatchPoll] = []
    @Published private(set) var leaderboard: [CloudLeaderboardEntry] = []
    @Published private(set) var leaderboardSource: CloudLeaderboardSource = .none
    @Published private(set) var moderationQueue: [CloudModerationQueueItem] = []
    @Published private(set) var moderationAudit: [CloudModerationAuditEvent] = []
    @Published private(set) var communityRules: [String] = []
    @Published private(set) var accountLabel: String = "iCloud não verificado"
    @Published private(set) var currentUserLabel: String = "Usuário não identificado"

    private enum RecordType {
        static let post = "SocialPost"
        static let poll = "MatchPoll"
        static let leaderboard = "LeaderboardEntry"
        static let bet = "PointBet"
        static let report = "SocialReport"
    }

    private struct BackendLeaderboardResponse: Decodable {
        let leaderboard: [BackendLeaderboardEntry]
    }

    private struct BackendModerationQueueResponse: Decodable {
        let queue: [CloudModerationQueueItem]
    }

    private struct BackendModerationAuditResponse: Decodable {
        let audit: [CloudModerationAuditEvent]
    }

    private struct BackendCommunityRulesResponse: Decodable {
        let rules: [String]
    }

    private struct BackendLeaderboardEntry: Decodable {
        let id: String?
        let userRecordName: String
        let displayName: String
        let avatarSymbol: String
        let points: Int
        let wins: Int
        let losses: Int
        let currentStreak: Int
        let updatedAt: String?
        let isCurrentUser: Bool?
    }

    private let container: CKContainer?
    private let publicDatabase: CKDatabase?
    private let privateDatabase: CKDatabase?
    private var cachedUserRecordName: String?
    private let urlSession: URLSession
    /// When true, every public mutation/refresh entry point becomes a no-op.
    /// SwiftUI previews use the `previewStub()` factory so they don't try to
    /// hit CloudKit / the moderation backend from the canvas (which would
    /// stall the preview and surface confusing connectivity errors).
    private let isInert: Bool

    /// Per-action timestamps used by `enforceRateLimit(for:)` to throttle
    /// CloudKit/HTTP writes. A misbehaving (or compromised) client can still
    /// flood the backend, but this caps accidental floods from UI tap-spam and
    /// shifts the burden of abuse detection to the server.
    private var lastWriteAt: [String: Date] = [:]
    /// Minimum spacing between two writes of the same action. Picked to allow
    /// normal interactive use (one tap per ~couple of seconds) while
    /// short-circuiting taps-per-second floods.
    private let writeCooldown: TimeInterval = 2

    @discardableResult
    private func enforceRateLimit(for action: String) -> Bool {
        let now = Date()
        if let last = lastWriteAt[action], now.timeIntervalSince(last) < writeCooldown {
            return false
        }
        lastWriteAt[action] = now
        return true
    }

    static let isAvailable: Bool = true
    static let expectedCloudKitContainerIdentifier = "iCloud.ALTB.Match-Point"

    static var isSocialBackendConfigured: Bool {
        guard let rawURL = UserDefaults.standard.string(forKey: DefaultsKey.moderationBackendURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL),
              url.scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    static var cloudKitEntitlementContainerIdentifiers: [String] {
        [expectedCloudKitContainerIdentifier]
    }

    static var cloudKitEntitlementServices: [String] {
        ["CloudKit"]
    }

    static var hasExpectedCloudKitContainerEntitlement: Bool {
        cloudKitEntitlementContainerIdentifiers.contains(expectedCloudKitContainerIdentifier)
    }

    static var hasCloudKitServiceEntitlement: Bool {
        cloudKitEntitlementServices.contains("CloudKit")
    }

    private static func makeContainer() -> CKContainer? {
        guard isAvailable else { return nil }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("MATCH_POINT_UI_TESTING") {
            return nil
        }
        #endif
        guard hasExpectedCloudKitContainerEntitlement, hasCloudKitServiceEntitlement else {
            // iCloud entitlement not configured in this signed build — degrade
            // gracefully instead of instantiating CKContainer and crashing.
            return nil
        }
        return CKContainer(identifier: expectedCloudKitContainerIdentifier)
    }

    init(container: CKContainer? = nil, urlSession: URLSession = .shared, isInert: Bool = false) {
        let resolved = isInert ? nil : (container ?? Self.makeContainer())
        self.container = resolved
        self.publicDatabase = resolved?.publicCloudDatabase
        self.privateDatabase = resolved?.privateCloudDatabase
        self.urlSession = urlSession
        self.isInert = isInert
        if resolved == nil {
            self.accountLabel = "iCloud indisponível neste build"
            self.state = .unavailable("iCloud não está configurado neste build.")
        }
    }

    /// Returns an instance that will never reach CloudKit or the moderation
    /// backend even if the iCloud entitlement is enabled. Use this for SwiftUI
    /// previews so the canvas doesn't deadlock on a network round-trip.
    ///
    /// Pass `seedingData: true` to populate the inert backend with a small
    /// fixture set (posts, polls, leaderboard) so the preview shows a
    /// realistic-looking feed instead of every empty state at once.
    static func previewStub(seedingData: Bool = false) -> CloudSocialBackend {
        let stub = CloudSocialBackend(isInert: true)
        if seedingData {
            stub.seedFixtureFeed()
        }
        return stub
    }

    /// Populates the published arrays with a deterministic fixture that
    /// exercises the most common rendering paths: a regular post, a pinned
    /// system event, a poll with votes, and a 3-entry leaderboard with the
    /// "current user" highlighted.
    private func seedFixtureFeed() {
        accountLabel = "iCloud preview"
        currentUserLabel = "preview-user"
        state = .ready

        let createdAt = Date(timeIntervalSinceNow: -120)

        posts = [
            CloudSocialPost(
                id: "preview-post-1",
                matchKey: "preview-match",
                matchTitle: "Alcaraz vs Sinner",
                authorName: "Maria",
                authorRecordName: "preview-user-2",
                body: "Drama de quadra central\n\nA partida teve ritmo, viradas curtas e aquele tipo de tensão que faz cada game parecer decisivo.",
                likes: 12,
                replyCount: 0,
                eventKey: "review:5:preview-post-1",
                parentPostID: nil,
                reportCount: 0,
                isHidden: false,
                isPinned: false,
                createdAt: createdAt
            ),
            CloudSocialPost(
                id: "preview-post-2",
                matchKey: "preview-match",
                matchTitle: "Alcaraz vs Sinner",
                authorName: "João",
                authorRecordName: "preview-user-3",
                body: "Bom, mas irregular\n\nOs melhores pontos foram incríveis, só faltou mais consistência no meio do segundo set.",
                likes: 4,
                replyCount: 0,
                eventKey: "review:4:preview-post-2",
                parentPostID: nil,
                reportCount: 0,
                isHidden: false,
                isPinned: false,
                createdAt: createdAt.addingTimeInterval(60)
            )
        ]

        polls = [
            CloudMatchPoll(
                id: "preview-poll-1",
                matchKey: "preview-match",
                matchTitle: "Alcaraz vs Sinner",
                question: "Quem vence?",
                optionOne: "Alcaraz",
                optionTwo: "Sinner",
                optionThree: "Tie-break decisivo",
                votesOne: 42,
                votesTwo: 35,
                votesThree: 8,
                createdAt: createdAt
            )
        ]

        leaderboard = [
            CloudLeaderboardEntry(
                id: "preview-leader-1",
                displayName: "Maria",
                avatarSymbol: "person.crop.circle.fill",
                points: 1_240,
                wins: 24,
                losses: 9,
                currentStreak: 5,
                updatedAt: createdAt,
                isCurrentUser: false
            ),
            CloudLeaderboardEntry(
                id: "preview-leader-2",
                displayName: "Você",
                avatarSymbol: "tennisball.fill",
                points: 980,
                wins: 18,
                losses: 12,
                currentStreak: 2,
                updatedAt: createdAt,
                isCurrentUser: true
            ),
            CloudLeaderboardEntry(
                id: "preview-leader-3",
                displayName: "João",
                avatarSymbol: "star.fill",
                points: 760,
                wins: 14,
                losses: 18,
                currentStreak: 0,
                updatedAt: createdAt,
                isCurrentUser: false
            )
        ]
    }

    static func configureModerationBackend(url: String, adminToken: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.moderationBackendURL)
        if let adminToken {
            let trimmed = adminToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                deleteModerationAdminToken()
            } else {
                storeModerationAdminToken(trimmed)
            }
        }
        // Wipe any legacy plaintext token left behind by older builds.
        defaults.removeObject(forKey: DefaultsKey.legacyModerationAdminToken)
    }

    static var hasModerationAdminToken: Bool {
        loadModerationAdminToken()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    private static func loadModerationAdminToken() -> String? {
        if let token = keychain.read(account: KeychainKey.moderationAdminToken) {
            return token
        }
        // Migration: pull any legacy plaintext token out of UserDefaults, persist
        // it to Keychain, then erase the UserDefaults copy.
        let defaults = UserDefaults.standard
        if let legacy = defaults.string(forKey: DefaultsKey.legacyModerationAdminToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            keychain.write(legacy, account: KeychainKey.moderationAdminToken)
            defaults.removeObject(forKey: DefaultsKey.legacyModerationAdminToken)
            return legacy
        }
        return nil
    }

    private static func storeModerationAdminToken(_ token: String) {
        keychain.write(token, account: KeychainKey.moderationAdminToken)
    }

    static func deleteModerationAdminToken() {
        keychain.delete(account: KeychainKey.moderationAdminToken)
    }

    func refreshAll() async {
        guard !isInert, Self.isAvailable else { return }
        state = .loading
        do {
            let userRecordName = try await currentUserRecordName()
            currentUserLabel = userRecordName
            accountLabel = "iCloud disponível"
            async let loadedPosts = fetchPosts()
            async let loadedPolls = fetchPolls()
            posts = try await loadedPosts
            polls = try await loadedPolls
            leaderboard = try await fetchPreferredLeaderboard(currentUserRecordName: userRecordName)
            state = .ready
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func refreshAccountStatus() async {
        guard !isInert, let container else { return }
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                accountLabel = "iCloud disponível"
                currentUserLabel = try await currentUserRecordName()
                state = .ready
            case .noAccount:
                accountLabel = "Sem conta iCloud ativa"
                state = .unavailable("Entre no iCloud para sincronizar.")
            case .restricted:
                accountLabel = "iCloud restrito neste aparelho"
                state = .unavailable("iCloud restrito neste aparelho.")
            case .couldNotDetermine:
                accountLabel = "Não foi possível verificar iCloud"
                state = .unavailable("Não foi possível verificar iCloud.")
            case .temporarilyUnavailable:
                accountLabel = "iCloud temporariamente indisponível"
                state = .unavailable("iCloud temporariamente indisponível.")
            @unknown default:
                accountLabel = "Estado iCloud desconhecido"
                state = .unavailable("Estado iCloud desconhecido.")
            }
        } catch {
            accountLabel = Self.userFacingCloudMessage(for: error)
            state = .unavailable(accountLabel)
        }
    }

    func publishComment(
        match: TennisMatch?,
        authorName: String,
        body: String,
        eventKey: String? = nil
    ) async {
        guard let publicDatabase else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard enforceRateLimit(for: "publishComment") else { return }

        do {
            let userRecordName = try await currentUserRecordName()
            let record = CKRecord(recordType: RecordType.post)
            record["matchKey"] = matchKey(for: match) as CKRecordValue
            record["matchTitle"] = matchTitle(for: match) as CKRecordValue
            record["authorName"] = authorName as CKRecordValue
            record["authorRecordName"] = userRecordName as CKRecordValue
            record["body"] = trimmed as CKRecordValue
            record["likes"] = 0 as CKRecordValue
            record["replyCount"] = 0 as CKRecordValue
            if let eventKey {
                record["eventKey"] = eventKey as CKRecordValue
            }
            record["reportCount"] = 0 as CKRecordValue
            record["isHidden"] = NSNumber(value: false)
            record["isPinned"] = NSNumber(value: false)
            record["createdAt"] = Date() as CKRecordValue
            _ = try await publicDatabase.save(record)
            await refreshAll()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func publishMatchReview(
        match: TennisMatch?,
        authorName: String,
        body: String,
        eventKey: String
    ) async {
        guard MatchReviewEncoding.rating(from: eventKey) != nil else { return }
        await publishComment(match: match, authorName: authorName, body: body, eventKey: eventKey)
    }

    func likePost(_ post: CloudSocialPost) async {
        guard let publicDatabase else { return }
        guard enforceRateLimit(for: "likePost.\(post.id)") else { return }
        do {
            let recordID = CKRecord.ID(recordName: post.id)
            let record = try await publicDatabase.record(for: recordID)
            let current = record["likes"] as? Int ?? post.likes
            record["likes"] = (current + 1) as CKRecordValue
            _ = try await publicDatabase.save(record)
            await refreshAll()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func reply(to post: CloudSocialPost, authorName: String, body: String) async {
        guard let publicDatabase else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard enforceRateLimit(for: "reply") else { return }

        do {
            let userRecordName = try await currentUserRecordName()
            let record = CKRecord(recordType: RecordType.post)
            record["matchKey"] = post.matchKey as CKRecordValue
            record["matchTitle"] = post.matchTitle as CKRecordValue
            record["authorName"] = authorName as CKRecordValue
            record["authorRecordName"] = userRecordName as CKRecordValue
            record["body"] = trimmed as CKRecordValue
            record["likes"] = 0 as CKRecordValue
            record["replyCount"] = 0 as CKRecordValue
            record["parentPostID"] = post.id as CKRecordValue
            record["reportCount"] = 0 as CKRecordValue
            record["isHidden"] = NSNumber(value: false)
            record["isPinned"] = NSNumber(value: false)
            record["createdAt"] = Date() as CKRecordValue
            _ = try await publicDatabase.save(record)

            let parentRecord = try await publicDatabase.record(for: CKRecord.ID(recordName: post.id))
            parentRecord["replyCount"] = ((parentRecord["replyCount"] as? Int ?? post.replyCount) + 1) as CKRecordValue
            _ = try await publicDatabase.save(parentRecord)
            await refreshAll()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func reportPost(_ post: CloudSocialPost) async {
        do {
            let userRecordName = try await currentUserRecordName()
            if let publicDatabase {
                let reportID = CKRecord.ID(recordName: "report-\(post.id)-\(userRecordName)")
                let report = CKRecord(recordType: RecordType.report, recordID: reportID)
                report["postID"] = post.id as CKRecordValue
                report["userRecordName"] = userRecordName as CKRecordValue
                report["createdAt"] = Date() as CKRecordValue
                _ = try await publicDatabase.save(report)
            }

            try await sendModerationReport(post: post, userRecordName: userRecordName)
            await refreshAll()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func setPinned(_ post: CloudSocialPost, isPinned: Bool) async {
        do {
            let userRecordName = try await currentUserRecordName()
            try await sendModerationAction(
                post: post,
                action: isPinned ? "pin" : "unpin",
                userRecordName: userRecordName
            )
            await refreshAll()
            await refreshModerationAdmin()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func setHidden(_ post: CloudSocialPost, isHidden: Bool) async {
        do {
            let userRecordName = try await currentUserRecordName()
            try await sendModerationAction(
                post: post,
                action: isHidden ? "hide" : "unhide",
                userRecordName: userRecordName
            )
            await refreshAll()
            await refreshModerationAdmin()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func banAuthor(of post: CloudSocialPost, reason: String) async {
        guard !post.authorRecordName.isEmpty else {
            state = .unavailable("Não foi possível identificar o autor deste post.")
            return
        }

        await setUserBan(userRecordName: post.authorRecordName, reason: reason, isActive: true)
    }

    func setUserBan(userRecordName: String, reason: String, isActive: Bool) async {
        do {
            let endpoint = try moderationEndpoint(path: isActive ? "/social/moderation/ban" : "/social/moderation/unban", requiresAdmin: true)
            let actorRecordName = try await currentUserRecordName()
            let payload: [String: Any] = [
                "userRecordName": userRecordName,
                "reason": reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "moderation" : reason,
                "actorRecordName": actorRecordName,
                "createdAt": ISO8601DateFormatter().string(from: .now)
            ]
            try await postJSON(payload, to: endpoint.url, authorization: endpoint.authorization)
            await refreshModerationAdmin()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func refreshModerationAdmin() async {
        guard !isInert else { return }
        do {
            async let queue = fetchModerationQueue()
            async let audit = fetchModerationAudit()
            async let rules = fetchCommunityRules()
            moderationQueue = try await queue
            moderationAudit = try await audit
            communityRules = try await rules
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func saveCommunityRules(_ rules: [String]) async {
        do {
            let endpoint = try moderationEndpoint(path: "/social/moderation/rules", requiresAdmin: true)
            let actorRecordName = try await currentUserRecordName()
            let sanitizedRules = rules
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(20)
            let payload: [String: Any] = [
                "rules": Array(sanitizedRules),
                "actorRecordName": actorRecordName,
                "createdAt": ISO8601DateFormatter().string(from: .now)
            ]
            try await postJSON(payload, to: endpoint.url, authorization: endpoint.authorization)
            await refreshModerationAdmin()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    private func sendModerationReport(post: CloudSocialPost, userRecordName: String) async throws {
        let endpoint = try moderationEndpoint(path: "/social/moderation/report", requiresAdmin: false)
        let payload: [String: Any] = [
            "postID": post.id,
            "matchKey": post.matchKey,
            "reason": "user-report",
            "userRecordName": userRecordName,
            "createdAt": ISO8601DateFormatter().string(from: .now)
        ]
        try await postJSON(payload, to: endpoint.url, authorization: endpoint.authorization)
    }

    private func sendModerationAction(post: CloudSocialPost, action: String, userRecordName: String) async throws {
        let endpoint = try moderationEndpoint(path: "/social/moderation/action", requiresAdmin: true)
        let payload: [String: Any] = [
            "postID": post.id,
            "matchKey": post.matchKey,
            "action": action,
            "actorRecordName": userRecordName,
            "createdAt": ISO8601DateFormatter().string(from: .now)
        ]
        try await postJSON(payload, to: endpoint.url, authorization: endpoint.authorization)
    }

    private func moderationEndpoint(path: String, requiresAdmin: Bool) throws -> (url: URL, authorization: String?) {
        let defaults = UserDefaults.standard
        let rawURL = defaults.string(forKey: DefaultsKey.moderationBackendURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try Self.makeModerationEndpoint(
            baseURL: rawURL,
            path: path,
            requiresAdmin: requiresAdmin,
            adminToken: Self.loadModerationAdminToken()
        )
    }

    static func makeModerationEndpoint(
        baseURL rawURL: String,
        path: String,
        requiresAdmin: Bool,
        adminToken token: String?
    ) throws -> (url: URL, authorization: String?) {
        let rawURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: rawURL), !rawURL.isEmpty else {
            throw CloudBackendError.accountUnavailable
        }

        components.path = path
        guard let url = components.url else {
            throw CloudBackendError.accountUnavailable
        }

        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresAdmin, trimmedToken?.isEmpty != false {
            throw CloudBackendError.accountUnavailable
        }

        return (url, trimmedToken.map { "Bearer \($0)" })
    }

    private func postJSON(_ payload: [String: Any], to url: URL, authorization: String?) async throws {
        _ = try await postJSONReturningObject(payload, to: url, authorization: authorization)
    }

    private func postJSONReturningObject(_ payload: [String: Any], to url: URL, authorization: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIHTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: "")
        }

        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func getJSONData(from url: URL, authorization: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIHTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: "")
        }
        return data
    }

    @discardableResult
    func createPoll(match: TennisMatch?, question: String) async -> String? {
        guard let publicDatabase else { return nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuestion = trimmed.isEmpty ? "Quem vence?" : trimmed

        do {
            let record = CKRecord(recordType: RecordType.poll)
            record["matchKey"] = matchKey(for: match) as CKRecordValue
            record["matchTitle"] = matchTitle(for: match) as CKRecordValue
            record["question"] = resolvedQuestion as CKRecordValue
            record["optionOne"] = (match?.player1?.name ?? "Jogador 1") as CKRecordValue
            record["optionTwo"] = (match?.player2?.name ?? "Jogador 2") as CKRecordValue
            record["optionThree"] = "Vai ao tie-break" as CKRecordValue
            record["votesOne"] = 0 as CKRecordValue
            record["votesTwo"] = 0 as CKRecordValue
            record["votesThree"] = 0 as CKRecordValue
            record["createdAt"] = Date() as CKRecordValue
            let saved = try await publicDatabase.save(record)
            await refreshAll()
            return saved.recordID.recordName
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
            return nil
        }
    }

    func voteOnLocalPoll(_ poll: MatchPoll, optionIndex: Int) async {
        guard let cloudRecordID = poll.cloudRecordID, !cloudRecordID.isEmpty else { return }
        let proxy = CloudMatchPoll(
            id: cloudRecordID,
            matchKey: poll.match.map(matchKey(for:)) ?? "",
            matchTitle: poll.match.map(matchTitle(for:)) ?? "",
            question: poll.question,
            optionOne: poll.optionOne,
            optionTwo: poll.optionTwo,
            optionThree: poll.optionThree,
            votesOne: poll.votesOne,
            votesTwo: poll.votesTwo,
            votesThree: poll.votesThree,
            createdAt: poll.createdAt
        )
        await vote(on: proxy, optionIndex: optionIndex)
    }

    func vote(on poll: CloudMatchPoll, optionIndex: Int) async {
        guard let publicDatabase else { return }
        guard optionIndex >= 1, optionIndex <= 3 else {
            AppLogger.api.error("vote: optionIndex \(optionIndex, privacy: .public) is out of range [1,3] — vote ignored")
            return
        }
        guard enforceRateLimit(for: "vote.\(poll.id)") else { return }
        do {
            let userRecordName = try await currentUserRecordName()
            let voteID = CKRecord.ID(recordName: "vote-\(poll.id)-\(userRecordName)")
            let voteRecord = CKRecord(recordType: "PollVote", recordID: voteID)
            voteRecord["pollID"] = poll.id as CKRecordValue
            voteRecord["optionIndex"] = optionIndex as CKRecordValue
            voteRecord["userRecordName"] = userRecordName as CKRecordValue
            voteRecord["createdAt"] = Date() as CKRecordValue
            _ = try await publicDatabase.save(voteRecord)

            let pollRecord = try await publicDatabase.record(for: CKRecord.ID(recordName: poll.id))
            switch optionIndex {
            case 1:
                pollRecord["votesOne"] = ((pollRecord["votesOne"] as? Int ?? poll.votesOne) + 1) as CKRecordValue
            case 2:
                pollRecord["votesTwo"] = ((pollRecord["votesTwo"] as? Int ?? poll.votesTwo) + 1) as CKRecordValue
            case 3:
                pollRecord["votesThree"] = ((pollRecord["votesThree"] as? Int ?? poll.votesThree) + 1) as CKRecordValue
            default:
                break  // Guard above ensures this is unreachable
            }
            _ = try await publicDatabase.save(pollRecord)
            await refreshAll()
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func syncProfile(_ profile: UserProfile, performance: CloudTipsterPerformance? = nil) async {
        guard let publicDatabase else { return }
        do {
            let userRecordName = try await currentUserRecordName()
            let recordID = CKRecord.ID(recordName: "leader-\(userRecordName)")
            let record = CKRecord(recordType: RecordType.leaderboard, recordID: recordID)
            record["userRecordName"] = userRecordName as CKRecordValue
            record["displayName"] = profile.displayName as CKRecordValue
            record["avatarSymbol"] = profile.avatarSymbol as CKRecordValue
            record["points"] = profile.points as CKRecordValue
            // Persist the tipster stats so the leaderboard can show win rate and
            // streak — turning "who has the most points" into "who is hot right
            // now". Omitted when `performance` is nil (e.g. settings round-trip)
            // so we don't overwrite a previously-published stat with zeros.
            if let performance {
                record["wins"] = performance.wins as CKRecordValue
                record["losses"] = performance.losses as CKRecordValue
                record["currentStreak"] = performance.currentStreak as CKRecordValue
            }
            record["updatedAt"] = Date() as CKRecordValue
            _ = try await publicDatabase.save(record)
            try? await syncLeaderboardProfileWithBackend(profile, userRecordName: userRecordName)
            leaderboard = try await fetchPreferredLeaderboard(currentUserRecordName: userRecordName)
            state = .ready
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    func syncBet(_ bet: PointBet, profile: UserProfile) async {
        guard bet.hasValidIntegrity else {
            // Refuse to ship a bet whose stake/payout/selection no longer match
            // its placement hash. Surfacing the audit failure beats letting a
            // mutated bet hit CloudKit + the backend ledger.
            AppLogger.persistence.error("syncBet aborted: integrity hash mismatch for bet \(bet.id.uuidString, privacy: .public)")
            AppLogger.recordFailure(
                category: "persistence",
                operation: "syncBet.integrityMismatch",
                error: APIError(message: "PointBet integrity hash does not match current state")
            )
            return
        }
        do {
            let userRecordName = try await currentUserRecordName()
            if let privateDatabase {
                let recordID = CKRecord.ID(recordName: "bet-\(bet.id.uuidString)")
                let record = CKRecord(recordType: RecordType.bet, recordID: recordID)
                record["userRecordName"] = userRecordName as CKRecordValue
                record["displayName"] = profile.displayName as CKRecordValue
                record["matchKey"] = matchKey(for: bet.match) as CKRecordValue
                record["matchTitle"] = matchTitle(for: bet.match) as CKRecordValue
                record["playerName"] = (bet.player?.name ?? bet.selection) as CKRecordValue
                record["kind"] = bet.kind.rawValue as CKRecordValue
                record["selection"] = bet.selection as CKRecordValue
                record["stake"] = bet.stake as CKRecordValue
                record["payout"] = bet.payout as CKRecordValue
                record["status"] = bet.status.rawValue as CKRecordValue
                record["targetSetIndex"] = (bet.targetSetIndex ?? -1) as CKRecordValue
                record["predictedScore"] = bet.predictedScore as CKRecordValue
                record["performanceRule"] = bet.performanceRule.rawValue as CKRecordValue
                record["integrityHash"] = bet.integrityHash as CKRecordValue
                record["settlementAuthority"] = bet.settlementAuthority.rawValue as CKRecordValue
                record["serverSettlementStatus"] = bet.serverSettlementStatus.rawValue as CKRecordValue
                if let serverSettlementID = bet.serverSettlementID {
                    record["serverSettlementID"] = serverSettlementID as CKRecordValue
                }
                record["createdAt"] = bet.createdAt as CKRecordValue
                if let settledAt = bet.settledAt {
                    record["settledAt"] = settledAt as CKRecordValue
                }
                _ = try await privateDatabase.save(record)
            }

            try await registerBetWithBackend(bet, profile: profile, userRecordName: userRecordName)
        } catch {
            state = .unavailable(Self.userFacingCloudMessage(for: error))
        }
    }

    private func registerBetWithBackend(_ bet: PointBet, profile: UserProfile, userRecordName: String) async throws {
        let endpoint = try moderationEndpoint(path: "/social/bets/register", requiresAdmin: false)
        let payload: [String: Any] = [
            "betID": bet.id.uuidString,
            "userRecordName": userRecordName,
            "displayName": profile.displayName,
            "avatarSymbol": profile.avatarSymbol,
            "matchKey": matchKey(for: bet.match),
            "selection": bet.selection,
            "kind": bet.kind.rawValue,
            "stake": bet.stake,
            "payout": bet.payout,
            "integrityHash": bet.integrityHash,
            "createdAt": ISO8601DateFormatter().string(from: bet.createdAt)
        ]
        let response = try await postJSONReturningObject(payload, to: endpoint.url, authorization: endpoint.authorization)
        guard let result = response["result"] as? [String: Any] else { return }

        bet.serverSettlementID = result["serverSettlementID"] as? String
        bet.serverSettlementStatus = .accepted
        bet.settlementAuthority = .serverAuthoritative
    }

    private func syncLeaderboardProfileWithBackend(_ profile: UserProfile, userRecordName: String) async throws {
        let endpoint = try moderationEndpoint(path: "/social/leaderboard/profile", requiresAdmin: false)
        let payload: [String: Any] = [
            "userRecordName": userRecordName,
            "displayName": profile.displayName,
            "avatarSymbol": profile.avatarSymbol
        ]
        try await postJSON(payload, to: endpoint.url, authorization: endpoint.authorization)
    }

    private func fetchPosts() async throws -> [CloudSocialPost] {
        guard let publicDatabase else { throw CloudBackendError.accountUnavailable }
        let records = try await queryRecords(
            database: publicDatabase,
            recordType: RecordType.post,
            sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: false)],
            limit: 80
        )

        return records.compactMap { record in
            guard let body = record["body"] as? String else { return nil }
            let isHidden = Self.boolValue(record["isHidden"])
            guard !isHidden else { return nil }
            // CloudKit's creatorUserRecordID is authoritative — set by the
            // server, not the client. Fall back to the client-supplied
            // authorRecordName only if creator metadata is missing (older
            // posts predating this field).
            let verifiedRecordName = record.creatorUserRecordID?.recordName
                ?? (record["authorRecordName"] as? String)
                ?? ""
            return CloudSocialPost(
                id: record.recordID.recordName,
                matchKey: record["matchKey"] as? String ?? "",
                matchTitle: record["matchTitle"] as? String ?? "Partida",
                authorName: record["authorName"] as? String ?? "Fan",
                authorRecordName: verifiedRecordName,
                body: body,
                likes: record["likes"] as? Int ?? 0,
                replyCount: record["replyCount"] as? Int ?? 0,
                eventKey: record["eventKey"] as? String,
                parentPostID: record["parentPostID"] as? String,
                reportCount: record["reportCount"] as? Int ?? 0,
                isHidden: isHidden,
                isPinned: Self.boolValue(record["isPinned"]),
                createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .now
            )
        }
    }

    private func fetchPolls() async throws -> [CloudMatchPoll] {
        guard let publicDatabase else { throw CloudBackendError.accountUnavailable }
        let records = try await queryRecords(
            database: publicDatabase,
            recordType: RecordType.poll,
            sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: false)],
            limit: 30
        )

        return records.compactMap { record in
            guard let question = record["question"] as? String else { return nil }
            return CloudMatchPoll(
                id: record.recordID.recordName,
                matchKey: record["matchKey"] as? String ?? "",
                matchTitle: record["matchTitle"] as? String ?? "Partida",
                question: question,
                optionOne: record["optionOne"] as? String ?? "Opção 1",
                optionTwo: record["optionTwo"] as? String ?? "Opção 2",
                optionThree: record["optionThree"] as? String ?? "",
                votesOne: record["votesOne"] as? Int ?? 0,
                votesTwo: record["votesTwo"] as? Int ?? 0,
                votesThree: record["votesThree"] as? Int ?? 0,
                createdAt: record["createdAt"] as? Date ?? record.creationDate ?? .now
            )
        }
    }

    private func fetchModerationQueue() async throws -> [CloudModerationQueueItem] {
        let endpoint = try moderationEndpoint(path: "/social/moderation/queue", requiresAdmin: true)
        guard var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else {
            throw CloudBackendError.accountUnavailable
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = components.url else {
            throw CloudBackendError.accountUnavailable
        }

        let data = try await getJSONData(from: url, authorization: endpoint.authorization)
        return try JSONDecoder().decode(BackendModerationQueueResponse.self, from: data).queue
    }

    private func fetchModerationAudit() async throws -> [CloudModerationAuditEvent] {
        let endpoint = try moderationEndpoint(path: "/social/moderation/audit", requiresAdmin: true)
        guard var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else {
            throw CloudBackendError.accountUnavailable
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = components.url else {
            throw CloudBackendError.accountUnavailable
        }

        let data = try await getJSONData(from: url, authorization: endpoint.authorization)
        return try JSONDecoder().decode(BackendModerationAuditResponse.self, from: data).audit
    }

    private func fetchCommunityRules() async throws -> [String] {
        let endpoint = try moderationEndpoint(path: "/social/moderation/rules", requiresAdmin: true)
        let data = try await getJSONData(from: endpoint.url, authorization: endpoint.authorization)
        return try JSONDecoder().decode(BackendCommunityRulesResponse.self, from: data).rules
    }

    /// LGPD Art. 18 erasure: removes every CloudKit record owned by the current
    /// iCloud user from public + private DBs. Best-effort — surfaces the first
    /// error to the caller after attempting all categories. Returns the number
    /// of records actually deleted.
    func deleteAllCloudRecordsForCurrentUser() async throws -> Int {
        let userRecordName = try await currentUserRecordName()
        var deleted = 0
        var firstError: Error?

        let userPredicate = NSPredicate(format: "userRecordName == %@", userRecordName)

        if let publicDatabase {
            for recordType in [RecordType.post, RecordType.poll, RecordType.leaderboard] {
                do {
                    deleted += try await wipeRecords(database: publicDatabase, recordType: recordType, predicate: userPredicate)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            do {
                let votePredicate = NSPredicate(format: "userRecordName == %@", userRecordName)
                deleted += try await wipeRecords(database: publicDatabase, recordType: "PollVote", predicate: votePredicate)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let privateDatabase {
            do {
                deleted += try await wipeRecords(database: privateDatabase, recordType: RecordType.bet, predicate: userPredicate)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        await refreshAll()

        if let firstError {
            throw firstError
        }
        return deleted
    }

    private func wipeRecords(database: CKDatabase, recordType: String, predicate: NSPredicate) async throws -> Int {
        let records = try await queryRecords(
            database: database,
            recordType: recordType,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "modificationDate", ascending: false)],
            limit: CKQueryOperation.maximumResults
        )
        guard !records.isEmpty else { return 0 }
        let ids = records.map(\.recordID)
        try await deleteRecordIDs(ids, in: database)
        return ids.count
    }

    private func deleteRecordIDs(_ ids: [CKRecord.ID], in database: CKDatabase) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private func fetchLeaderboard() async throws -> [CloudLeaderboardEntry] {
        guard let publicDatabase else { throw CloudBackendError.accountUnavailable }
        let currentUser = try await currentUserRecordName()
        let records = try await queryRecords(
            database: publicDatabase,
            recordType: RecordType.leaderboard,
            sortDescriptors: [NSSortDescriptor(key: "points", ascending: false)],
            limit: 50
        )

        return records.map { record in
            let userRecordName = record["userRecordName"] as? String ?? record.recordID.recordName
            return CloudLeaderboardEntry(
                id: record.recordID.recordName,
                displayName: record["displayName"] as? String ?? "Fan",
                avatarSymbol: record["avatarSymbol"] as? String ?? "person.crop.circle.fill",
                points: record["points"] as? Int ?? 0,
                wins: record["wins"] as? Int ?? 0,
                losses: record["losses"] as? Int ?? 0,
                currentStreak: record["currentStreak"] as? Int ?? 0,
                updatedAt: record["updatedAt"] as? Date ?? record.modificationDate ?? .now,
                isCurrentUser: userRecordName == currentUser
            )
        }
    }

    private func fetchPreferredLeaderboard(currentUserRecordName: String) async throws -> [CloudLeaderboardEntry] {
        do {
            let entries = try await fetchBackendLeaderboard(currentUserRecordName: currentUserRecordName)
            leaderboardSource = .backendAuthoritative
            return entries
        } catch {
            AppLogger.api.info("Backend leaderboard unavailable; falling back to CloudKit leaderboard")
            let entries = try await fetchLeaderboard()
            leaderboardSource = .cloudKitFallback
            return entries
        }
    }

    private func fetchBackendLeaderboard(currentUserRecordName: String) async throws -> [CloudLeaderboardEntry] {
        let endpoint = try moderationEndpoint(path: "/social/leaderboard", requiresAdmin: false)
        guard var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else {
            throw CloudBackendError.accountUnavailable
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "limit", value: "50"))
        queryItems.append(URLQueryItem(name: "userRecordName", value: currentUserRecordName))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw CloudBackendError.accountUnavailable
        }

        let data = try await getJSONData(from: url, authorization: endpoint.authorization)
        return try Self.decodeBackendLeaderboard(data, currentUserRecordName: currentUserRecordName)
    }

    static func decodeBackendLeaderboard(_ data: Data, currentUserRecordName: String) throws -> [CloudLeaderboardEntry] {
        let response = try JSONDecoder().decode(BackendLeaderboardResponse.self, from: data)
        return response.leaderboard.map { entry in
            CloudLeaderboardEntry(
                id: entry.id ?? "leader-\(entry.userRecordName)",
                displayName: entry.displayName,
                avatarSymbol: entry.avatarSymbol,
                points: entry.points,
                wins: entry.wins,
                losses: entry.losses,
                currentStreak: entry.currentStreak,
                updatedAt: parseBackendDate(entry.updatedAt) ?? .now,
                isCurrentUser: entry.isCurrentUser ?? (entry.userRecordName == currentUserRecordName)
            )
        }
    }

    private static func parseBackendDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private func queryRecords(
        database: CKDatabase,
        recordType: String,
        predicate: NSPredicate = NSPredicate(value: true),
        sortDescriptors: [NSSortDescriptor],
        limit: Int
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        return try await withCheckedThrowingContinuation { continuation in
            var records: [CKRecord] = []

            func run(_ operation: CKQueryOperation) {
                // Ask for at most what's still needed, capped at the CloudKit
                // page size — prevents fetching thousands of records at once.
                operation.resultsLimit = min(limit - records.count, 100)
                operation.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        records.append(record)
                    }
                }
                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        // Follow cursor pages until `limit` is satisfied or
                        // CloudKit says there are no more records.
                        if let cursor, records.count < limit {
                            run(CKQueryOperation(cursor: cursor))
                        } else {
                            continuation.resume(returning: records)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }

            run(CKQueryOperation(query: query))
        }
    }

    private func currentUserRecordName() async throws -> String {
        if let cachedUserRecordName {
            return cachedUserRecordName
        }

        guard let container else {
            throw CloudBackendError.accountUnavailable
        }

        let status = try await container.accountStatus()
        guard status == .available else {
            throw CloudBackendError.accountUnavailable
        }

        let recordID = try await container.userRecordID()
        cachedUserRecordName = recordID.recordName
        return recordID.recordName
    }

    private func matchKey(for match: TennisMatch?) -> String {
        match?.externalID ?? match?.id.uuidString ?? "global"
    }

    private func matchTitle(for match: TennisMatch?) -> String {
        guard let match else { return "Discussão geral" }
        return "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }

    private static func userFacingCloudMessage(for error: Error) -> String {
        if let backendError = error as? CloudBackendError {
            return backendError.localizedDescription
        }

        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return "Entre no iCloud para sincronizar."
            case .networkUnavailable, .networkFailure:
                return "Sem conexão com iCloud."
            case .permissionFailure:
                return "CloudKit sem permissão neste app."
            default:
                return ckError.localizedDescription
            }
        }

        return error.localizedDescription
    }

    private static func boolValue(_ value: CKRecordValue?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let int = value as? Int { return int != 0 }
        if let str = value as? String { return str == "1" || str.lowercased() == "true" }
        if let value {
            AppLogger.persistence.warning("boolValue: unexpected CKRecordValue type \(String(describing: type(of: value)), privacy: .public), defaulting to false")
        }
        return false
    }
}

private enum CloudBackendError: LocalizedError, UserPresentableError {
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            return "iCloud indisponível neste aparelho."
        }
    }

    var userFacing: UserFacingSyncFeedback {
        switch self {
        case .accountUnavailable:
            return UserFacingSyncFeedback(
                kind: .configuration,
                title: "iCloud indisponível",
                message: "Não foi possível acessar a conta iCloud neste aparelho.",
                recoverySuggestion: "Verifique se está conectado ao iCloud em Ajustes → ID Apple e tente novamente."
            )
        }
    }
}

private extension String {
    var stableCloudIdentifier: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .prefix(220)
            .description
    }
}
