/// Typed models for the paid weekly leaderboard.
///
/// Board rows used to travel as `Map<String, dynamic>` with string keys, read
/// back through unchecked casts (`e['rank'] as int?`, `e['weeklyPoints'] as
/// int? ?? 0`) at roughly twenty call sites. That shape made it trivially
/// possible to write `(e['rank'] as int) <= 3` — which throws outright when the
/// rank is null for an ineligible row — and to mix an `int` key into the prize
/// map lookup without the compiler noticing. Everything downstream now works
/// against this type instead.
library;

/// How old the board may get before a resume is allowed to re-read it.
///
/// This is **not** a poll cadence: there is no timer, no scheduled wake-up.
/// The Global board loads when the page opens, re-reads on pull-to-refresh, and
/// re-reads on resume only once the last successful fetch is at least this old.
/// Between those events the app performs **zero** Firestore reads for this
/// screen.
///
/// The board was previously backed by live Firestore snapshots (an open
/// websocket per board, streaming every cohort member's `weeklyPoints` write),
/// then by a self-rearming six-hour timer. Both delivered changes nobody acts
/// on that fast while costing reads and battery; load-on-open plus a deliberate
/// pull-to-refresh gives the player the same control with none of the idle work.
const Duration kLeaderboardRefreshInterval = Duration(hours: 6);

/// Whether data fetched at [lastFetchAt] (bound to [fetchedWeek]) needs to be
/// re-read, as of [now].
///
/// Stale when any of the following holds, in priority order:
///   * nothing has been fetched yet;
///   * the calendar week has rolled since the fetch — the old cycle's board is
///     closed, and showing it is actively wrong, not merely old;
///   * [interval] has elapsed.
///
/// Used on resume: a backgrounded app cannot run its timer, so returning after
/// longer than one interval must re-read even though no boundary was crossed.
bool isLeaderboardDataStale({
  required DateTime? lastFetchAt,
  required DateTime now,
  required String fetchedWeek,
  required String currentWeek,
  Duration interval = kLeaderboardRefreshInterval,
}) {
  if (lastFetchAt == null) return true;
  if (fetchedWeek != currentWeek) return true;
  return now.difference(lastFetchAt) >= interval;
}

/// Whether a change in the signed-in player's own weekly points justifies a
/// network read.
///
/// **It does not, and never will.** The position card already renders the
/// player's points live from [UserDataProvider], and their rank is recomputed
/// from the stored snapshot (see [rankInSnapshot]), so scoring updates the
/// screen with no read at all. Only the *other* 99 rows need a re-read, and they
/// wait for the next scheduled refresh.
///
/// Changing your entry week is different and does warrant a read: it changes
/// which cohort the board is querying, from "nobody" to a paid board.
bool shouldRefetchOnProviderChange({
  required String previousEntryWeek,
  required String nextEntryWeek,
}) =>
    previousEntryWeek != nextEntryWeek;

/// The rank the signed-in player would hold against a stored snapshot at
/// [myPoints], using the same sequential numbering the board applies.
///
/// The board numbers rows 1..N in query order down the `weeklyPoints desc`
/// ordering (ties broken by document id), NOT by competition rank — see
/// [BoardEntry.rank]. Counting rows with *strictly* higher points would
/// disagree with the visible row whenever scores tie.
///
/// So the stored order is used, with the player's live [myPoints] in place of
/// their stored score. A row stored *before* the player is ahead of them when
/// it has at least [myPoints] (a tie keeps document order); a row stored
/// *after* them is ahead only when it is strictly higher. Both cases handle the
/// live points moving either way, so scoring between refreshes still moves the
/// rank with no network read.
///
/// When the player is absent (ranked beyond the 100-row window) there is no
/// position to anchor to, every row is compared strictly, and the result exceeds
/// `entries.length`; [resolveDisplayRank] then uses the COUNT-captured rank.
int rankInSnapshot({
  required List<BoardEntry> entries,
  required int myPoints,
}) {
  final mine = entries.indexWhere((e) => e.isCurrentUser);
  var rank = 1;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (i == mine || !e.isRanked) continue;
    final ahead = (mine >= 0 && i < mine)
        ? e.weeklyPoints >= myPoints
        : e.weeklyPoints > myPoints;
    if (ahead) rank++;
  }
  return rank;
}

/// The rank to display for the signed-in player.
///
/// Uses the live-points derivation while the player is inside the fetched
/// window. Past that window the snapshot cannot see them at all, so the rank
/// captured by the COUNT query at fetch time is used instead. Returns 0 when
/// neither is available, which the card renders as unranked rather than
/// guessing.
int resolveDisplayRank({
  required List<BoardEntry> entries,
  required int myPoints,
  required int capturedRank,
}) {
  final derived = rankInSnapshot(entries: entries, myPoints: myPoints);
  if (derived <= entries.length) return derived;
  return capturedRank > 0 ? capturedRank : 0;
}

/// One aggregated read of everything the leaderboard renders.
///
/// Assembled in parallel so a slow campus query does not delay the board, and
/// so the board and the pool land in the same frame instead of the layout
/// shifting twice.
class LeaderboardSnapshot {
  /// Global cohort board, already ranked.
  final List<BoardEntry> global;

  /// `prize_pool/{currentWeek}`.
  final Map<String, dynamic> pool;

  /// Legacy floor input. Always 0 under the fixed-pool model — kept so
  /// pinned tests and old call sites keep compiling. Never sizes the pool.
  final double guaranteedFloor;

  /// The pool actually allocated last week, when a cycle has been calculated.
  ///
  /// DISPLAY ONLY. Each week's pool is independent — there is no carryover — so
  /// this number is never added to, or compared against, this week's
  /// projection. It exists purely as a reference point so a player can see the
  /// projected figure is tracking something real.
  final double? lastWeekPool;

  /// When these figures were read, shown in the footer. Null only for
  /// [LeaderboardSnapshot.empty], which has never been fetched.
  final DateTime? fetchedAt;

  const LeaderboardSnapshot({
    required this.global,
    required this.pool,
    required this.guaranteedFloor,
    required this.lastWeekPool,
    required this.fetchedAt,
  });

  /// False when the `prize_pool` document does not exist yet, so the card can
  /// say "Opening soon" instead of advertising a zero prize.
  bool get poolOpen => pool['status'] != 'missing';

  static const LeaderboardSnapshot empty = LeaderboardSnapshot(
    global: <BoardEntry>[],
    pool: <String, dynamic>{},
    guaranteedFloor: 0,
    lastWeekPool: null,
    fetchedAt: null,
  );
}

/// One row on a weekly leaderboard.
///
/// [rank] is `null` for a player who has no entry for the current week. Those
/// rows still appear (the payout admin sees everyone; a stale entry week can
/// briefly surface the whole cohort) but they occupy no rank slot and win
/// nothing, so every "what does this row win" question must handle null.
class BoardEntry {
  /// 1-based position within the board's cohort, or `null` when the player is
  /// not ranked this week.
  ///
  /// Sequential, not competition ranking: two players on equal points get
  /// consecutive ranks in document order, exactly as the reset's snapshot and
  /// `weeklyStanding` both number them. Ties therefore never produce two
  /// players claiming the same rank on screen.
  final int? rank;

  /// Firestore document id of the player.
  final String uid;

  /// Display name, falling back to "Anonymous" server-side-safe.
  final String username;

  /// One of `kNigerianUniversities`, or empty when unset.
  final String university;

  /// Weekly points accrued in the current cycle.
  final int weeklyPoints;

  /// Whether this row is the signed-in player.
  final bool isCurrentUser;

  /// The leaderboard week this player paid for. Null means never entered.
  final String? entryWeekId;

  const BoardEntry({
    required this.rank,
    required this.uid,
    required this.username,
    required this.university,
    required this.weeklyPoints,
    required this.isCurrentUser,
    required this.entryWeekId,
  });

  /// True when the player holds a rank this week and can therefore win.
  bool get isRanked => rank != null && rank! > 0;

  /// Single-letter avatar glyph.
  String get initial => username.isEmpty ? '?' : username[0].toUpperCase();

  @override
  bool operator ==(Object other) =>
      other is BoardEntry &&
      other.rank == rank &&
      other.uid == uid &&
      other.username == username &&
      other.university == university &&
      other.weeklyPoints == weeklyPoints &&
      other.isCurrentUser == isCurrentUser &&
      other.entryWeekId == entryWeekId;

  @override
  int get hashCode => Object.hash(rank, uid, username, university, weeklyPoints,
      isCurrentUser, entryWeekId);

  @override
  String toString() => 'BoardEntry(#$rank $uid $username $weeklyPoints pts)';
}

/// Splits a board into the podium and the rows beneath it.
///
/// Ranked rows sort by rank; unranked rows (an admin viewing non-entrants, or
/// a cohort that has just been finalised) keep their relative order and are
/// appended last, so a stale board can never displace a real podium.
({List<BoardEntry> podium, List<BoardEntry> rest}) splitBoard(
  List<BoardEntry> entries,
) {
  final ranked = <BoardEntry>[];
  final unranked = <BoardEntry>[];
  for (final e in entries) {
    (e.isRanked ? ranked : unranked).add(e);
  }
  ranked.sort((a, b) => a.rank!.compareTo(b.rank!));

  // The podium is a prefix of the ranked rows; `rest` must therefore start
  // after it. Deriving both independently let a short board (one or two
  // entrants) list the same row as both podium and list entry.
  final podium = ranked.length <= 3 ? List.of(ranked) : ranked.sublist(0, 3);
  final rest = <BoardEntry>[...ranked.skip(podium.length), ...unranked];

  return (podium: podium, rest: rest);
}

/// One rendered element of the board list: a row, a range band, or a gap.
sealed class BoardSlot {
  const BoardSlot();
}

/// A player row.
class RowSlot extends BoardSlot {
  final BoardEntry entry;
  const RowSlot(this.entry);
}

/// A "ranks 51–75" band label.
class GroupSlot extends BoardSlot {
  final String label;
  final int fromRank;
  final int toRank;
  const GroupSlot(this.label, this.fromRank, this.toRank);
}

/// A collapsed span of rows the player cannot currently see.
class GapSlot extends BoardSlot {
  final int hiddenAbove;
  final int hiddenBelow;
  const GapSlot({required this.hiddenAbove, required this.hiddenBelow});
}

/// Flattens the board into the sequence the list renders.
///
/// Two things happen here that used to be impossible to reason about:
///
/// 1. **Neighbourhood windowing.** A player ranked #74 in a 100-row board has
///    their own row visible, but scrolling a hundred rows to find it is a
///    losing experience, and the moment someone overtakes them the row they
///    care about moves out from under their thumb. When both the rows above and
///    below the player would be cut, the list instead shows a ±[neighbourWindow]
///    window around them and collapses the rest behind a "…+N above" marker.
///    With fewer than roughly two screens' worth of rows it shows everything,
///    so short boards never look artificially chopped.
/// 2. **Rank range bands.** Without them a 100-row list is an undifferentiated
///    wall; they give the eye something to navigate by.
List<BoardSlot> buildBoardSlots(
  List<BoardEntry> rows, {
  int neighbourWindow = 2,
  int groupSize = 25,
}) {
  if (rows.isEmpty) return const [];

  final mine = rows.indexWhere((e) => e.isCurrentUser);

  // Only collapse a list long enough to be worth navigating. Below this,
  // showing everything is both simpler and cheaper than a window plus two
  // gap markers, which would cost more vertical space than they save.
  var start = 0;
  var end = rows.length;
  if (mine >= 0 && rows.length > 25) {
    start = (mine - neighbourWindow).clamp(0, rows.length);
    end = (mine + neighbourWindow + 1).clamp(0, rows.length);
  }

  final slots = <BoardSlot>[];
  final hiddenAbove = start;
  final hiddenBelow = rows.length - end;

  if (hiddenAbove > 0) {
    slots.add(GapSlot(hiddenAbove: hiddenAbove, hiddenBelow: 0));
  }

  var lastGroupIndex = -1;

  // Clamp band labels to ranks that actually exist, so a 60-row board does
  // not advertise a "Ranks 51–75" band with nobody in 61–75.
  var maxRank = 0;
  for (final e in rows) {
    final r = e.rank;
    if (r != null && r > maxRank) maxRank = r;
  }

  for (var i = start; i < end; i++) {
    final entry = rows[i];
    final rank = entry.rank;

    if (rank != null && rank > 0) {
      final groupIndex = (rank - 1) ~/ groupSize;
      if (groupIndex != lastGroupIndex) {
        lastGroupIndex = groupIndex;
        final from = groupIndex * groupSize + 1;
        final to =
            (from + groupSize - 1) > maxRank ? maxRank : from + groupSize - 1;
        slots.add(GroupSlot('Ranks $from–$to', from, to));
      }
    }

    slots.add(RowSlot(entry));
  }

  if (hiddenBelow > 0) {
    slots.add(GapSlot(hiddenAbove: 0, hiddenBelow: hiddenBelow));
  }

  return slots;
}
