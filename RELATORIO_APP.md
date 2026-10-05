# Relatorio tecnico do Match Point

Data da revisao: 2026-06-05

## Correcoes feitas nesta revisao

- Adicionados initializers explicitos em `OnboardingView`, `ProfileView`, `SocialFeedView` e `LiveTrackerView` para evitar erro de inicializacao em previews quando as views possuem propriedades `@Query` privadas.
- Ajustada a assinatura do delegate CarPlay para o SDK atual: `templateApplicationScene(_:didConnect:to:)` e `templateApplicationScene(_:didDisconnect:from:)`.
- Mantida a estrutura de widgets fixos com `StaticConfiguration` e `TimelineProvider`.
- Mantida a estrutura de Live Activity para tela bloqueada e Dynamic Island.

## Status de build

O build filtrado nao mostrou novos erros Swift nas views corrigidas.

O erro restante observado neste ambiente e de infraestrutura do Xcode/Simulator:

```text
Assets.xcassets: error: No available simulator runtimes for platform iphonesimulator.
SimServiceContext supportedRuntimes=[]
```

Isso indica problema local de CoreSimulator/runtime iOS, nao uma falha direta do codigo do app.

## O que o app ja faz hoje

### Experiencia principal

- Possui fluxo de onboarding.
- Permite escolher jogadores favoritos.
- Mostra feed "For You" com partidas ao vivo, urgentes, favoritas e recomendadas.
- Possui abas para partidas, torneios, rankings, favoritos, jogadores, alertas, provider/API e perfil.

### Live Tracker

- Gera cards grandes para partidas ao vivo de jogadores favoritos.
- Mostra placar, status, set/game atual, saque, ponto atual e contexto.
- Alterna entre mais de uma partida ativa.
- Usa `LiveTrackerBuilder` e `MatchIntelligence` para priorizar partidas e gerar narrativa.
- Tem estrutura para estados vazios, loading/sync e erro de provider.

### Tela bloqueada, Dynamic Island e widgets

- Live Activity configurada com `ActivityKit`.
- `NSSupportsLiveActivities` e `NSSupportsLiveActivitiesFrequentUpdates` estao no `MatchPointInfo.plist`.
- A extensao `MatchPointLiveActivityExtension` possui:
  - Live Activity / Dynamic Island.
  - Widget fixo para Home Screen / Lock Screen com `StaticConfiguration`.
  - `TimelineProvider` lendo snapshots compartilhados.
- App Group configurado para compartilhar snapshots entre app e extensao.

### Favoritos

- Jogadores, partidas e torneios podem ser marcados como favoritos.
- Favoritos alimentam Live Tracker, feed personalizado, alertas e widgets.

### Dados e APIs

- Estrutura multi-provider em `TennisAPI`.
- Provider direto API Tennis com REST e WebSocket.
- Providers RapidAPI com parser heuristico para Flashscore, Sofascore, LiveScore e Tennis ATP/WTA/ITF.
- Tela de diagnostico para configurar provider, API key e endpoints.

### Social / Match Point

- Feed social por partida.
- Comentarios locais e via CloudKit.
- Polls/enquetes locais e via CloudKit.
- Likes, replies, fixar comentarios, denuncias e auto-hide.
- Dashboard de moderacao.

### Gamificacao

- Sistema de previsoes com pontos.
- Tipos de previsao incluem vencedor da partida, set, placar, performance, tie-break, total de sets, confirma saque, quebra primeiro e proximo game.
- Liquidacao local por `BetSettlementEngine`.
- Ranking social semanal, mensal, geral e por categorias.
- Badges/conquistas e historico de previsoes no perfil.

### Perfil

- Perfil editavel com nome e avatar.
- Pontuacao total.
- Ranking.
- Historico de previsoes.
- Jogadores favoritos.
- Conquistas.
- Perfil publico.
- Estado de conta iCloud/CloudKit.

### Torneios

- Central de torneios.
- Favoritos vivos/eliminados.
- Jogos imperdiveis.
- Upsets.
- Bracket/visao de torneio inicial.
- Tratamento especial para Grand Slams/Masters.

### CarPlay

- Scene CarPlay configurada no `MatchPointInfo.plist`.
- Delegate CarPlay implementado.
- Lista partidas ao vivo/favoritas e detalhe do jogo.
- Ainda exige entitlement/aprovacao real da Apple para producao.

## Por que o Xcode pede Apple Development Team

O projeto usa recursos que exigem assinatura com uma equipe Apple:

- iCloud + CloudKit.
- App Groups.
- Widget extension.
- Live Activities.
- Possivel CarPlay.
- Provisioning profile para app e extensao.

O projeto esta com signing automatico:

```text
CODE_SIGN_STYLE = Automatic
```

E tambem possui um time configurado:

```text
DEVELOPMENT_TEAM = X4LVNLD477
```

Se esse Team ID nao pertence a conta Apple logada no Xcode, o Xcode vai pedir para selecionar uma equipe valida.

## Como resolver o Apple Development Team no Xcode

1. Abrir `Match Point.xcodeproj`.
2. Selecionar o projeto `Match Point`.
3. Abrir o target `Match Point`.
4. Ir em `Signing & Capabilities`.
5. Marcar `Automatically manage signing`.
6. Em `Team`, escolher sua conta Apple.
7. Repetir para o target `MatchPointLiveActivityExtension`.
8. Conferir se os Bundle IDs continuam unicos:
   - App: `ALTB.Match-Point`
   - Extension: `ALTB.Match-Point.MatchPointLiveActivity`
9. No Apple Developer, ativar/criar:
   - `iCloud.ALTB.Match-Point`
   - `group.ALTB.Match-Point`
   - capability iCloud + CloudKit
   - capability App Groups

Para desenvolvimento sem CloudKit/App Groups em simulador, e possivel remover temporariamente capabilities, mas isso desativa partes importantes do app.

## Como usar a API key real sem colocar segredo no GitHub

Opcao recomendada no Xcode:

1. Abra `Product > Scheme > Edit Scheme`.
2. Entre em `Run > Arguments`.
3. Em `Environment Variables`, adicione:
   - Nome: `MATCH_POINT_API_TENNIS_KEY`
   - Valor: sua chave da API Tennis
4. Rode o app.
5. A aba Provider tambem pode salvar a chave localmente em `UserDefaults`.

O codigo tambem aceita `API_TENNIS_KEY` como fallback.

## Pendencias reais

- Validar o app em Xcode com runtime iOS instalado e funcionando.
- Ativar App Group e CloudKit no Apple Developer.
- Promover schema CloudKit para producao.
- Validar ranking/social multiusuario com contas iCloud diferentes.
- Contratar/configurar API real de tenis para dados ponto a ponto.
- Validar entitlement e regras de CarPlay com a Apple.
- Fazer QA visual em aparelho real.
