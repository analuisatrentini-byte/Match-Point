# Deploy do backend

O backend está pronto para rodar como container em um serviço Node persistente
(por exemplo, Railway, Render ou Fly.io). A plataforma deve terminar TLS e
encaminhar HTTP e WebSocket para a porta informada em `PORT`.

## 1. Criar o serviço

Configure a raiz do serviço como `Backend`, use `Backend/Dockerfile` e mantenha
uma única instância enquanto o ingester WebSocket estiver habilitado. A imagem
já instala dependências de produção e inicia `npm start`.

Configure a verificação de saúde como `GET /health`. A aplicação escuta em
`0.0.0.0` na porta `PORT` (padrão `8787`). Não configure um disco efêmero como
persistência: os dados duráveis devem ir para Postgres.

## 2. Variáveis e secrets

Obrigatórias para servir dados de tênis:

```text
NODE_ENV=production
API_TENNIS_KEY=<chave contratada do API Tennis>
DATABASE_URL=<URL de conexão pooled do Neon/Postgres>
START_API_TENNIS_INGESTER=true
```

Use a conexão pooled do banco e habilite SSL conforme a URL fornecida pelo Neon.
Após configurar `DATABASE_URL`, execute uma vez, a partir do serviço ou de um
ambiente seguro com a mesma variável:

```bash
npm run migrate
```

O backend atual não precisa de Redis para servir o proxy ou persistir usuários,
snapshots, histórico e tokens; sem `REDIS_URL`, a fila de push é local ao
processo e serve apenas para desenvolvimento. Não habilite múltiplas instâncias
nem conte com entrega resiliente de push até configurar Redis Streams.

Também recomendado antes de expor o serviço:

```text
MODERATION_ADMIN_TOKEN=<segredo aleatório longo>
```

Configure Resend (`RESEND_API_KEY`, `AUTH_EMAIL_FROM`) quando recuperação de
senha por e-mail estiver disponível para usuários. Apple server-side e APNs
podem ser adicionados depois, usando os secrets documentados no README.

## 3. Configurar o app

Depois que a plataforma entregar o domínio HTTPS, configure no serviço de
diagnóstico do app:

```text
MATCH_POINT_BACKEND_PROXY_URL=https://<dominio-real>/tennis
MATCH_POINT_BACKEND_WEBSOCKET_URL=wss://<dominio-real>/live
```

Esses são os formatos esperados pelo app; a configuração é gravada no Keychain.
O endpoint `/live` precisa encaminhar a conexão WebSocket ao backend e preservar
o caminho e a query string. O servidor também disponibiliza o upstream seguro
em `GET /production/contract`.

## 4. Validar

Abra os endpoints abaixo no domínio HTTPS do serviço:

```text
GET https://<dominio-real>/health
GET https://<dominio-real>/production/readiness
GET https://<dominio-real>/production/contract
```

`/health` deve responder `200` com `ok: true`; readiness deve indicar
`apiTennis.apiKeyConfigured`, `restProxyConfigured` e
`websocketConfigured` como `true`, além de `ingesterEnabled: true`. Faça então
uma sincronização de torneios/partidas no app e confirme que o contrato do
proxy recebe as chamadas sem chave do provider no cliente.

## Bloqueios externos

O repositório não contém um domínio de produção, vínculo com serviço de
hospedagem, nem a chave do API Tennis. O comando `neon me` também não conseguiu
alcançar a API Neon neste ambiente. Portanto, a criação do serviço e a aplicação
da migration precisam acontecer na conta de hospedagem/banco; não publique
segredos no repositório. Após o primeiro deploy, substitua os dois placeholders
pelas URLs reais do serviço no app.

## Live Activity na tela bloqueada

A entrega remota exige o schema atualizado no Postgres e uma instância contínua
com `START_API_TENNIS_INGESTER=true`. Além de `API_TENNIS_KEY` e `DATABASE_URL`,
configure `APNS_KEY_PATH` (arquivo .p8 montado com segurança), `APNS_KEY_ID`,
`APNS_TEAM_ID` e `APNS_BUNDLE_ID` (o identificador exato do app, sem o sufixo
`.push-type.liveactivity`). O servidor usa sandbox ou produção conforme o token
registrado pelo app. Sem essas configurações, o registro retorna HTTP 503 ou
400 e nenhuma atualização remota é enviada.

Teste a migração e o envio APNs em ambiente isolado antes de aplicar o schema
em produção. Com inscrições ativas, a reconciliação começa na inicialização e
consulta a fonte a cada 30 segundos. Recupera placares e busca fixtures para
partidas ausentes do feed ao vivo. Só um resultado final explícito encerra a
atividade; ausência ou falha do provedor não implica encerramento. Um final
confirmado fica persistido até o APNs aceitar o encerramento, inclusive após
reiniciar o servidor. O resultado final permanece visível por 30 segundos.

O WebSocket possui prazo de conexão, ping/pong e recuperação de stream
silencioso. O envio APNs tem prazo de 10 segundos e repete falhas transitórias
automaticamente, mantendo o estado mais recente em vez de uma fila de pontos
antigos. Alterações de placar usam prioridade 10; repetições são deduplicadas e
heartbeats usam prioridade 5. A validade dos dados expira após 90 segundos
sem aquisição recente, preservando o último placar com indicação de espera.

Verifique em `/health`: `uptimeSeconds`, `apiTennisIngester.connected`,
`lastFrameAt`, `watchdogReconnects`, `liveActivities.pushesSent`, `pushesFailed`,
`retryingMatches` e `liveActivityReconciliation.lastSuccessAt`. As flags de
readiness confirmam configuração, não comprovam entrega em um dispositivo.
Uma instância que suspende por inatividade não oferece acompanhamento contínuo.
A entrega depende do APNs e da disponibilidade do provedor e deve ser validada
em um iPhone real, com o app em segundo plano, até o encerramento da partida.
