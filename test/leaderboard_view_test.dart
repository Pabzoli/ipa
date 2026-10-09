import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quiz/core/constants/app_constants.dart';
import 'package:quiz/core/services/firestore_service.dart';
import 'package:quiz/core/services/prize_pool_service.dart';
import 'package:quiz/features/leaderboard/leaderboard_models.dart';
import 'package:quiz/features/leaderboard/widgets/leaderboard_pool_card.dart';
import 'package:quiz/features/leaderboard/widgets/leaderboard_position.dart';
import 'package:quiz/features/leaderboard/widgets/leaderboard_rows.dart';
import 'package:quiz/features/leaderboard/widgets/leaderboard_states.dart';

BoardEntry row(int rank, {String? uid, int points = 100, bool me = false}) {
  return BoardEntry(
    rank: rank,
    uid: uid ?? 'u$rank',
    username: 'Player$rank',
    university: 'UNILAG',
    weeklyPoints: points,
    isCurrentUser: me,
    entryWeekId: '2025-06-16',
  );
}

Widget wrap(Widget content) => MaterialApp(
      home: ScreenUtilInit(
        designSize: const Size(390, 844),
        child: Scaffold(body: content),
      ),
    );

void main() {
  group('Refresh cadence', () {
    test('the board is read four times a day', () {
      // Pinned deliberately: this is a resource/bandwidth decision, not an
      // incidental constant. Changing it should be a conscious edit.
      expect(kLeaderboardRefreshInterval, const Duration(hours: 6));
      expect(
        Duration(days: 1).inMinutes ~/ kLeaderboardRefreshInterval.inMinutes,
        4,
      );
      // No wake-up tick exists any more: the page arms one one-shot timer per
      // successful fetch and does nothing at all between refreshes.
    });

    test('nothing fetched yet is always stale', () {
      expect(
        isLeaderboardDataStale(
          lastFetchAt: null,
          now: DateTime.utc(2025, 6, 16, 12),
          fetchedWeek: '2025-06-16',
          currentWeek: '2025-06-16',
        ),
        isTrue,
      );
    });

    test('fresh within six hours is not stale', () {
      final at = DateTime.utc(2025, 6, 16, 6);
      expect(
        isLeaderboardDataStale(
          lastFetchAt: at,
          now: at.add(const Duration(hours: 5, minutes: 59)),
          fetchedWeek: '2025-06-16',
          currentWeek: '2025-06-16',
        ),
        isFalse,
      );
    });

    test('stale at exactly six hours', () {
      final at = DateTime.utc(2025, 6, 16, 6);
      expect(
        isLeaderboardDataStale(
          lastFetchAt: at,
          now: at.add(const Duration(hours: 6)),
          fetchedWeek: '2025-06-16',
          currentWeek: '2025-06-16',
        ),
        isTrue,
      );
    });

    test('a week rollover makes data stale no matter how recent', () {
      // The previous cycle's board is closed. Showing it with a fresh
      // timestamp would be wrong, not just old.
      final at = DateTime.utc(2025, 6, 16, 6);
      expect(
        isLeaderboardDataStale(
          lastFetchAt: at,
          now: at.add(const Duration(minutes: 1)),
          fetchedWeek: '2025-06-09',
          currentWeek: '2025-06-16',
        ),
        isTrue,
      );
    });
  });

  // 2025-06-16 is a Monday, so 2025-06-22 is the Sunday of that week.
  group('nextRefreshAt', () {
    test('mid-week: plain six-hour cadence', () {
      final fetched = DateTime.utc(2025, 6, 16, 8);
      expect(
        nextRefreshAt(fetchedAt: fetched, now: fetched),
        DateTime.utc(2025, 6, 16, 14),
      );
    });

    test('before the reset: the Sunday 23:00 boundary wins', () {
      // Sunday 20:00 + 6h would be Monday 02:00, but the CF resets at 23:00 and
      // zeroes every score there, so that boundary takes priority.
      final fetched = DateTime.utc(2025, 6, 22, 20);
      expect(
        nextRefreshAt(fetchedAt: fetched, now: fetched),
        DateTime.utc(2025, 6, 22, 23),
      );
    });

    test('after the reset: the Monday 00:00 week rollover wins', () {
      // Sunday 23:30 + 6h would be Monday 05:30. The reset has already run and
      // points are zeroed, but currentWeekId still names the closed week until
      // 00:00, so the rollover is the next moment worth reading.
      final fetched = DateTime.utc(2025, 6, 22, 23, 30);
      expect(
        nextRefreshAt(fetchedAt: fetched, now: fetched),
        DateTime.utc(2025, 6, 23, 0),
      );
    });

    test('each boundary triggers exactly one fetch', () {
      // Fetching at the reset must reschedule for the rollover, not for the
      // same boundary again (which would fire in a loop).
      final atReset = DateTime.utc(2025, 6, 22, 23);
      expect(
        nextRefreshAt(fetchedAt: atReset, now: atReset),
        DateTime.utc(2025, 6, 23, 0),
      );

      // ...and fetching at the rollover skips to the plain cadence.
      final atRollover = DateTime.utc(2025, 6, 23, 0);
      expect(
        nextRefreshAt(fetchedAt: atRollover, now: atRollover),
        DateTime.utc(2025, 6, 23, 6),
      );
    });

    test('never schedules in the past', () {
      // Defensive against a busy-loop if the clock jumps backwards.
      final fetched = DateTime.utc(2025, 6, 16, 8);
      final now = fetched.add(const Duration(days: 3));
      expect(nextRefreshAt(fetchedAt: fetched, now: now).isAfter(now), isTrue);
    });
  });

  group('Resume path', () {
    test('resume after an hour does NOT re-read', () {
      // The scheduled refresh is still armed; a resume must not duplicate it.
      final at = DateTime.utc(2025, 6, 16, 6);
      expect(
        isLeaderboardDataStale(
          lastFetchAt: at,
          now: at.add(const Duration(hours: 1)),
          fetchedWeek: '2025-06-16',
          currentWeek: '2025-06-16',
        ),
        isFalse,
      );
    });

    test('resume after seven hours DOES re-read', () {
      // A backgrounded app cannot run its timer, so this is the only thing that
      // recovers a schedule missed while suspended.
      final at = DateTime.utc(2025, 6, 16, 6);
      expect(
        isLeaderboardDataStale(
          lastFetchAt: at,
          now: at.add(const Duration(hours: 7)),
          fetchedWeek: '2025-06-16',
          currentWeek: '2025-06-16',
        ),
        isTrue,
      );
    });
  });

  group('Points changes never trigger a read', () {
    test('a points change is not a reason to refetch', () {
      // The policy function takes only the entry week, so scoring cannot
      // appear as a trigger. Asserted explicitly so reintroducing one is a
      // visible failure.
      expect(
        shouldRefetchOnProviderChange(
          previousEntryWeek: '2025-06-16',
          nextEntryWeek: '2025-06-16',
        ),
        isFalse,
      );
    });

    test('an entry-week change does refetch', () {
      // It swaps the cohort the board queries, so the stored snapshot describes
      // a different set of players entirely.
      expect(
        shouldRefetchOnProviderChange(
          previousEntryWeek: '',
          nextEntryWeek: '2025-06-16',
        ),
        isTrue,
      );
    });
  });

  group('Live rank from a stored snapshot', () {
    List<BoardEntry> board(int n) =>
        List.generate(n, (i) => row(i + 1, points: 1000 - i * 10));

    test('rank is one more than the number of strictly higher rows', () {
      final rows = board(5); // 1000, 990, 980, 970, 960
      expect(rankInSnapshot(entries: rows, myPoints: 1000), 1);
      // 985 beats 980/970/960 but not 1000/990 -> three ahead -> rank 4.
      expect(rankInSnapshot(entries: rows, myPoints: 985), 3);
      expect(rankInSnapshot(entries: rows, myPoints: 960), 5);
      // Below every row in the snapshot.
      expect(rankInSnapshot(entries: rows, myPoints: 0), 6);
    });

    test('ties are shared by nobody: strictly-greater only', () {
      // 980 ties with the rank-3 row and beats ranks 4-5, so it is rank 3.
      expect(rankInSnapshot(entries: board(5), myPoints: 980), 3);
    });

    test('uses live points, so scoring moves the rank with no read', () {
      final rows = board(5);
      // 970 ties with the rank-4 row and beats rank 5 -> three ahead -> rank 4.
      final before = resolveDisplayRank(
        entries: rows,
        myPoints: 970,
        capturedRank: 0,
      );
      // 990 beats only the leader -> rank 2.
      final after = resolveDisplayRank(
        entries: rows,
        myPoints: 990,
        capturedRank: 0,
      );
      expect(before, 4);
      expect(after, 2);
      // Same snapshot object throughout: nothing was refetched.
    });

    test('falls back to the fetch-time rank below the window', () {
      // Nobody in a full 100-row snapshot scores below 10, so the derivation
      // returns 101 and must be discarded for the COUNT-captured rank.
      expect(
        resolveDisplayRank(
          entries: board(100),
          myPoints: 5,
          capturedRank: 147,
        ),
        147,
      );
    });

    test('reports unranked when neither source knows', () {
      expect(
        resolveDisplayRank(
          entries: board(100),
          myPoints: 5,
          capturedRank: 0,
        ),
        0,
      );
    });
  });

  group('splitBoard', () {
    test('separates the podium from the rest, in rank order', () {
      final split = splitBoard([
        row(3, points: 10),
        row(1, points: 30),
        row(2, points: 20),
        row(4, points: 9),
      ]);
      expect(split.podium.map((e) => e.rank), [1, 2, 3]);
      expect(split.rest.map((e) => e.rank), [4]);
    });

    test('unranked rows never take a podium slot', () {
      // A stale cohort (week just rolled) ranks nothing; a real podium must
      // still be built if any ranked rows exist.
      final split = splitBoard([
        row(1, points: 30),
        const BoardEntry(
          rank: null,
          uid: 'ghost',
          username: 'NoEntry',
          university: '',
          weeklyPoints: 5,
          isCurrentUser: false,
          entryWeekId: null,
        ),
      ]);
      expect(split.podium.map((e) => e.rank), [1]);
      expect(split.rest.single.isRanked, isFalse);
    });

    test('a single entrant is not a podium', () {
      final split = splitBoard([row(1)]);
      expect(split.podium, hasLength(1));
      expect(split.rest, isEmpty);
    });

    test('empty board yields nothing', () {
      final split = splitBoard([]);
      expect(split.podium, isEmpty);
      expect(split.rest, isEmpty);
    });
  });

  group('buildBoardSlots', () {
    test('short boards render every row with no gap markers', () {
      final slots = buildBoardSlots([row(1), row(2), row(3), row(4, me: true)]);
      expect(slots.whereType<GapSlot>(), isEmpty);
      expect(slots.whereType<RowSlot>(), hasLength(4));
    });

    test('inserts rank-range bands every 25 ranks', () {
      // No signed-in player in this list, so nothing is windowed and the bands
      // can be checked in isolation.
      final rows = List.generate(60, (i) => row(i + 1));
      final slots = buildBoardSlots(rows);
      final groups = slots.whereType<GroupSlot>().toList();
      // Last band is clamped to the ranks that exist, not to 51–75.
      expect(groups.map((g) => g.label),
          ['Ranks 1–25', 'Ranks 26–50', 'Ranks 51–60']);
      expect(slots.whereType<RowSlot>(), hasLength(60));
    });

    test('windows around the player and collapses the rest', () {
      final rows = List.generate(100, (i) => row(i + 1, me: i == 49));
      final slots = buildBoardSlots(rows, neighbourWindow: 2);

      // Player is rank 50 (index 49), so rows 48–52 are kept.
      final shown = slots.whereType<RowSlot>().map((s) => s.entry.rank).toList();
      expect(shown, [48, 49, 50, 51, 52]);

      final gaps = slots.whereType<GapSlot>().toList();
      expect(gaps, hasLength(2));
      expect(gaps.first.hiddenAbove, 47);
      expect(gaps.last.hiddenBelow, 48);
    });

    test('boards too short to be worth collapsing render in full', () {
      // 20 rows is under the collapse threshold, so the player gets the whole
      // list rather than a five-row window between two gap markers.
      final rows = List.generate(20, (i) => row(i + 1, me: i == 9));
      final slots = buildBoardSlots(rows);
      expect(slots.whereType<GapSlot>(), isEmpty);
      expect(slots.whereType<RowSlot>(), hasLength(20));
    });

    test('keeps the player visible when they are near the top', () {
      final rows = List.generate(100, (i) => row(i + 1, me: i == 3));
      final slots = buildBoardSlots(rows, neighbourWindow: 2);
      final shown = slots.whereType<RowSlot>().map((s) => s.entry.rank);
      expect(shown, contains(4));
      expect(slots.whereType<GapSlot>(), isNotEmpty);
    });
  });

  group('WeeklyStanding', () {
    test('topPercent is ceiled and never 0 or 100', () {
      WeeklyStanding at(int rank, int total) =>
          WeeklyStanding(rank: rank, totalPlayers: total, myPoints: 1);
      expect(at(1, 100).topPercent, 1);
      expect(at(50, 100).topPercent, 50);
      // 1 of 3 ceils to 34, not 33.3.
      expect(at(1, 3).topPercent, 34);
      // A lone player must not be told they are in the top 99%.
      expect(at(1, 1).topPercent, isNull);
      expect(at(0, 100).topPercent, isNull);
      expect(at(100, 100).topPercent, 99);
    });

    test('pointsToOvertake always costs at least one point', () {
      // Tied on score: the target equals our own, which must not read as
      // "0 points needed".
      final tied = WeeklyStanding(
        rank: 5,
        totalPlayers: 20,
        myPoints: 50,
        pointsToNextRank: 50,
      );
      expect(tied.pointsToOvertake, 1);

      final behind = WeeklyStanding(
        rank: 5,
        totalPlayers: 20,
        myPoints: 20,
        pointsToNextRank: 50,
      );
      expect(behind.pointsToOvertake, 31);

      // Rank 1 has nobody to overtake.
      expect(
        WeeklyStanding(rank: 1, totalPlayers: 5, myPoints: 99).pointsToOvertake,
        isNull,
      );
    });
  });

  group('PrizePoolCard', () {
    testWidgets('labels a revenue projection as provisional, never a promise',
        (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 50000,
      );
      expect(projection.amount, 35000);

      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: false,
      )));

      expect(find.text('₦35K'), findsOneWidget);
      expect(find.text('Projected · finalised Monday'), findsOneWidget);
    });

    testWidgets('an empty board invites the first entry instead of promising '
        'a payout', (tester) async {
      // The CF allocates the floor to a cycle whose `ranked` array is empty, so
      // an empty week pays nobody. "Guaranteed minimum" next to a naira figure
      // would read as money already committed.
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 0,
        guaranteedFloor: 20000,
      );
      expect(projection.source, PoolSource.floor);

      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: true,
      )));

      expect(
        find.text('Be the first to enter. Prize pool starts at ₦20K'),
        findsOneWidget,
      );
      expect(find.text('Guaranteed minimum · projected'), findsNothing);
    });

    testWidgets('an empty board with no floor avoids quoting ₦0', (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 0,
        guaranteedFloor: 0,
      );

      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: true,
      )));

      expect(find.text('Be the first to enter.'), findsOneWidget);
      expect(find.textContaining('Prize pool starts at ₦0'), findsNothing);
    });

    testWidgets('the floor label still applies once people have entered',
        (tester) async {
      // The floor is still worth naming once there are entrants: it means the
      // figure is a subsidy rather than sales.
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 1000,
        guaranteedFloor: 20000,
      );

      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: false,
      )));

      expect(find.text('Guaranteed minimum · projected'), findsOneWidget);
    });

    testWidgets('does not claim "projected" for an admin-fixed pool',
        (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 100,
        adminPoolNaira: 25000,
      );
      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: false,
      )));

      expect(find.text('Fixed for this week'), findsOneWidget);
      expect(find.text('Projected · finalised Monday'), findsNothing);
    });

    testWidgets('says so when the pool is riding the guaranteed floor',
        (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 1000,
        guaranteedFloor: 20000,
      );
      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: false,
      )));

      expect(find.text('Guaranteed minimum · projected'), findsOneWidget);
    });

    testWidgets('shows last week\'s actuals as the trust anchor',
        (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 50000,
      );
      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: 21000,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: false,
      )));

      expect(find.text('Last week paid ₦21K'), findsOneWidget);
    });

    test('last week is never added to this week', () {
      // NO ROLLOVER. Each week's pool is funded only by its own entries (or the
      // admin's fixed figure). The displayed figure must be exactly the
      // projection, whatever last week paid.
      final withNothingLastWeek = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 50000,
      );
      final afterAFortnightOfRichWeeks = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 50000,
      );

      // 70% of 50000, not 7000 plus any of last week's 2M.
      expect(withNothingLastWeek.amount, 35000);
      expect(afterAFortnightOfRichWeeks.amount, 35000);

      // And the floor is a floor, not a carryover target.
      expect(
        PrizePoolService.projectPrizePool(
          entryCodeRevenue: 0,
          guaranteedFloor: 20000,
        ).amount,
        20000,
      );
    });

    testWidgets('copy never implies a carryover', (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 50000,
      );
      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: 2000000,
        weekId: '2025-06-16',
        poolOpen: true,
        isBoardEmpty: false,
      )));

      // This week's figure is unchanged by a ₦2M last week...
      expect(find.text('₦35K'), findsOneWidget);
      // ...and the reference line is phrased as a completed payment, not as
      // money still in the pot.
      expect(find.text('Last week paid ₦2.0M'), findsOneWidget);

      final copy = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ')
          .toLowerCase();
      for (final banned in [
        'rollover',
        'roll over',
        'rolled over',
        'carried over',
        'carryover',
        'jackpot',
        'still in the pot',
        'unclaimed',
      ]) {
        expect(copy, isNot(contains(banned)), reason: 'copy says "$banned"');
      }
    });

    testWidgets('does not open with a pool that does not exist yet',
        (tester) async {
      final projection = PrizePoolService.projectPrizePool(
        entryCodeRevenue: 0,
      );
      await tester.pumpWidget(wrap(PrizePoolCard(
        projection: projection,
        lastWeekPool: null,
        weekId: '2025-06-16',
        poolOpen: false,
        isBoardEmpty: false,
      )));

      expect(find.text('Opening soon'), findsOneWidget);
    });
  });

  group('YourPositionCard', () {
    testWidgets('shows a real rank and the gap to the next one',
        (tester) async {
      await tester.pumpWidget(wrap(YourPositionCard(
        standing: const WeeklyStanding(
          rank: 47,
          totalPlayers: 240,
          myPoints: 320,
          pointsToNextRank: 403,
          nextRankUsername: 'Ada',
        ),
        myWeeklyPoints: 320,
        displayName: 'Me',
        isEligible: true,
      )));

      expect(find.text('#47'), findsOneWidget);
      expect(find.text('#47 of 240 · top 20% · 320 pts'), findsOneWidget);
      expect(find.text('84 pts to pass Ada'), findsOneWidget);
    });

    testWidgets('a rank-1 player is told they lead, not given a fake target',
        (tester) async {
      await tester.pumpWidget(wrap(YourPositionCard(
        standing: const WeeklyStanding(
          rank: 1,
          totalPlayers: 90,
          myPoints: 900,
        ),
        myWeeklyPoints: 900,
        displayName: 'Me',
        isEligible: true,
      )));

      expect(find.text('You lead the board. Hold it.'), findsOneWidget);
    });

    testWidgets('an unranked entrant still sees their points', (tester) async {
      await tester.pumpWidget(wrap(YourPositionCard(
        standing: WeeklyStanding.none,
        myWeeklyPoints: 75,
        displayName: 'Me',
        isEligible: true,
      )));

      expect(find.text('#—'), findsOneWidget);
      expect(find.text('75 pts this week'), findsOneWidget);
      // No chase prompt without a rank to chase.
      expect(find.textContaining('pts to pass'), findsNothing);
    });

    testWidgets('a non-entrant is told why and shown the CTA', (tester) async {
      await tester.pumpWidget(wrap(YourPositionCard(
        standing: WeeklyStanding.none,
        myWeeklyPoints: 120,
        displayName: 'Me',
        isEligible: false,
        entryCta: const LeaderboardEntryCta(),
      )));

      expect(
        find.text("You're not eligible for prizes this week"),
        findsOneWidget,
      );
      expect(find.byType(LeaderboardEntryCta), findsOneWidget);
    });

    testWidgets('no CTA is rendered for an entrant', (tester) async {
      await tester.pumpWidget(wrap(YourPositionCard(
        standing: const WeeklyStanding(rank: 3, totalPlayers: 9, myPoints: 50),
        myWeeklyPoints: 50,
        displayName: 'Me',
        isEligible: true,
      )));

      expect(find.byType(LeaderboardEntryCta), findsNothing);
    });
  });

  group('LeaderboardEntryCta', () {
    testWidgets('on a non-web build it points at the website, never nothing',
        (tester) async {
      // The old handler returned early on non-web with no snackbar, no sheet
      // and no launch: tapping the primary CTA did literally nothing.
      await tester.pumpWidget(wrap(const LeaderboardEntryCta()));

      expect(find.text(kEntryCtaLabelExternal), findsOneWidget);
      expect(find.text(kEntryCtaLabelWeb), findsNothing);
      expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
    });

    testWidgets('a disabled reason is announced rather than silently ignored',
        (tester) async {
      await tester.pumpWidget(wrap(const LeaderboardEntryCta(
        disabledReason: 'Sign in to purchase a leaderboard entry.',
      )));

      final button = tester.widget<ElevatedButton>(
        find.byType(ElevatedButton),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('RankRow', () {
    testWidgets('an ineligible row says No entry instead of a prize',
        (tester) async {
      await tester.pumpWidget(wrap(RankRow(
        entry: const BoardEntry(
          rank: null,
          uid: 'x',
          username: 'Ghost',
          university: '',
          weeklyPoints: 40,
          isCurrentUser: false,
          entryWeekId: null,
        ),
        prize: null,
        isMe: false,
        isRival: false,
        isNextRank: false,
        isBelowRank: false,
      )));

      expect(find.text('No entry'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('the row directly above the player is flagged',
        (tester) async {
      await tester.pumpWidget(wrap(RankRow(
        entry: row(4, points: 500),
        prize: 3500,
        isMe: false,
        isRival: false,
        isNextRank: true,
        isBelowRank: false,
      )));

      expect(find.text('PASS ME'), findsOneWidget);
      expect(find.text('500 weekly pts'), findsOneWidget);
    });

    testWidgets('carries a screen-reader label with the real prize',
        (tester) async {
      // Disposed at the end of the body, not via addTearDown: the binding
      // verifies semantics handles before tearDowns run.
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(wrap(RankRow(
        entry: row(1, points: 900),
        prize: 35000,
        isMe: false,
        isRival: false,
        isNextRank: false,
        isBelowRank: false,
      )));

      // Regex rather than a literal: bySemanticsLabel compares a String for
      // *equality* against the whole node label, so it also fails as soon as
      // anything merges extra text into that node.
      expect(
        find.bySemanticsLabel(
          RegExp(r'Rank 1, Player1, 900 points, ₦35,000'),
        ),
        findsOneWidget,
      );

      handle.dispose();
    });
  });

  group('BoardErrorState', () {
    testWidgets('a missing composite index is named, not shown as empty',
        (tester) async {
      await tester.pumpWidget(wrap(BoardErrorState(
        error: 'FAILED_PRECONDITION: The query requires an index. '
            'You can create the index here: https://console.firebase.google.com',
        onRetry: () {},
      )));

      expect(find.text('Could not load the leaderboard'), findsOneWidget);
      expect(find.textContaining('composite index'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a generic failure offers a retry without blaming an index',
        (tester) async {
      await tester.pumpWidget(wrap(BoardErrorState(
        error: 'PERMISSION_DENIED: Missing or insufficient permissions.',
        onRetry: () {},
      )));

      expect(find.text('Check your connection and try again.'),
          findsOneWidget);
      expect(find.textContaining('composite index'), findsNothing);
    });
  });

  group('LeaderboardPodium', () {
    testWidgets('hidden below two entrants so one card never spans the page',
        (tester) async {
      await tester.pumpWidget(wrap(LeaderboardPodium(
        entries: [row(1)],
        prizes: const {},
        rivalUids: const {},
        onRivalTap: (_) {},
      )));

      expect(find.byType(PodiumCard), findsNothing);
    });

    testWidgets('renders ordered cards for a real podium', (tester) async {
      await tester.pumpWidget(wrap(LeaderboardPodium(
        entries: [row(1, points: 900), row(2, points: 700), row(3, points: 500)],
        prizes: const {1: 35000, 2: 22000, 3: 13000},
        rivalUids: const {},
        onRivalTap: (_) {},
      )));

      expect(find.byType(PodiumCard), findsNWidgets(3));
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
    });
  });

  group('CountdownChip', () {
    testWidgets('renders a countdown and ticks without touching the parent',
        (tester) async {
      await tester.pumpWidget(wrap(const CountdownChip()));
      await tester.pump(const Duration(milliseconds: 100));

      // A self-owned timer: the board list must not rebuild because of this.
      expect(find.byType(CountdownChip), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'(\d+[dhm].*left)|Finalising')),
        findsOneWidget,
      );
    });
  });
}
