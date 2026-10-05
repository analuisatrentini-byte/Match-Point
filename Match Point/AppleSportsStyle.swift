import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Design tokens
//
// Surface tokens for the translucent card pattern repeated across the app
// (~30 sites used `Color.white.opacity(0.10)` or `0.20` inline). Centralizing
// them here lets a single edit retune the entire theme — particularly useful
// when adjusting for a light-mode pass or a Liquid Glass refresh.

extension Color {
    static let matchPointPurple = Color(red: 0.34, green: 0.12, blue: 0.66)
    static let matchPointPurpleDeep = Color(red: 0.10, green: 0.03, blue: 0.24)
    static let matchPointGreen = Color(red: 0.34, green: 0.92, blue: 0.48)
    static let matchPointGreenDeep = Color(red: 0.02, green: 0.28, blue: 0.17)
    static let readableSecondary = Color.white.opacity(0.88)
    static let readableTertiary = Color.white.opacity(0.76)

    /// Default card / chip / pill background — sits over the gradient and is
    /// readable but subtle. Replaces `Color.white.opacity(0.10)` inline.
    static let cardSurface = Color.black.opacity(0.38)

    /// Hover / selected variant — 2x the opacity of `cardSurface` so the
    /// selected state has a perceptible bump.
    static let cardSurfaceHover = Color.black.opacity(0.52)

    /// Stroke / border at the edge of cards. Lighter than `cardSurface`.
    static let cardSurfaceStroke = Color.white.opacity(0.34)

    /// Heavy overlay used behind score badges, tour pills, etc.
    static let cardOverlay = Color.black.opacity(0.46)

    /// Subtle overlay for nav bars, dividers.
    static let cardOverlaySoft = Color.black.opacity(0.28)
}

// Global UIKit chrome (tab bar + navigation bar) tuned to sit on top of the
// Apple Sports gradient backgrounds. Both bars use a transparent dark blur so
// the gradient bleeds through; titles and tab items render in white.
enum AppleSportsAppearance {
    static func applyGlobalChrome() {
        #if canImport(UIKit)
        let blur = UIBlurEffect(style: .systemThinMaterialDark)
        let chromeTint = UIColor(red: 0.08, green: 0.03, blue: 0.18, alpha: 0.72)

        let tabBar = UITabBarAppearance()
        tabBar.configureWithTransparentBackground()
        tabBar.backgroundEffect = blur
        tabBar.backgroundColor = chromeTint
        applyTabItem(tabBar.stackedLayoutAppearance)
        applyTabItem(tabBar.inlineLayoutAppearance)
        applyTabItem(tabBar.compactInlineLayoutAppearance)
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
        UITabBar.appearance().tintColor = UIColor(red: 0.50, green: 1.00, blue: 0.60, alpha: 1.0)
        UITabBar.appearance().unselectedItemTintColor = UIColor.white.withAlphaComponent(0.72)

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundEffect = nil
        nav.backgroundColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = .white

        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear

        let segmented = UISegmentedControl.appearance()
        segmented.backgroundColor = UIColor.black.withAlphaComponent(0.46)
        segmented.selectedSegmentTintColor = UIColor(red: 0.34, green: 0.92, blue: 0.48, alpha: 0.32)
        segmented.setTitleTextAttributes(
            [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
            ],
            for: .selected
        )
        segmented.setTitleTextAttributes(
            [
                .foregroundColor: UIColor.white.withAlphaComponent(0.76),
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
            ],
            for: .normal
        )
        #endif
    }

    #if canImport(UIKit)
    private static func applyTabItem(_ appearance: UITabBarItemAppearance) {
        appearance.normal.iconColor = UIColor.white.withAlphaComponent(0.72)
        appearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.72)]
        appearance.selected.iconColor = UIColor(red: 0.50, green: 1.00, blue: 0.60, alpha: 1.0)
        appearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
    }
    #endif
}

// Centralized visual tokens that give the app the "Apple Sports" look:
// saturated gradient backgrounds, glass cards, pill segmented controls and
// a dark color scheme that makes existing `.secondary` labels render with
// the right opacity over the colored backgrounds.

enum AppleSportsTheme {
    case clay     // warm Roland Garros orange/red — live & match contexts
    case royal    // deep violet — lists, rankings, social, profile
    case midnight // dark navy — fallback / neutral

    fileprivate var gradientColors: [Color] {
        switch self {
        case .clay:
            return [
                .matchPointGreenDeep,
                Color(red: 0.16, green: 0.09, blue: 0.32),
                .matchPointPurpleDeep
            ]
        case .royal:
            return [
                .matchPointPurple,
                Color(red: 0.16, green: 0.07, blue: 0.40),
                .matchPointPurpleDeep,
                .matchPointGreenDeep
            ]
        case .midnight:
            return [
                .matchPointPurpleDeep,
                Color(red: 0.03, green: 0.12, blue: 0.11),
                Color(red: 0.02, green: 0.06, blue: 0.08)
            ]
        }
    }

    fileprivate var accentColor: Color {
        switch self {
        case .clay:
            return .matchPointGreen
        case .royal:
            return .matchPointGreen
        case .midnight:
            return Color(red: 0.68, green: 0.54, blue: 1.00)
        }
    }
}

// MARK: - Grand Slam seasonal themes
//
// `SlamSeason` describes the automatic Grand Slam windows used by surfaces such as
// the Live Activity scoreboard. The main app keeps its standard Match Point
// identity; individual call sites opt in only when they need a seasonal palette.

nonisolated enum SlamSeason: String, Codable, CaseIterable, Identifiable, Sendable {
    case australianOpen
    case rolandGarros
    case wimbledon
    case usOpen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .australianOpen: return "Australian Open"
        case .rolandGarros: return "Roland Garros"
        case .wimbledon: return "Wimbledon"
        case .usOpen: return "US Open"
        }
    }

    fileprivate var gradientColors: [Color] {
        switch self {
        case .australianOpen:
            // DecoTurf blue: bright cyan-blue → navy.
            return [
                Color(red: 0.00, green: 0.50, blue: 0.80),
                Color(red: 0.00, green: 0.30, blue: 0.58),
                Color(red: 0.00, green: 0.17, blue: 0.36)
            ]
        case .rolandGarros:
            // Deeper terracotta than the generic `.clay` to feel "the RG one".
            return [
                Color(red: 0.74, green: 0.27, blue: 0.16),
                Color(red: 0.50, green: 0.16, blue: 0.10),
                Color(red: 0.27, green: 0.09, blue: 0.06)
            ]
        case .wimbledon:
            // Wimbledon grass green sliding into the famous purple.
            return [
                Color(red: 0.00, green: 0.36, blue: 0.22),
                Color(red: 0.12, green: 0.17, blue: 0.32),
                Color(red: 0.22, green: 0.10, blue: 0.36)
            ]
        case .usOpen:
            // DecoTurf USO blue; the signature yellow lives on the accent only
            // (yellow background would wreck legibility of white text).
            return [
                Color(red: 0.16, green: 0.47, blue: 0.73),
                Color(red: 0.07, green: 0.26, blue: 0.50),
                Color(red: 0.03, green: 0.12, blue: 0.30)
            ]
        }
    }

    fileprivate var accentColor: Color {
        switch self {
        case .australianOpen: return Color(red: 0.30, green: 0.78, blue: 1.00)
        case .rolandGarros: return Color(red: 0.95, green: 0.55, blue: 0.30)
        case .wimbledon: return Color(red: 0.72, green: 0.90, blue: 0.56)
        case .usOpen: return Color(red: 1.00, green: 0.83, blue: 0.00)
        }
    }

    /// Year-agnostic month/day windows wide enough to cover qualifying + main draw + final
    /// so the theme phases in a week before each Slam and out a few days after.
    static func current(for date: Date, calendar: Calendar = .init(identifier: .gregorian)) -> SlamSeason? {
        let comps = calendar.dateComponents([.month, .day], from: date)
        guard let month = comps.month, let day = comps.day else { return nil }
        let mmdd = month * 100 + day
        switch mmdd {
        case 110...209: return .australianOpen   // mid-Jan → early Feb
        case 515...615: return .rolandGarros     // late May → mid-Jun
        case 620...720: return .wimbledon        // late Jun → mid-Jul
        case 815...920: return .usOpen           // late Aug → mid-Sep
        default: return nil
        }
    }
}

private struct SlamSeasonEnvironmentKey: EnvironmentKey {
    static let defaultValue: SlamSeason? = nil
}

extension EnvironmentValues {
    /// When non-nil, `.appleSportsBackground(_:)` swaps the gradient and accent
    /// for the Slam's palette instead of the semantic theme passed at the call site.
    var slamSeason: SlamSeason? {
        get { self[SlamSeasonEnvironmentKey.self] }
        set { self[SlamSeasonEnvironmentKey.self] = newValue }
    }
}

private struct AppleSportsBackground: ViewModifier {
    let theme: AppleSportsTheme
    @Environment(\.slamSeason) private var slamSeason

    func body(content: Content) -> some View {
        let colors = slamSeason?.gradientColors ?? theme.gradientColors
        let accent = slamSeason?.accentColor ?? theme.accentColor
        content
            .scrollContentBackground(.hidden)
            .background(
                ZStack {
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.10),
                            Color.black.opacity(0.30),
                            Color.black.opacity(0.44)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                    .ignoresSafeArea()
            )
            .foregroundStyle(Color.white)
            .tint(accent)
            .preferredColorScheme(.dark)
    }
}

private struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    var padding: CGFloat = 16

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, *) {
            content
                .padding(padding)
                .background {
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.34)))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.30), lineWidth: 1))
                }
                .glassEffect(.regular.tint(.matchPointPurple.opacity(0.18)).interactive(), in: shape)
                .shadow(color: Color.black.opacity(0.34), radius: 18, x: 0, y: 10)
        } else {
            content
                .padding(padding)
                .background(
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.36)))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.30), lineWidth: 1))
                )
                .shadow(color: Color.black.opacity(0.30), radius: 16, x: 0, y: 8)
        }
    }
}

private struct GlassPill: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, *) {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.34)))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.30), lineWidth: 1))
                )
                .glassEffect(.regular.tint(.matchPointGreen.opacity(0.18)).interactive(), in: shape)
        } else {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    shape
                        .fill(.regularMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.36)))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.30), lineWidth: 1))
                )
        }
    }
}

extension View {
    func appleSportsBackground(_ theme: AppleSportsTheme = .royal) -> some View {
        modifier(AppleSportsBackground(theme: theme))
    }

    func liquidGlassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, padding: padding))
    }

    func glassPill() -> some View {
        modifier(GlassPill())
    }

    func appListCardRow(cornerRadius: CGFloat = 18, padding: CGFloat = 14) -> some View {
        self
            .foregroundStyle(Color.white)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color.matchPointPurpleDeep.opacity(0.42)
                    LinearGradient(
                        colors: [
                            Color.matchPointPurple.opacity(0.30),
                            Color.matchPointGreen.opacity(0.10),
                            Color.black.opacity(0.24)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.cardSurfaceStroke.opacity(0.34), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.20), radius: 14, x: 0, y: 8)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func appListPlainRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// Pill-shaped segmented control used on the Apple Sports match detail screen.
struct AppleSportsSegmentedPicker<SelectionValue: Hashable>: View {
    let options: [(label: String, value: SelectionValue)]
    @Binding var selection: SelectionValue

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(selection == option.value ? Color.white : Color.readableSecondary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection == option.value ? Color.matchPointGreen.opacity(0.30) : Color.clear)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(selection == option.value ? Color.white.opacity(0.28) : Color.clear, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.black.opacity(0.42)))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
        )
    }
}

// Horizontal head-to-head bar used on the stats screen (red gradient bars
// flanking a centered label).
struct AppleSportsStatBar: View {
    let leftValue: String
    let label: String
    let rightValue: String
    let leftRatio: Double // 0...1 — share of the bar belonging to the left side
    var leftColor: Color = Color(red: 0.92, green: 0.30, blue: 0.30)
    var rightColor: Color = Color(red: 0.95, green: 0.55, blue: 0.30)

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(leftValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Color.readableSecondary)
                Spacer()
                Text(rightValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            GeometryReader { geo in
                let clamped = max(0, min(1, leftRatio))
                let leftWidth = geo.size.width * clamped
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    HStack(spacing: 0) {
                        Capsule().fill(leftColor)
                            .frame(width: leftWidth)
                        Capsule().fill(rightColor)
                            .frame(width: geo.size.width - leftWidth)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}
