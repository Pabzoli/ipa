# House social decision matrix

Bots are premium humans. Every branch is server-side, best-effort, idempotent.
One bot's failure never blocks the others or the WP pacing tick.

Tick order per bot (`_houseSocialCore`, every 15 min):
`bankroll → friendCode → unlock → incoming friends → prune → outgoing friend request (+house-edge) → invites (join/decline) → pending plays (submit) → nudge → outgoing challenge`.
Budget `maxSocialActionsPerDay` (default 12) is shared across stages; `0` left stops later stages.
Outside prime WAT windows `[[8,10],[13,15],[19,22]]` only pending plays run (60% of ticks skip even that), except `offWindowTickRate` (default 10%) of ticks run the full pipeline so off-hours activity isn't zero.
Per-bot desync: 30% of ticks skip the bot entirely so bots never act together.
Podium WP pacing (`_houseTickCore`): H3 tracks real #4 in `[gapMin,gapMax]` (default `30-200`), per-bot `±110` weekly offset + weekly walk `±150` + daily jitter; want blends 65% self-grind / 35% band, clamped to the floor so the house still wins; slump sit-out only when cushioned `>=220`. Weekly goals `1600-2600`; upset day 1x/week sits the leader so reals can overtake. Chunks `20-500` (snipe cap 250). Chasers run independent goals `300-1500`, ceiling `housesMin-60`. Names rotate staggered `1-2/day` from a `340+` pool. Scoring writes `matches` history with `~65%` wins, tilt/dominant tails, solo+QM mix, anime from own unlocks.
Stealth: visible ledger/match timestamps backdate `0-14m` in-tick (`_houseVisibleAtMs`); ledger sources use real shapes (`quiz_run`/`earn_bonus`/`spend_unlock`, no `house_*`); bankroll targets `8-12k` varied; outgoing stakes include ~8% high takes (`2000-5000AC/200-400WP`); accept/win/floor rates vary per bot `±10`; refusals rematch in ~8h 1-in-5; `accountPool`/`chaserPool` rotate the active weekly set; chasers socialize at ~40% rate; rare house-house edges (~3%/tick).

## 1. Incoming friends (`_houseProcessFriends`)

| # | Condition | Outcome |
|---|---|---|
| F1 | `ageH < minRespondHours` | skip (too fresh, human delay) |
| F2 | `ageH < maxRespondHours` + `jitter<45` | skip (not glued to inbox) |
| F3 | roll >= `friendAcceptRate` | decline: pair → `declined`, delete both links |
| F4 | `pair.status == blocked` | skip, warn (no oracle leak) |
| F5 | `pair.status != pending` or `requestedBy == hid` | skip/throw, clean stray link |
| F6 | peer missing / `friendCount >= 50` either side | skip, warn (no write) |
| F7 | else accept | `_activateFriendshipTx`: pair `active`, both links `friend`, `friendCount++` both |
| F8 | every accept/decline | `_houseBumpSocial`, log |

Deterministic test config: `minRespondHours:0, maxRespondHours:0`, `friendAcceptRate:100` (always accept) or `0` (always decline).

## 2. Prune (`_housePruneFriends`)

| # | Condition | Outcome |
|---|---|---|
| P1 | outgoing link `ageMs < 7d` | keep |
| P2 | outgoing link `ageMs >= 7d` + `jitter<50` skip, else | cancel: delete pair + both links (budget NOT refunded, matches human spec) |
| P3 | `friendCount < FRIEND_MAX-5` | no eviction |
| P4 | near cap + `jitter<30` | evict least-recently-played friend (max 8 match reads): delete pair + links, `friendCount--` both |
| P5 | pair not `active` at commit | abort (race-safe) |

## 3. Outgoing friend requests (`_houseMaybeOutgoingFriendRequest`)

| # | Condition | Outcome |
|---|---|---|
| O1 | `!outgoingEnabled` / budget 0 | `0` |
| O2 | `lastOutgoingFriendAt` within 3d + `jitter<90` | `0` (~1-2/week/bot) |
| O3 | `jitter>=15` | `0` |
| O4 | own `friendCount>=50` / outgoing today `>=10` | `0` |
| O5 | no recent `matches` opponents | `0` (only people they played) |
| O6 | peer is ghost/admin/self/house | skip candidate |
| O7 | pair `blocked/active/pending` | skip (blocked = silent, no oracle) |
| O8 | pair `declined` by hid within 7d | skip (decline cooldown) |
| O9 | peer `friendCount>=50` / peer inbox `>=20` | skip |
| O10 | else | create pair `pending requestedBy=hid` + `outgoing/incoming` links, `outgoingReqCount++`, push `friend_request` best-effort, stamp `lastOutgoingFriendAt`, bump |

## 4. Invites (`_houseProcessInvites`)

Reads `challenges where opponentUid==hid` (25) + `where creatorUid==hid` (25), filters joinable in code (no composite index).

| # | Condition | Outcome |
|---|---|---|
| I1 | `resolved` or `completed/declined/expired/expired_refunded` | drop from `pendingPlays`; if we were creator and it was refused → `_houseNoteRefusal(peer, 48h)` |
| I2 | not a participant / no action needed | skip |
| I3 | `needsJoin` + `ageH<minH` + `jitter<70` | skip (let invite breathe) |
| I4 | spar? `sparAcceptRate` : high-stake? `highStakeAcceptRate` : `duelAcceptRate`; roll>=rate | invitee declines via `_houseDeclineTx` (creator refunded), `_houseNoteRefusal(creator,24h)`; creators just wait |
| I5 | join throws blocked/not_friends/wp_cap/wp_cooldown/insufficient/too_many/daily/budget | gate-decline (refund creator) + bump |
| I6 | other join error | warn, leave for sweeps |
| I7 | join ok | `_houseJoinTx`, schedule `pendingPlays[cid]=now+30m..5.5h`, bump |
| I8 | `needsPlay` only | stamp `pendingPlays[cid]` if missing (submit happens in stage 5) |

`_houseJoinTx` gates (premium path mirror): joinable status, seat free, invited, not own, spar zero-stake, spar requires friendship / staked blocks on `blocked`, active cap 5, spar 15/day else join 8/day, AC shape+balance, WP shape+`WP_DAILY_CAP_PREMIUM 500`+balance, rival 6h cooldown unless active series, deduct + touch `rivalCooldowns`, extend expiry to 24h.
`_houseDeclineTx`: invitee only + joinable; set `declined`, refund creator AC+WP with ledger entries.

## 5. Pending plays (`_houseProcessPendingPlays`)

| # | Condition | Outcome |
|---|---|---|
| S1 | `now-lastPlayAt < minPlayIntervalMins` (default 6, solo floor) | `0`, whole stage defers |
| S2 | `pendingPlays[cid] > now` | skip (not due) |
| S3 | doc gone | drop entry |
| S4 | `resolved` / score set / terminal status | drop entry |
| S5 | opponent seat with no `joinedAt` | drop entry |
| S6 | else | `wantWin = jitter<winRate` (default 60) with streak breaker (`winStreak>=4` forces loss, `lossStreak>=3` forces win); `_houseSubmitTx`; set `lastPlayAt=now`, `winStreak/lossStreak`, drop entry, bump; **return after 1 play** (one scored play per tick per bot) |
| S7 | submit race (`already_played`) | drop entry, warn |

`_houseSubmitTx`: participant + seat free + `joinedAt` for opponent + 10 qids; fetch `correctAnswerIndex`, `target=_houseTargetScore(oppScore, wantWin)` (blind 7-9 win / 4-6 loss; vs opp: win `opp+1..`, loss under, cap 0-10); uniform miss slots, wrong=`(correct+1+jitter)%4`; tx writes score field only if still free.

## 6. Nudge (`_houseMaybeNudge`)

| # | Condition | Outcome |
|---|---|---|
| N1 | budget 0 / `jitter>=25` | `0` |
| N2 | no `theirTurn` peers (via `_duelTurnsFor` + `_theirTurnOnChallenge`) | `0` |
| N3 | pair not `active` | `0` |
| N4 | already nudged today (`lastNudgeAt.sender_receiver` WAT) | `0` |
| N5 | no their-turn duel found | `0` |
| N6 | reserve stamp, push fails (no token/outage) | rollback stamp, `0` (don't burn budget) |
| N7 | push ok | bump, log (1/day/pair, server template only) |

## 7. Outgoing challenges (`_houseMaybeOutgoing`)

| # | Condition | Outcome |
|---|---|---|
| C1 | `!outgoingEnabled` / budget 0 / `jitter>=12` | `0` |
| C2 | no friends | `0` |
| C3 | peer backed off / WP cooldown (unless active series) | try next friend (shuffled 20); none valid → `0` |
| C4 | spar budget / create budget hit | `0` (spar 15/d, staked 8/d premium) |
| C5 | `<10` questions for anime / insufficient balance | `0` |
| C6 | else | 75% spar (0/0) / 25% low duel (20-500 AC, 5-100 WP); deduct, write `waiting` rival/spar vs friend, 12h expiry, schedule creator play 30m-2h, bump |

Never hangs: a refuser gets `peerBackoff` 48h (24h if we declined them); the picker shuffles and tries the next friend. Stale series expire via `expireStaleRivalries` (14d); bots keep playing others meanwhile.

## 8. Money/cooldown invariants (never violated)

Active 5 · join 8/d · create 8/d · spar 15/d · WP cap 500/d · rival 6h (series excepted) · solo 6m floor · friend 50 / out 10/d / in 20 / 7d re-request · invite 12h / in-play 24h · forfeit 15m · AC `20..5000 step 10` · WP `5..400 step 5` · pair rewards/day + spar-paid/pair/day enforced at resolve. Social never mints WP/AC except transparent `house_bankroll` top-up (to 10k when <6k, 1/d) and `house_unlock` (5k, <8 titles).
