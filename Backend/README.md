# Match Point Backend

Guia de deploy gerenciado: [`DEPLOY.md`](DEPLOY.md). Container: `Dockerfile`.

Backend de dados e push do Match Point: recebe tokens APNs, ingere placares
continuamente, deduplica snapshots, guarda historico auditavel, enfileira
eventos e dispara push remoto server-side quando APNs esta configurado.

## Rodar localmente

```bash
cd Backend
npm start
```

Endpoint usado pelo app:

```text
POST http://localhost:8787/apns/device-token
```

Proxy REST usado pelo app em producao:

```text
GET https://seu-backend.com/tennis?method=get_livescore
```

Configure o app com:

```bash
MATCH_POINT_BACKEND_PROXY_URL="https://seu-backend.com/tennis"
MATCH_POINT_BACKEND_WEBSOCKET_URL="wss://seu-backend.com/live"
```

Configure o backend com a chave contratada do provider:

```bash
API_TENNIS_KEY="sua-chave-api-tennis"
```

O app nunca envia `APIkey` quando usa backend proxy. O servidor injeta a chave
na chamada upstream para `https://api.api-tennis.com/tennis/` e aceita apenas a
allowlist de metodos usados pelo app: `get_tournaments`, `get_standings`,
`get_livescore`, `get_events`, `get_fixtures`, `get_H2H`, `get_players`,
`get_odds`, `get_live_odds`.

### Producao: rate limit, cache, logs e fallback

O proxy `/tennis` ja aplica protecoes de producao:

- chave `API_TENNIS_KEY` somente no servidor;
- allowlist de metodos da API Tennis;
- rate limit dedicado por IP para chamadas ao provider;
- cache por endpoint para reduzir custo/quota;
- stale fallback quando API Tennis cai, expira ou retorna `429/5xx`;
- logs JSON sanitizados sem `APIkey`;
- endpoint de contrato em `GET /production/contract`;
- readiness em `GET /production/readiness` e `GET /health`.

Variaveis uteis:

```bash
API_TENNIS_KEY="sua-chave-api-tennis"
API_TENNIS_PROXY_RATE_LIMIT_WINDOW_MS=60000
API_TENNIS_PROXY_RATE_LIMIT_MAX=120
API_TENNIS_LIVE_CACHE_TTL_MS=5000
API_TENNIS_FIXTURE_CACHE_TTL_MS=300000
API_TENNIS_REFERENCE_CACHE_TTL_MS=3600000
API_TENNIS_STALE_FALLBACK_TTL_MS=900000
API_TENNIS_PROXY_TIMEOUT_MS=12000
```

## Autenticacao e recuperacao de senha

Endpoints de conta:

```text
POST /auth/apple
POST /auth/email/signup
POST /auth/email/login
POST /auth/email/recovery/request
POST /auth/email/recovery/reset
POST /auth/delete
```

Em producao, defina `DATABASE_URL` para persistir usuarios, sessoes e codigos
de recuperacao nas tabelas `auth_users`, `auth_sessions` e
`auth_recovery_codes`.

Para envio real de e-mail de recuperacao, configure Resend:

```bash
RESEND_API_KEY="re_xxxxxxxxx"
AUTH_EMAIL_FROM="Match Point <no-reply@seudominio.com>"
```

Sem essas variaveis, o backend usa `console mailer`: o codigo e gerado e
aparece nos logs do servidor, util apenas para desenvolvimento local. Antes de
subir para a App Store, use um dominio verificado no Resend e mantenha a chave
somente no ambiente do backend.

`POST /auth/delete` exige `Authorization: Bearer <session-token>`. Ele remove o
usuario em `auth_users`; no Postgres, `auth_sessions` e `auth_recovery_codes`
saem em cascata pelas foreign keys. Para contas criadas com Sign in with Apple,
configure tambem a revogacao server-side antes de subir para App Store:

```bash
APPLE_CLIENT_ID="seu.bundle.id"
APPLE_TEAM_ID="TEAMID1234"
APPLE_KEY_ID="KEYID1234"
APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
```

O app envia o `authorizationCode` da Conta Apple ao login. O backend troca esse
codigo diretamente com a Apple, deriva o usuario pelo `id_token` retornado e
guarda o `refresh_token` para revogar a conta quando ela e excluida. O
`appleUserID` enviado pelo app nao e usado como autoridade de identidade.

Para testes locais, voce pode desativar partes especificas:

```bash
API_TENNIS_PROXY_CACHE_DISABLED=true
API_TENNIS_PROXY_RATE_LIMIT_DISABLED=true
```

Payload aceito:

```json
{
  "action": "register",
  "reason": "apns-token-registered",
  "deviceToken": "hex-token",
  "platform": "ios",
  "bundleIdentifier": "ALTB.Match-Point",
  "environment": "sandbox",
  "registeredForRemoteNotifications": true,
  "subscription": {
    "favorites": {
      "players": [{ "id": "sinner", "name": "Jannik Sinner", "kind": "player" }],
      "matches": [],
      "tournaments": []
    }
  }
}
```

Use `action: "unregister"` para revogar opt-out. O servidor faz upsert por
`bundleIdentifier + environment + platform + deviceToken`, então a rotação do
token atualiza o cadastro em vez de criar estado ambíguo.

## Privacidade

As respostas nunca retornam o token completo, apenas os ultimos 8 caracteres.
O arquivo local `data/device-tokens.json` e apenas para desenvolvimento. Em
producao, defina `DATABASE_URL` para usar a tabela `device_registry`, com
subscriptions por token e resolucao server-side de destinatarios.

## Moderacao social

Endpoints:

```text
POST /social/moderation/report
POST /social/moderation/action
```

`/social/moderation/report` recebe denuncias de usuarios e salva auditoria.
Ele nao oculta posts automaticamente no cliente.

```json
{
  "postID": "post-id",
  "matchKey": "match-id",
  "reason": "user-report",
  "userRecordName": "icloud-user-record",
  "createdAt": "2026-06-06T20:00:00Z"
}
```

`/social/moderation/action` exige role administrativa no servidor:

```bash
MODERATION_ADMIN_TOKEN="troque-este-token" npm start
```

Envie o token como `Authorization: Bearer <token>`.

```json
{
  "postID": "post-id",
  "matchKey": "match-id",
  "action": "pin",
  "actorRecordName": "moderator-user-record",
  "createdAt": "2026-06-06T20:00:00Z"
}
```

Acoes aceitas: `pin`, `unpin`, `hide`, `unhide`.
O arquivo local `data/social-moderation.json` guarda reports, estado moderado
e trilha de auditoria. Em producao, substitua por banco/Cloud Functions com
roles reais e logs imutaveis.

## Apostas e saldo server-authoritative

O app registra apostas localmente para UX, mas ranking social e saldo de
producao devem ser decididos no servidor.

```text
POST /social/bets/register
POST /social/bets/settle
```

Registro de aposta:

```json
{
  "betID": "uuid",
  "userRecordName": "icloud-user-record",
  "matchKey": "match-id",
  "selection": "Carlos Alcaraz",
  "kind": "Vencedor da partida",
  "stake": 50,
  "payout": 90,
  "integrityHash": "sha256",
  "createdAt": "2026-06-06T20:00:00Z"
}
```

Settlement exige `Authorization: Bearer <MODERATION_ADMIN_TOKEN>`:

```json
{
  "betID": "uuid",
  "status": "won",
  "integrityHash": "sha256",
  "serverSettlementID": "settlement-id"
}
```

Status aceitos: `won`, `lost`, `void`. O servidor rejeita settlement se o
`integrityHash` nao bater com a aposta registrada e grava auditoria append-only.

## Ingestao ao vivo e push server-authoritative

O backend agora tem uma pipeline propria para partidas ao vivo — ingestao
continua, deduplicacao, historico auditavel e fila de push. O device do
usuario nao precisa mais ficar acordado para acompanhar uma partida: o proxy
do API Tennis alimenta o backend e ele decide o que virar push.

### Fluxo

```
proxy API Tennis  ->  POST /ingest/snapshot
                          |
                          v
              matchSnapshotStore  (dedup por hash)
                          |
                          v
              scoreHistoryStore   (append-only audit)
                          |
                          v
              pushDecisionEngine  (match_started, match_finished,
                                    break_point, tiebreak_started,
                                    set_completed, favorite_alert)
                          |
                          v
              pushEventQueue      (FIFO persistida)
                          |
                          v (worker drain)
              apnsDispatcher      (APNs real quando APNS_* existe; default = log)
```

Para ligar o ingester WebSocket always-on no processo do backend:

```bash
API_TENNIS_KEY="sua-chave-api-tennis" \
START_API_TENNIS_INGESTER=true \
npm start
```

`API_TENNIS_WS_URL` e opcional; quando omitido, o backend usa
`wss://wss.api-tennis.com/live` e injeta `API_TENNIS_KEY` na query.

### Endpoints

```text
GET  /production/readiness
GET  /health            (inclui readiness + ingestion.*)
GET  /tennis?method=…   (proxy REST API Tennis; chave fica no servidor)
GET  /rankings/live-projection?tour=ATP&tournament_key=…
POST /ingest/snapshot   Authorization: Bearer <MODERATION_ADMIN_TOKEN>
POST /ingest/drain      Authorization: Bearer <MODERATION_ADMIN_TOKEN>
GET  /matches/:key/score-history
GET  /push/queue        Authorization: Bearer <MODERATION_ADMIN_TOKEN>
```

## Ranking oficial e live projection

O app diferencia projeção local de projeção oficial. Para exibir frases como
`sobe de #5 para #3`, o backend precisa devolver um snapshot oficial com
ranking atual, live points, race rank, pontos defendidos e pontos ganhos no
torneio. Configure uma fonte oficial/contratada atras do proxy:

```bash
OFFICIAL_RANKING_PROJECTION_URL="https://provider.example.com/live-projection"
OFFICIAL_RANKING_API_KEY="sua-chave-ranking"
```

O endpoint `GET /rankings/live-projection` repassa apenas `tour`,
`tournament_key` e `player_key` para o provedor. A chave fica no servidor via
`Authorization: Bearer <OFFICIAL_RANKING_API_KEY>`.

### Payload de ingestao

```json
{
  "source": "api-tennis-ws",
  "snapshot": {
    "matchKey": "atp-2026-042",
    "tournamentKey": "atp-1000-monte-carlo-2026",
    "player1": "Carlos Alcaraz",
    "player2": "Jannik Sinner",
    "player1Key": "carlos-alcaraz",
    "player2Key": "jannik-sinner",
    "status": "live",
    "serverName": "Alcaraz",
    "score": "6-4, 3-2",
    "gameScore": "40-30",
    "pointScore": "40-30",
    "setNumber": 2,
    "breakPoint": true,
    "capturedAt": "2026-04-12T18:20:31Z"
  }
}
```

Resposta:

```json
{
  "ok": true,
  "result": {
    "changed": true,
    "matchKey": "atp-2026-042",
    "revision": 7,
    "events": [
      { "kind": "break_point", "priority": "high", "recipients": 3 },
      { "kind": "favorite_alert", "priority": "high", "recipients": 1 }
    ]
  }
}
```

Quando o frame e byte-equivalente ao ultimo, `changed=false` e nada mais
acontece (dedup server-side).

### Persistencia

- `data/match-snapshots.json` — estado corrente por matchKey.
- `data/score-history.json`   — trilha imutavel de mudancas de placar.
- `data/push-queue.json`      — fila (`pending` / `sent` / `dead`).

Em producao, substituir por banco relacional (Postgres) + Redis Streams para
a fila. As interfaces `MatchSnapshotStore`/`ScoreHistoryStore`/`PushEventQueue`
sao proposital enxutas para permitir a troca sem tocar no ingest ou no engine.

### Dispatcher de push

O `LiveIngestionService` recebe um `dispatcher(event) -> { ok, receipt? }`.
Quando `APNS_KEY_PATH`, `APNS_KEY_ID` e `APNS_TEAM_ID` estao configurados, o
servidor usa `ApnsDispatcher` via HTTP/2 com token JWT `.p8`. Sem essas env
vars, cai para `noopDispatcher` (log em stdout) para desenvolvimento local. A
fila retenta ate 3 vezes antes de mover para `dead`.

As subscriptions chegam junto do `POST /apns/device-token` enviado pelo app.
O backend transforma favoritos em seletores:

- `favorites.matches[].id` -> `{ type: "match", matchKey }`
- `favorites.tournaments[].id` -> `{ type: "tournament", tournamentKey }`
- `favorites.players[].id` -> `{ type: "favorite-player", playerKey }`

Durante o drain, esses seletores sao resolvidos contra tokens ativos; tokens
revogados ou invalidados pelo APNs deixam de receber eventos futuros.

### Persistencia de producao

Defina `DATABASE_URL` para ativar Postgres em snapshots, score history e
device registry. Defina `REDIS_URL` para ativar Redis Streams na fila de push.
Sem essas variaveis o backend usa arquivos JSON locais para desenvolvimento.

## Rate limit e CORS

Todos os endpoints (exceto `/health`) sao limitados por IP usando uma janela
deslizante. Configure via env vars:

```bash
RATE_LIMIT_WINDOW_MS=60000   # tamanho da janela em ms (default: 60s)
RATE_LIMIT_MAX=60            # requisicoes permitidas por janela (default: 60)
```

Quando o limite e atingido o servidor responde `429 Too many requests` com o
header `Retry-After` em segundos.

CORS e desligado por padrao (nenhuma origem cross-site liberada). Para
liberar uma ferramenta de debug web, defina origens permitidas separadas por
virgula:

```bash
ALLOWED_ORIGINS="https://admin.matchpoint.example,https://dev.matchpoint.example"
```

Apenas as origens listadas recebem `Access-Control-Allow-Origin`. O cliente
iOS nao trafega CORS, entao o app continua funcionando sem essa variavel.

Atras de proxy/CDN, terminar `X-Forwarded-For` na borda e garantir que apenas
um hop confiavel preenche o header — o servidor le o primeiro valor da lista
para identificar o IP do cliente.
