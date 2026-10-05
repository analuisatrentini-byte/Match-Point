import SwiftUI
import SwiftData

// MARK: - Pick Detail
//
// Dedicated screen for a single pick. Shows the visual PickShareCard at the
// top, an emoji reaction bar with counts, threaded comments (mixing local
// SocialPosts + cloud CloudSocialPosts) and a share button. This is the
// canonical page for a pick's social life — the profile row and public
// profile both push into this view.

struct PickDetailView: View {
    let bet: PointBet

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloudBackend: CloudSocialBackend
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @Query(sort: \SocialPost.createdAt, order: .reverse) private var localPosts: [SocialPost]
    @Query(sort: \PointBet.createdAt, order: .reverse) private var bets: [PointBet]

    @State private var commentDraft = ""
    @State private var isPublishing = false
    @FocusState private var commentFocused: Bool

    private var profile: UserProfile? { profiles.first }
    private var profileName: String { profile?.displayName ?? "Match Point Fan" }

    private var summary: PickInteractionSummary {
        PickInteractionAnalyzer.summary(
            for: bet.id,
            localPosts: localPosts,
            cloudPosts: cloudBackend.posts,
            viewer: profileName
        )
    }

    private var comments: [PickCommentEntry] {
        PickInteractionAnalyzer.comments(
            for: bet.id,
            localPosts: localPosts,
            cloudPosts: cloudBackend.posts
        )
    }

    private var predictionStats: PredictionStats {
        PredictionStats(bets: bets)
    }

    private var weeklySummary: WeeklySocialSummary {
        WeeklySocialSummary(
            season: SocialSeason.weekly(),
            rank: cloudRank,
            localLeaderboardCount: max(cloudBackend.leaderboard.count, 1),
            stats: predictionStats
        )
    }

    private var cloudRank: Int {
        if let index = cloudBackend.leaderboard.firstIndex(where: { $0.isCurrentUser }) {
            return index + 1
        }
        return 1
    }

    var body: some View {
        List {
            Section {
                PickShareCard(
                    bet: bet,
                    profileName: profileName,
                    weeklySummary: weeklySummary
                )
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .appListCardRow(cornerRadius: 22, padding: 10)
                .accessibilityIdentifier("pick-detail-share-card")
                shareRow
                    .appListCardRow()
            }

            Section("Reações") {
                reactionsBar
                    .appListCardRow()
            }

            Section("Interações rápidas") {
                ForEach(PickSocialAction.actions(for: bet)) { action in
                    Button {
                        publishAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .appListCardRow()
                }
            }

            Section("Comentários (\(summary.commentCount))") {
                commentComposer
                    .appListCardRow()
                if comments.isEmpty {
                    ContentUnavailableView {
                        Label("Sem comentários", systemImage: "bubble.left")
                    } description: {
                        Text("Seja o primeiro a comentar este pick.")
                    } actions: {
                        Button {
                            commentFocused = true
                        } label: {
                            Label("Comentar", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .accessibilityIdentifier("pick-detail-empty-comment")
                    }
                    .appListCardRow()
                } else {
                    ForEach(comments) { entry in
                        commentRow(entry)
                            .appListCardRow()
                    }
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Pick")
        .accessibilityIdentifier("pick-detail-screen")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            await cloudBackend.refreshAll()
        }
        .refreshable {
            await cloudBackend.refreshAll()
        }
    }

    private var shareRow: some View {
        HStack {
            if let profile,
               let payload = PickShareCardRenderer.payload(for: bet, profile: profile, weeklySummary: weeklySummary) {
                ShareLink(
                    item: payload,
                    preview: SharePreview("Pick Match Point", image: Image(systemName: "ticket"))
                ) {
                    Label("Compartilhar card", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("pick-detail-share-card-link")
            } else {
                ShareLink(item: ShareTextFactory.prediction(bet)) {
                    Label("Compartilhar", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("pick-detail-share-fallback")
            }
        }
    }

    private var reactionsBar: some View {
        HStack(spacing: 8) {
            ForEach(PickReactionKind.allCases) { kind in
                Button {
                    publishReaction(kind)
                } label: {
                    ReactionChip(
                        emoji: kind.emoji,
                        label: kind.label,
                        count: summary.count(for: kind),
                        isSelected: summary.viewerReactions.contains(kind)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(kind.label). \(summary.count(for: kind)) reações.")
                .accessibilityIdentifier("pick-detail-reaction-\(kind.rawValue)")
            }
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Escreva um comentário", text: $commentDraft, axis: .vertical)
                .focused($commentFocused)
                .accessibilityIdentifier("pick-detail-comment-field")
            HStack {
                Text("\(commentDraft.count)/280")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(commentDraft.count > 280 ? .red : Color.readableSecondary)
                Spacer()
                Button {
                    Task { await publishComment() }
                } label: {
                    if isPublishing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Publicar", systemImage: "paperplane.fill")
                    }
                }
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || commentDraft.count > 280
                          || isPublishing)
                .accessibilityIdentifier("pick-detail-comment-send")
            }
        }
    }

    private func commentRow(_ entry: PickCommentEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(entry.authorName, systemImage: entry.source == .cloud ? "cloud.fill" : "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
            }
            Text(entry.body)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func publishReaction(_ kind: PickReactionKind) {
        let eventKey = PickInteractionEncoding.reaction(betID: bet.id, kind: kind)
        let body = "\(kind.emoji) \(kind.label) — \(pickContextLine())"
        context.insert(SocialPost(
            match: bet.match,
            authorName: profileName,
            body: body,
            eventKey: eventKey
        ))
        Task { @MainActor in
            await cloudBackend.publishComment(match: bet.match, authorName: profileName, body: body)
        }
    }

    private func publishAction(_ action: PickSocialAction) {
        let body = "\(action.body) \(pickContextLine())"
        let eventKey = PickInteractionEncoding.comment(betID: bet.id)
        context.insert(SocialPost(
            match: bet.match,
            authorName: profileName,
            body: body,
            eventKey: eventKey
        ))
        Task { @MainActor in
            await cloudBackend.publishComment(match: bet.match, authorName: profileName, body: body)
        }
    }

    private func publishComment() async {
        let draft = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, draft.count <= 280 else { return }
        isPublishing = true
        defer { isPublishing = false }

        let body = "\(draft) \(pickContextLine())"
        let eventKey = PickInteractionEncoding.comment(betID: bet.id)
        context.insert(SocialPost(
            match: bet.match,
            authorName: profileName,
            body: body,
            eventKey: eventKey
        ))
        commentDraft = ""
        await cloudBackend.publishComment(match: bet.match, authorName: profileName, body: body)
    }

    private func pickContextLine() -> String {
        let matchTitle = bet.match.map { "\($0.player1TeamName) vs \($0.player2TeamName)" } ?? "Partida"
        return "[\(matchTitle) • \(bet.kind.rawValue): \(bet.selection)]"
    }
}

struct ReactionChip: View {
    let emoji: String
    let label: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(emoji)
                .font(.title2)
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.bold))
        }
        .frame(minWidth: 48)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.green.opacity(0.20) : Color.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
