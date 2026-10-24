// lib/core/constants/share_links.dart
//
// One source of truth for what leaves the app when a player shares.
//
// There is no landing page per invite yet (no /j/<code>, no /c/<code>): every
// link points at the hosted download page so a recipient always has a next
// step. When those pages ship, change the builders below — no call site moves,
// and no surface needs to know which URL is current.

import 'app_constants.dart';

/// Where a share link sends someone who does not have the app yet.
const String kShareDownloadUrl = '$kShopUrl/download.html';

/// Host-only form of the site, printed small on share cards.
const String kShareLinkHost = 'anime-quiz-1ab1b.web.app';

/// Referral invite. The code is the inviter's uid (see `AuthService`).
///
/// The reward promise here must stay true: `claimReferralBonus` pays out only
/// after the invitee finishes the qualifying quizzes, so the copy offers no
/// coins for merely signing up.
String referralShareMessage(String code) =>
    'Join me on AnimeQuiz! Use my referral code: $code — we both earn AC.\n'
    '$kShareDownloadUrl';

/// Challenge invite. A challenge code is only joinable while the challenge is
/// still open, so the copy says that rather than implying a permanent room.
String challengeShareMessage(String code) =>
    'I challenged you on AnimeQuiz! ⚔️\n'
    'Open the app, tap Join Challenge and enter: $code\n'
    'The code works while the challenge is still open.\n'
    '$kShareDownloadUrl';

/// Friend-code invite. Deliberately separate from the referral invite: adding
/// a friend pays nothing, so no reward is promised here.
String friendCodeShareMessage(String code) =>
    'Add me on AnimeQuiz! My friend code is $code';

/// Weekly winners announcement.
///
/// [winnerLines] are pre-formatted by the page (medal, name, campus, naira)
/// because the layout of a podium row is a display concern, not copy.
String winnersShareMessage({
  required String weekRange,
  required List<String> winnerLines,
}) =>
    '🎌 AnimeQuiz Champions ($weekRange):\n'
    '${winnerLines.join('\n')}\n\n'
    'Think you can top this? Join AnimeQuiz now!\n'
    '$kShareDownloadUrl';
