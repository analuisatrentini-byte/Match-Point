import SwiftUI

// Container que hospeda Torneios + Jogadores numa única aba (rotulada
// "Torneios" no tab bar, por ser o vocabulário que fãs casuais reconhecem).
// O segmented picker no topo é o único controle de navegação entre as duas
// telas; cada view interna mantém seu próprio `.navigationTitle`, `.toolbar`
// e `.appleSportsBackground`, então funcionam idêntico quando acessadas
// direto (deep links, previews, etc.). O nome do struct continua `Circuit`
// só por inércia histórica — refletir o rename completo exigiria editar
// usos em ContentView/Preview etc.

struct CircuitView: View {
    enum Section: String, CaseIterable, Identifiable {
        case tours = "Torneios"
        case players = "Rankings"

        var id: String { rawValue }
    }

    @State private var section: Section = .tours

    var body: some View {
        Group {
            switch section {
            case .tours:
                ToursView()
            case .players:
                PlayersView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Antes era `.background(.ultraThinMaterial)`, que somava uma
            // SEGUNDA faixa fosca logo abaixo da nav bar (a primeira foi
            // removida em `AppleSportsAppearance` — esta era a segunda
            // camada de blur). Agora deixamos transparente: o picker fica
            // direto sobre o gradient royal/clay, sem corte visual.
            Picker("Seção", selection: $section) {
                ForEach(Section.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("circuit-section-picker")
        }
    }
}
