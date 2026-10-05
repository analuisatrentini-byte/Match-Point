import SwiftUI
import SwiftData

// MARK: - Matchboxd Helpers

extension SocialFeedView {
    /// Review IDs for which a report request is already in flight.
    /// Prevents the user from sending multiple reports for the same review
    /// before the first one resolves.
    @MainActor static var reportingReviewIDs: Set<String> = []

    var blockedReviewAuthorKeys: Set<String> {
        guard let data = blockedReviewAuthorsData.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    func blockReviewAuthor(_ key: String) {
        guard !key.isEmpty else { return }
        var blocked = blockedReviewAuthorKeys
        blocked.insert(key)
        if let data = try? JSONEncoder().encode(blocked.sorted()),
           let payload = String(data: data, encoding: .utf8) {
            blockedReviewAuthorsData = payload
        }
    }

    func cloudReviewAuthorBlockKey(for post: CloudSocialPost) -> String {
        if !post.authorRecordName.isEmpty {
            return "cloud:\(post.authorRecordName)"
        }
        return "name:\(post.authorName)"
    }

    func localReviewAuthorBlockKey(for post: SocialPost) -> String {
        "name:\(post.authorName)"
    }

    func isOwnCloudReview(_ post: CloudSocialPost) -> Bool {
        if !post.authorRecordName.isEmpty, post.authorRecordName == cloudBackend.currentUserLabel {
            return true
        }
        return post.authorName == profileName
    }

    var canPublishReview: Bool {
        let body = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        return reviewValidationIssue == nil
    }

    var reviewValidationIssue: String? {
        let combined = [reviewTitle, reviewText].joined(separator: " ")
        return ObjectionableContentFilter.firstIssue(in: combined)
    }

    var sortedCloudPosts: [CloudSocialPost] {
        let reviews = cloudBackend.posts.filter {
            !$0.isHidden
                && MatchReviewEncoding.rating(from: $0.eventKey) != nil
                && $0.parentPostID == nil
                && !blockedReviewAuthorKeys.contains(cloudReviewAuthorBlockKey(for: $0))
        }
        if sortMode == "Populares" {
            return reviews.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.likes > $1.likes
            }
        }
        return reviews.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.createdAt > $1.createdAt
        }
    }

    func cloudPostCard(_ post: CloudSocialPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(post.authorName, systemImage: postIconName(eventKey: post.eventKey, isReply: post.parentPostID != nil))
                    .font(.headline)
                    .foregroundStyle(postTint(eventKey: post.eventKey))
                Spacer()
                if post.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(post.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }

            Text(post.matchTitle)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            if let rating = MatchReviewEncoding.rating(from: post.eventKey) {
                ratingRow(rating: rating)
                let parts = MatchReviewEncoding.splitBody(post.body)
                if let title = parts.title {
                    Text(title)
                        .font(.headline.weight(.bold))
                }
                Text(parts.body)
            } else {
                Text(post.body)
            }

            HStack {
                Button {
                    Task {
                        await cloudBackend.likePost(post)
                    }
                } label: {
                    Label("Curtir \(post.likes)", systemImage: "heart")
                        .accessibilityLabel("Curtir avaliação. \(post.likes) curtidas.")
                }
                Button {
                    let postID = post.id
                    guard !SocialFeedView.reportingReviewIDs.contains(postID) else { return }
                    SocialFeedView.reportingReviewIDs.insert(postID)
                    Task {
                        await cloudBackend.reportPost(post)
                        SocialFeedView.reportingReviewIDs.remove(postID)
                    }
                } label: {
                    Label("Denunciar \(post.reportCount)", systemImage: "flag")
                }
                .accessibilityIdentifier("cloud-report-review")
                if !isOwnCloudReview(post) {
                    Button(role: .destructive) {
                        blockReviewAuthor(cloudReviewAuthorBlockKey(for: post))
                    } label: {
                        Label("Bloquear", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .accessibilityIdentifier("cloud-block-review-author")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    func postCard(_ post: SocialPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(post.authorName, systemImage: postIconName(eventKey: post.eventKey, isReply: post.parentPostID != nil))
                    .font(.headline)
                    .foregroundStyle(postTint(eventKey: post.eventKey))
                Spacer()
                if post.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(post.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if let match = post.match {
                Text(matchTitle(match))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            if let rating = MatchReviewEncoding.rating(from: post.eventKey) {
                ratingRow(rating: rating)
                let parts = MatchReviewEncoding.splitBody(post.body)
                if let title = parts.title {
                    Text(title)
                        .font(.headline.weight(.bold))
                }
                Text(parts.body)
            } else {
                Text(post.body)
            }
            HStack {
                Button {
                    post.likes += 1
                } label: {
                    Label("Curtir \(post.likes)", systemImage: "heart")
                        .accessibilityLabel("Curtir avaliação. \(post.likes) curtidas.")
                }
                Button {
                    post.reportCount += 1
                    if post.reportCount >= 3 {
                        post.isHidden = true
                    }
                } label: {
                    Label("Denunciar \(post.reportCount)", systemImage: "flag")
                }
                .accessibilityIdentifier("local-report-review")
                if post.authorName != profileName {
                    Button(role: .destructive) {
                        blockReviewAuthor(localReviewAuthorBlockKey(for: post))
                    } label: {
                        Label("Bloquear", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .accessibilityIdentifier("local-block-review-author")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    func pollCard(_ poll: MatchPoll) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(safePollQuestion(poll.question))
                .font(.headline)
            if let match = poll.match {
                Text(matchTitle(match))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            pollOption(title: poll.optionOne, votes: poll.votesOne, total: poll.totalVotes) {
                poll.votesOne += 1
                Task { await cloudBackend.voteOnLocalPoll(poll, optionIndex: 1) }
            }
            pollOption(title: poll.optionTwo, votes: poll.votesTwo, total: poll.totalVotes) {
                poll.votesTwo += 1
                Task { await cloudBackend.voteOnLocalPoll(poll, optionIndex: 2) }
            }
            if !poll.optionThree.isEmpty {
                pollOption(title: poll.optionThree, votes: poll.votesThree, total: poll.totalVotes) {
                    poll.votesThree += 1
                    Task { await cloudBackend.voteOnLocalPoll(poll, optionIndex: 3) }
                }
            }
        }
    }

    func cloudPollCard(_ poll: CloudMatchPoll) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(safePollQuestion(poll.question))
                .font(.headline)
            Text(poll.matchTitle)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)

            cloudPollOption(title: poll.optionOne, votes: poll.votesOne, total: poll.totalVotes) {
                Task { await cloudBackend.vote(on: poll, optionIndex: 1) }
            }
            cloudPollOption(title: poll.optionTwo, votes: poll.votesTwo, total: poll.totalVotes) {
                Task { await cloudBackend.vote(on: poll, optionIndex: 2) }
            }
            if !poll.optionThree.isEmpty {
                cloudPollOption(title: poll.optionThree, votes: poll.votesThree, total: poll.totalVotes) {
                    Task { await cloudBackend.vote(on: poll, optionIndex: 3) }
                }
            }
        }
    }

    func pollOption(title: String, votes: Int, total: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.pollPercentageLabel(votes: votes, total: total))
                    .monospacedDigit()
            }
        }
        .socialActionButtonStyle()
    }

    func cloudPollOption(title: String, votes: Int, total: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.pollPercentageLabel(votes: votes, total: total))
                    .monospacedDigit()
            }
        }
        .socialActionButtonStyle()
    }

    /// Single guard against divide-by-zero when CloudMatchPoll structs are
    /// rebuilt mid-render from CloudKit refresh. Funnel both poll cards
    /// through this helper so the check is colocated with the division.
    private static func pollPercentageLabel(votes: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        let percentage = Int((Double(votes) / Double(total)) * 100)
        return "\(percentage)%"
    }

    func addReview() async {
        let body = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if let issue = reviewValidationIssue {
            reviewValidationMessage = issue
            return
        }
        let title = reviewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedBody = MatchReviewEncoding.body(title: title, review: body)
        let eventKey = MatchReviewEncoding.review(rating: reviewRating)
        context.insert(SocialPost(match: selectedMatch, authorName: profileName, body: encodedBody, eventKey: eventKey))
        reviewText = ""
        reviewTitle = ""
        reviewValidationMessage = nil
        await cloudBackend.publishMatchReview(match: selectedMatch, authorName: profileName, body: encodedBody, eventKey: eventKey)
    }

    @ViewBuilder
    func ratingRow(rating: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= rating ? "star.fill" : "star")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(value <= rating ? .yellow : Color.readableSecondary)
            }
            Text("\(rating)/5")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.readableSecondary)
        }
    }

    func postIconName(eventKey: String?, isReply: Bool) -> String {
        if MatchReviewEncoding.rating(from: eventKey) != nil { return "star.bubble.fill" }
        return eventKey == nil ? "person.crop.circle" : "bolt.circle.fill"
    }

    func postTint(eventKey: String?) -> Color {
        if MatchReviewEncoding.rating(from: eventKey) != nil { return .yellow }
        return eventKey == nil ? Color.primary : Color.orange
    }

    func createPoll(for match: TennisMatch) {
        let question = "Quem vence?"
        let localPoll = MatchPoll(
            match: match,
            question: question,
            optionOne: match.player1TeamName,
            optionTwo: match.player2TeamName,
            optionThree: "Vai ao tie-break"
        )
        context.insert(localPoll)
        Task {
            if let cloudRecordID = await cloudBackend.createPoll(match: match, question: question) {
                localPoll.cloudRecordID = cloudRecordID
            }
        }
    }

    func matchTitle(_ match: TennisMatch) -> String {
        "\(match.player1TeamName) vs \(match.player2TeamName)"
    }

    func cloudMatchKey(for match: TennisMatch) -> String {
        match.externalID ?? match.id.uuidString
    }

    func safePollQuestion(_ question: String) -> String {
        question == "Quem vence?" ? question : "Quem vence?"
    }

}

private extension View {
    func socialActionButtonStyle() -> some View {
        self
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.readableSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.cardOverlaySoft)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.cardSurfaceStroke.opacity(0.20), lineWidth: 1)
            }
    }
}

enum MatchReviewEncoding {
    static func review(rating: Int) -> String {
        "review:\(min(max(rating, 1), 5)):\(UUID().uuidString)"
    }

    static func rating(from eventKey: String?) -> Int? {
        guard let eventKey else { return nil }
        let parts = eventKey.split(separator: ":")
        guard parts.count >= 2, parts[0] == "review", let rating = Int(parts[1]) else { return nil }
        return min(max(rating, 1), 5)
    }

    static func body(title: String, review: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReview = review.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return trimmedReview }
        return "\(trimmedTitle)\n\n\(trimmedReview)"
    }

    static func splitBody(_ value: String) -> (title: String?, body: String) {
        let parts = value.components(separatedBy: "\n\n")
        guard parts.count > 1 else { return (nil, value) }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let body = parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body.isEmpty ? value : body)
    }
}

enum ObjectionableContentFilter {
    private static let blockedPhrases = [
        "kill yourself",
        "kys",
        "go die",
        "porn",
        "nazi",
        "terrorist",
        "se mata",
        "vai morrer",
        "pornografia",
        "nazista",
        "terrorista"
    ]

    static func firstIssue(in text: String) -> String? {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard blockedPhrases.contains(where: { normalized.contains($0) }) else {
            return nil
        }
        return "Ajuste a avaliação antes de publicar. Conteúdo ofensivo ou abusivo não é permitido."
    }
}
