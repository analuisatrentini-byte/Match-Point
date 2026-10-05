//
//  Shared favorite UI primitives.
//
//  Um único arquivo é a "fonte da verdade" para o padrão de favoritar:
//  • `favoriteButton` — botão de estrela usado em toolbars de detalhe.
//  • `favoriteSwipeAction` — swipe-action de listagem (Players/Tours/Matches).
//  • `favoriteToolbar` — açúcar para colocar o `favoriteButton` no toolbar
//    com `ToolbarItem(placement: .automatic)` sem repetir 4 linhas em cada
//    view de detalhe.
//
//  Quando o padrão mudar (cor, ícone, posição, copy, a11y), troque aqui e
//  todas as superfícies herdam — sem precisar rastrear 6 call sites.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private func favoriteHaptic(isFavoriting: Bool) {
    #if canImport(UIKit)
    let generator = UIImpactFeedbackGenerator(style: isFavoriting ? .medium : .light)
    generator.impactOccurred()
    #endif
}

@ViewBuilder
func favoriteButton(isFavorite: Bool, action: @escaping () -> Void) -> some View {
    Button(action: {
        favoriteHaptic(isFavoriting: !isFavorite)
        if !isFavorite {
            NotificationCenter.default.post(name: .didFirstFavorite, object: nil)
        }
        action()
        NotificationCenter.default.post(name: .didToggleFavorite, object: nil)
    }) {
        Image(systemName: isFavorite ? "star.fill" : "star")
            .foregroundStyle(isFavorite ? .yellow : .primary)
    }
    .accessibilityLabel("Favorito")
    .accessibilityValue(isFavorite ? "Ativado" : "Desativado")
    .accessibilityHint(isFavorite ? "Toque duas vezes para remover dos favoritos" : "Toque duas vezes para favoritar")
}

extension View {
    /// Swipe-action canônico de favoritar em listas. Substitui o bloco
    /// `.swipeActions { Button { ... } label: { Label(... star/star.slash) }.tint(.yellow) }`
    /// duplicado em MatchesView, ToursView e PlayersView.
    func favoriteSwipeAction(isFavorite: Bool, onToggle: @escaping () -> Void) -> some View {
        self.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: {
                favoriteHaptic(isFavoriting: !isFavorite)
                if !isFavorite {
                    NotificationCenter.default.post(name: .didFirstFavorite, object: nil)
                }
                onToggle()
                NotificationCenter.default.post(name: .didToggleFavorite, object: nil)
            }) {
                Label(
                    isFavorite ? "Remover favorito" : "Favoritar",
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            .tint(.yellow)
        }
    }

    /// Toolbar canônico com o `favoriteButton` na posição padrão. Substitui o
    /// bloco `.toolbar { ToolbarItem(placement: .automatic) { favoriteButton(...) } }`
    /// duplicado em MatchDetailView, TournamentDetailView e PlayerDetailView.
    func favoriteToolbar(isFavorite: Bool, onToggle: @escaping () -> Void) -> some View {
        self.toolbar {
            ToolbarItem(placement: .automatic) {
                favoriteButton(isFavorite: isFavorite, action: onToggle)
            }
        }
    }
}
