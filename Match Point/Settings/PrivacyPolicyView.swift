//
//  PrivacyPolicyView.swift
//  Match Point
//
//  In-app reference of the privacy commitments declared in PrivacyInfo.xcprivacy.
//  Keep wording aligned with the manifest so App Store review and the user see
//  the same story.
//

import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                section(
                    title: String(localized: "Resumo"),
                    body: String(localized: "Match Point coleta apenas o necessário para funcionar: conta, perfil, favoritos, previsões, avaliações de partidas, enquetes e alertas. Esses dados não são usados para rastreamento entre apps ou empresas.")
                )

                section(
                    title: String(localized: "Dados que coletamos"),
                    bullets: [
                        String(localized: "Nome de exibição e nome de perfil, quando você cria ou edita a conta (NSPrivacyCollectedDataTypeName)."),
                        String(localized: "E-mail usado para criar conta, entrar ou recuperar acesso (NSPrivacyCollectedDataTypeEmailAddress)."),
                        String(localized: "Identificador de usuário, username ou identidade da Conta Apple usados para manter sua sessão e perfil (NSPrivacyCollectedDataTypeUserID)."),
                        String(localized: "Avaliações de partidas, enquetes e conteúdo criado por você (NSPrivacyCollectedDataTypeOtherUserContent)."),
                        String(localized: "Token de notificação remota/APNs para entrega de alertas (NSPrivacyCollectedDataTypeDeviceID), sempre protegido em trânsito."),
                        String(localized: "Interações com o app: favoritos, previsões, pontuação e ranking (NSPrivacyCollectedDataTypeProductInteraction).")
                    ]
                )

                section(
                    title: String(localized: "Dados que NÃO coletamos"),
                    bullets: [
                        String(localized: "Identificadores de rastreamento (IDFA, IDFV)."),
                        String(localized: "Localização precisa ou aproximada."),
                        String(localized: "Contatos, fotos, microfone ou câmera."),
                        String(localized: "Pagamentos, cartão de crédito ou informações financeiras.")
                    ]
                )

                section(
                    title: String(localized: "Onde os dados ficam"),
                    bullets: [
                        String(localized: "Dados locais ficam no SwiftData, dentro do sandbox do app."),
                        String(localized: "Dados de conta, recuperação, avaliações e ranking sincronizam com os serviços de produção do Match Point quando você usa recursos online."),
                        String(localized: "Token APNs é usado apenas para entregar alertas que você ativou."),
                        String(localized: "A senha não é salva em texto puro pelo app; a autenticação usa credenciais protegidas e códigos de recuperação.")
                    ]
                )

                section(
                    title: Self.privacyRightsTitle(),
                    bullets: [
                        String(localized: "Exportar seus dados a qualquer momento em Configurações."),
                        String(localized: "Excluir todos os seus dados locais com um toque em Configurações."),
                        String(localized: "Pedir esclarecimentos sobre uso dos dados via e-mail de suporte: suporte@matchpoint.app.")
                    ]
                )

                Text(String(format: String(localized: "Última atualização: %@"), Self.lastUpdated))
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
            }
            .padding(22)
        }
        .navigationTitle(String(localized: "Política de Privacidade"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .accessibilityIdentifier("privacy-policy-screen")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Privacidade"))
                .font(.largeTitle.weight(.bold))
            Text(String(localized: "Como o Match Point trata seus dados."))
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.primary)
        }
    }

    private func section(title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(bullets, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Color.readableSecondary)
                    Text(item).font(.callout)
                }
            }
        }
    }

    private static let lastUpdated = "2026-10-04"

    private static func privacyRightsTitle(locale: Locale = .current) -> String {
        guard let regionCode = locale.region?.identifier.uppercased() else {
            return String(localized: "Seus direitos de privacidade")
        }

        if gdprRegionCodes.contains(regionCode) {
            return String(localized: "Seus direitos (GDPR)")
        }
        if regionCode == "GB" {
            return String(localized: "Seus direitos (UK GDPR)")
        }
        if regionCode == "BR" {
            return String(localized: "Seus direitos (LGPD)")
        }
        return String(localized: "Seus direitos de privacidade")
    }

    private static let gdprRegionCodes: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR",
        "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK",
        "SI", "ES", "SE", "IS", "LI", "NO"
    ]
}

#Preview {
    NavigationStack { PrivacyPolicyView() }
}
