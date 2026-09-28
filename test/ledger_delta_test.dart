// test/ledger_delta_test.dart
//
// Regression tests for the Pi-page History ledger's money columns.
//
// The History tab is a *balance ledger*: every row must answer "how much did
// my balance actually move because of this match". That is not the same as the
// settlement credit, because both the AC stake and the WP stake are debited
// when the challenge is created/joined (functions/index.js:1841 creator,
// :2121 joiner) — long before the outcome is known.
//
// The bug this guards: a rival LOSS stored wpChange = 0 ("the stake was
// already lost at stake time — no further deduction"), and the row only
// rendered a WP line when wpChange != 0. So the one match that actually cost
// the player Weekly Points displayed no WP at all.
//
// The oracle below is a direct transcription of the deployed Cloud Function
// balance movements in _resolveChallengeCore. If either side changes, this
// test fails rather than the two silently drifting apart again.

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz/features/multiplayer/challenge_model.dart';

/// The WP balance movement the server actually applied, transcribed from
/// _resolveChallengeCore:
///
///   at create/join : -wpStake                       (:1841, :2121)
///   at resolve     : +(flatBonus + stakeCredit)     (:2336-2342, :2404-2424)
///
/// with stakeCredit from the win / opponent_wins / draw branches at :2406-2416.
int _serverWpNet({
  required int wpStake,
  required bool won,
  required bool isDraw,
  required int flatBonus,
}) {
  var credit = 0;
  if (wpStake > 0) {
    if (won) {
      credit = wpStake + (wpStake * 0.9).floor();
    } else if (!isDraw) {
      credit = 0; // loser: stake already gone, no further credit
    } else {
      credit = (wpStake * 0.9).floor();
    }
  }
  return flatBonus + credit - wpStake;
}

/// The AC balance movement the server actually applied, transcribed from
/// _resolveChallengeCore: -stakeAmount at create/join, +winnerTotal /
/// +drawReturn / +0 at resolve (:2281-2298, :2385-2397).
int _serverAcNet({
  required int stakeAmount,
  required bool won,
  required bool isDraw,
}) {
  if (stakeAmount <= 0) return 0;
  final credit = won
      ? stakeAmount + (stakeAmount * 0.9).floor()
      : isDraw
          ? (stakeAmount * 0.95).floor()
          : 0;
  return credit - stakeAmount;
}

void main() {
  group('wpLedgerDelta — a rival loss is a real WP deduction', () {
    test('losing a 40 WP rival stake reports −40, not nothing', () {
      // wpChange == 0 is what the server stores for the losing side.
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 40,
        wpChange: 0,
        won: false,
        isDraw: false,
      );

      expect(delta, -40,
          reason: 'the stake left the balance at create time — the ledger '
              'must carry it, otherwise a rival loss looks free');
    });

    test('wpChange == 0 alone is never mistaken for "no WP moved"', () {
      // The distinguishing input is wpStake, not wpChange. Every one of these
      // documents carries wpChange == 0 and they must not collapse together.
      final rivalLoss = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 60,
        wpChange: 0,
        won: false,
        isDraw: false,
      );
      final codeLoss = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 0,
        wpChange: 0,
        won: false,
        isDraw: false,
      );

      expect(rivalLoss, -60);
      expect(codeLoss, 0,
          reason: 'a Code challenge stakes no WP, so a loss really is zero');
    });
  });

  group('wpLedgerDelta — wins, draws and the flat participation bonus', () {
    // The bonus is credited by the server (CHALLENGE_WIN_WP / CHALLENGE_DRAW_WP)
    // but was never written to the match document, so the old client could not
    // see it: a Code challenge win logged wpChange == 0 and displayed no WP.
    test('a Code challenge win reports the flat 50 WP bonus', () {
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 0,
        wpChange: 0,
        won: true,
        isDraw: false,
      );

      expect(delta, ChallengeModel.challengeWinWpBonus);
      expect(delta, 50);
    });

    test('a Code challenge draw reports the flat 25 WP bonus', () {
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 0,
        wpChange: 0,
        won: false,
        isDraw: true,
      );

      expect(delta, ChallengeModel.challengeDrawWpBonus);
      expect(delta, 25);
    });

    test('matches the server net movement across stakes and outcomes', () {
      for (final stake in [10, 20, 35, 40, 55, 80, 100]) {
        for (final won in [true, false]) {
          for (final isDraw in [true, false]) {
            if (!won && !isDraw) {
              // The loss branch is covered above; keep the matrix readable.
              continue;
            }
            final expected = _serverWpNet(
              wpStake: stake,
              won: won,
              isDraw: isDraw,
              flatBonus: won
                  ? ChallengeModel.challengeWinWpBonus
                  : ChallengeModel.challengeDrawWpBonus,
            );
            final actual = ChallengeModel.wpLedgerDelta(
              isQuickMatch: false,
              wpStake: stake,
              // Reproduce exactly what the server persisted.
              wpChange: won
                  ? stake + (stake * 0.9).floor()
                  : isDraw
                      ? (stake * 0.9).floor()
                      : 0,
              won: won,
              isDraw: isDraw,
            );

            expect(actual, expected,
                reason: 'wpStake=$stake won=$won isDraw=$isDraw');
          }
        }
      }
    });

    test('a rival win nets stake + rake + bonus, not the gross credit', () {
      // Stored credit for a 40 stake win is 76 (= 40 + 36). Rendering that raw
      // claimed +76 when only +46 of it was ever new money.
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 40,
        wpChange: 76,
        won: true,
        isDraw: false,
      );

      // -40 (staked) + 76 (credited) + 50 (flat bonus) = +86
      expect(delta, 86);
    });
  });

  group('wpLedgerDelta — the recorded award wins when present', () {
    test('wpAwarded reflects premium multiplier and daily cap exactly', () {
      // Premium applies floor(x * 1.20) to the combined bonus + stake credit
      // (functions/index.js:2453-2458), and the daily soft cap can truncate it
      // (:2472-2479). Neither is reconstructible from wpChange, so once
      // wpAwarded is stored it must be used verbatim.
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 40,
        wpChange: 76,
        won: true,
        isDraw: false,
        wpAwarded: 151, // floor((50 + 76) * 1.20) — a premium player
      );

      expect(delta, 111, reason: '151 credited, 40 already staked');
    });

    test('a capped-out award of 0 still reports the stake deduction', () {
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: false,
        wpStake: 40,
        wpChange: 76,
        won: true,
        isDraw: false,
        wpAwarded: 0, // daily 300 WP soft cap already reached
      );

      expect(delta, -40);
    });

    test('Quick Match uses the recorded award and never re-derives it', () {
      // Quick Match stakes no WP, so the stored award IS the whole delta.
      // It is written post-multiplier and post-cap (:5258, :5269).
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: true,
        wpStake: 0,
        wpChange: 0,
        won: true,
        isDraw: false,
        wpAwarded: 42, // floor(35 * 1.20)
      );

      expect(delta, 42);
    });

    test('Quick Match loss still pays the 5 WP participation credit', () {
      final delta = ChallengeModel.wpLedgerDelta(
        isQuickMatch: true,
        wpStake: 0,
        wpChange: 5,
        won: false,
        isDraw: false,
      );

      expect(delta, ChallengeModel.quickMatchWpLose);
      expect(delta, 5);
    });
  });

  group('acLedgerDelta — matches the server net movement', () {
    test('matches the server across stakes and outcomes', () {
      for (final stake in [10, 23, 40, 55, 100, 250]) {
        for (final won in [true, false]) {
          for (final isDraw in [true, false]) {
            if (!won && !isDraw) continue;
            final expected = _serverAcNet(
              stakeAmount: stake,
              won: won,
              isDraw: isDraw,
            );
            final actual = ChallengeModel.acLedgerDelta(
              isQuickMatch: false,
              stakeAmount: stake,
              pointsChange: 0,
              won: won,
              isDraw: isDraw,
            );

            expect(actual, expected,
                reason: 'stake=$stake won=$won isDraw=$isDraw');
          }
        }
      }
    });

    test('the draw fee is stake − floor(stake × 0.95), not floor(stake × 0.05)',
        () {
      // A 23-coin stake pays a fee of 2, not 1. The old inline formula used
      // -(stake * 0.05).floor() and was short by one on every stake that is
      // not a multiple of 20.
      final delta = ChallengeModel.acLedgerDelta(
        isQuickMatch: false,
        stakeAmount: 23,
        pointsChange: 0,
        won: false,
        isDraw: true,
      );

      expect(delta, -2);
      expect(delta, isNot(-(23 * 0.05).floor()));
    });

    test('a loss reports the full stake as a deduction', () {
      final delta = ChallengeModel.acLedgerDelta(
        isQuickMatch: false,
        stakeAmount: 40,
        pointsChange: -40,
        won: false,
        isDraw: false,
      );

      expect(delta, -40);
    });

    test('a win reports the rake bonus, not stake + rake', () {
      final delta = ChallengeModel.acLedgerDelta(
        isQuickMatch: false,
        stakeAmount: 40,
        pointsChange: 40,
        won: true,
        isDraw: false,
      );

      expect(delta, 36, reason: 'credited 76, already staked 40');
    });

    test('Quick Match uses the flat rewards', () {
      expect(
        ChallengeModel.acLedgerDelta(
          isQuickMatch: true,
          stakeAmount: 0,
          pointsChange: 0,
          won: true,
          isDraw: false,
        ),
        35,
      );
      expect(
        ChallengeModel.acLedgerDelta(
          isQuickMatch: true,
          stakeAmount: 0,
          pointsChange: 0,
          won: false,
          isDraw: true,
        ),
        15,
      );
      expect(
        ChallengeModel.acLedgerDelta(
          isQuickMatch: true,
          stakeAmount: 0,
          pointsChange: 0,
          won: false,
          isDraw: false,
        ),
        0,
      );
    });

    test('stake-free matches fall back to the stored pointsChange', () {
      final delta = ChallengeModel.acLedgerDelta(
        isQuickMatch: false,
        stakeAmount: 0,
        pointsChange: 12,
        won: true,
        isDraw: false,
      );

      expect(delta, 12);
    });
  });
}
