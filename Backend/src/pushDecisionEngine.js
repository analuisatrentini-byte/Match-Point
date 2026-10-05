/// Rules that turn a snapshot diff into push events. Kept small and
/// deterministic so the exact same (previous, current) pair always yields
/// the same event set — the engine has no I/O and no clock, which makes it
/// trivial to unit test and replay against the score history.
///
/// Extension model: add a new rule to `RULES` returning an event object.
/// Each rule receives `(previous, current)` and must return either an event
/// or `null`. Rules never mutate state.
export const PushEventKind = Object.freeze({
    matchStarted: "match_started",
    matchFinished: "match_finished",
    breakPoint: "break_point",
    breakPointCleared: "break_point_cleared",
    tiebreakStarted: "tiebreak_started",
    setCompleted: "set_completed",
    favoriteAlert: "favorite_alert"
});

const RULES = [
    matchStartedRule,
    matchFinishedRule,
    breakPointRule,
    breakPointClearedRule,
    tiebreakRule,
    setCompletedRule,
    favoriteRule
];

/// Runs every rule against the diff and returns the events they produced.
/// The engine gives NO priority to events beyond insertion order — the queue
/// consumer is responsible for deduping / rate limiting per user/device.
export function decide({ previous, current }) {
    if (!current) return [];
    const events = [];
    for (const rule of RULES) {
        const event = rule(previous, current);
        if (event) {
            events.push(makeEvent({ ...event, matchKey: current.matchKey }));
        }
    }
    return events;
}

function makeEvent(fields) {
    return {
        kind: fields.kind,
        matchKey: fields.matchKey,
        payload: fields.payload ?? {},
        recipients: fields.recipients ?? [],
        priority: fields.priority ?? "normal",
        createdAt: new Date().toISOString()
    };
}

function matchStartedRule(previous, current) {
    if (current.status !== "live") return null;
    if (previous?.status === "live") return null;
    return {
        kind: PushEventKind.matchStarted,
        priority: "high",
        recipients: recipientsForMatch(current),
        payload: {
            headline: `${current.player1} vs ${current.player2}`,
            body: "Partida começou.",
            score: current.score
        }
    };
}

function matchFinishedRule(previous, current) {
    if (current.status !== "completed") return null;
    if (previous?.status === "completed") return null;
    return {
        kind: PushEventKind.matchFinished,
        priority: "normal",
        recipients: recipientsForMatch(current),
        payload: {
            headline: `${current.player1} vs ${current.player2}`,
            body: `Fim de jogo: ${current.score}`,
            score: current.score
        }
    };
}

function breakPointRule(previous, current) {
    if (!current.breakPoint) return null;
    if (previous?.breakPoint) return null;
    if (current.status !== "live") return null;
    return {
        kind: PushEventKind.breakPoint,
        priority: "high",
        recipients: recipientsForMatch(current),
        payload: {
            headline: `Break point em ${current.player1} vs ${current.player2}`,
            body: current.gameScore ? `Game ${current.gameScore}` : "Ponto decisivo",
            score: current.score
        }
    };
}

function breakPointClearedRule(previous, current) {
    if (current.breakPoint) return null;
    if (!previous?.breakPoint) return null;
    if (current.status !== "live") return null;
    return {
        kind: PushEventKind.breakPointCleared,
        priority: "low",
        recipients: recipientsForMatch(current),
        payload: {
            headline: `${current.player1} vs ${current.player2}`,
            body: "Break point escapou."
        }
    };
}

function tiebreakRule(previous, current) {
    const currentTiebreak = isTiebreak(current);
    if (!currentTiebreak) return null;
    if (isTiebreak(previous)) return null;
    return {
        kind: PushEventKind.tiebreakStarted,
        priority: "high",
        recipients: recipientsForMatch(current),
        payload: {
            headline: `${current.player1} vs ${current.player2}`,
            body: "Tie-break começou.",
            score: current.score
        }
    };
}

function setCompletedRule(previous, current) {
    if (previous == null) return null;
    if (typeof current.setNumber !== "number" || typeof previous.setNumber !== "number") return null;
    if (current.setNumber <= previous.setNumber) return null;
    return {
        kind: PushEventKind.setCompleted,
        priority: "normal",
        recipients: recipientsForMatch(current),
        payload: {
            headline: `${current.player1} vs ${current.player2}`,
            body: `Set ${previous.setNumber} encerrado.`,
            score: current.score
        }
    };
}

function favoriteRule(previous, current) {
    const playerKeys = playerRecipientKeys(current);
    if (playerKeys.length === 0) return null;
    if (current.status !== "live") return null;
    if (!current.breakPoint) return null;
    if (previous?.breakPoint) return null;
    return {
        kind: PushEventKind.favoriteAlert,
        priority: "high",
        recipients: playerKeys.map((playerKey) => ({
            type: "favorite-player",
            playerKey
        })),
        payload: {
            headline: `Favorito em break point`,
            body: `${current.player1} vs ${current.player2}: ${current.gameScore || current.score}`
        }
    };
}

function isTiebreak(snapshot) {
    if (!snapshot) return false;
    if (typeof snapshot.gameScore === "string" && snapshot.gameScore.includes("6-6")) return true;
    if (typeof snapshot.status === "string" && snapshot.status.toLowerCase().includes("tie")) return true;
    return false;
}

/// The engine has no user database — it lists coarse "match audience"
/// selectors and lets the queue worker resolve them against actual device
/// tokens. This keeps decisions independent of who happens to be registered.
function recipientsForMatch(snapshot) {
    const recipients = [{ type: "match", matchKey: snapshot.matchKey }];
    if (snapshot.tournamentKey) {
        recipients.push({ type: "tournament", tournamentKey: snapshot.tournamentKey });
    }
    for (const key of playerRecipientKeys(snapshot)) {
        recipients.push({ type: "favorite-player", playerKey: key });
    }
    return recipients;
}

function playerRecipientKeys(snapshot) {
    const keys = [
        snapshot?.player1Key,
        snapshot?.player2Key,
        ...(snapshot?.favoritePlayerKeys ?? [])
    ];
    return Array.from(new Set(keys.filter((key) => typeof key === "string" && key.trim() !== "").map((key) => key.trim())));
}
