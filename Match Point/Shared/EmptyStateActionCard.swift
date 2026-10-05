import SwiftUI

// MARK: - EmptyStateActionCard
//
// Empty states that don't just say "sincronize". Every card offers a
// concrete next action the user can take from where they are:
//   • Ir para os favoritos (when data is present but the user hasn't
//     favorited anyone)
//   • Ajustar filtros / tour switch (when data is present but filtered out)

struct EmptyStateActionCard: View {
    let title: String
    let message: String
    let systemImage: String
    let primaryAction: EmptyStateAction?
    let secondaryAction: EmptyStateAction?

    init(
        title: String,
        message: String,
        systemImage: String,
        primaryAction: EmptyStateAction? = nil,
        secondaryAction: EmptyStateAction? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline.weight(.bold))
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let primaryAction {
                Button(role: primaryAction.role) {
                    primaryAction.handler()
                } label: {
                    Label(primaryAction.label, systemImage: primaryAction.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(primaryAction.tint)
                .accessibilityIdentifier(primaryAction.accessibilityIdentifier ?? "empty-state-primary")
            }

            if let secondaryAction {
                Button(role: secondaryAction.role) {
                    secondaryAction.handler()
                } label: {
                    Label(secondaryAction.label, systemImage: secondaryAction.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(secondaryAction.tint)
                .accessibilityIdentifier(secondaryAction.accessibilityIdentifier ?? "empty-state-secondary")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-state-card")
    }
}

struct EmptyStateAction {
    let label: String
    let systemImage: String
    let tint: Color
    let role: ButtonRole?
    let accessibilityIdentifier: String?
    let handler: () -> Void

    init(
        label: String,
        systemImage: String,
        tint: Color = .green,
        role: ButtonRole? = nil,
        accessibilityIdentifier: String? = nil,
        handler: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.accessibilityIdentifier = accessibilityIdentifier
        self.handler = handler
    }
}
