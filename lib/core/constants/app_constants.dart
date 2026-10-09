/// Single source of truth for the shop URL (mirrors HOSTING_BASE in
/// functions/index.js).
///
/// Historically this was referenced from app UI as plain, non-interactive text
/// only — never as a tappable/launchable link — because the leaderboard entry
/// purchase is a digital good and Google Play's billing policy forbids routing
/// users to an external provider for one. See
/// [kLeaderboardAllowsExternalEntryLink] for how that constraint is enforced
/// now.
const String kShopUrl = 'https://anime-quiz-1ab1b.web.app';

/// Whether the mobile build may link players out to the hosted shop to buy a
/// leaderboard entry.
///
/// THE ONE SWITCH for the Play Store question. Today the app ships as a
/// sideloaded APK behind a forced-update gate (see AppUpdateService), which
/// carries no Play billing obligation, so the link is allowed — and must stay
/// allowed: hiding it leaves Android/iOS players with no way to enter at all,
/// which silently removes them from every prize pool.
///
/// If the app is ever published on Google Play, set this to `false`. The
/// in-app CTA then stays visible but routes to the in-app redemption flow, and
/// the entry itself must be sold through Play Billing. The web build ignores
/// this flag entirely — it always completes the Flutterwave payment inline.
const bool kLeaderboardAllowsExternalEntryLink = true;

/// Copy for the entry CTA when [kLeaderboardAllowsExternalEntryLink] is true
/// and the app is running on mobile.
///
/// Kept short and action-first: "Buy leaderboard entry · ₦500" looks like an
/// in-app purchase, and tapping it on mobile used to do literally nothing.
const String kEntryCtaLabelWeb = 'Buy leaderboard entry · ₦500';
const String kEntryCtaLabelExternal = 'Get entry on the website';

/// Shown when a mobile player taps the website CTA, so the hand-off to an
/// external browser is never a dead end.
const String kEntryCtaExternalHint =
    'Leaderboard entries are bought on our website. You will get a one-time '
    'code to redeem under Profile → Redeem Code.';

/// Support / privacy contact address.
///
/// This is the single source of truth for BOTH the in-app "delete my account"
/// mail route and the Contact sections of the hosted privacy policy, terms and
/// refund pages. Keep them in step: if this changes, the [PRIVACY EMAIL] and
/// [SUPPORT EMAIL] placeholders in public/privacy.html, public/terms.html and
/// public/refund.html must change with it. They were shipped as unfilled
/// placeholders once already, which left the live policy with no way to contact
/// anyone — do not let that regress.
const String kSupportEmail = 'animequizzm@gmail.com';

/// Hosted "No Refunds Policy". Every paid item is final sale; see
/// public/refund.html for the full text and the single billing-error carve-out.
const String kNoRefundsPolicyUrl = '$kShopUrl/refund.html';

/// The one-line no-refund notice shown on every in-app purchase surface.
///
/// This is the single source of truth for that copy. Keep it short, blunt and
/// identical everywhere — a soft or inconsistent notice defeats the point of the
/// policy, because the hosted page at [kNoRefundsPolicyUrl] only helps if the
/// user believes it when they tap Buy.
///
/// Note it covers *purchases* only. It must never be shown next to the in-game
/// stake refunds on expired multiplayer challenges, which are real credit
/// movements between players, not refunds of money paid to us.
const String kNoRefundsNotice =
    'All purchases are final sale. No refunds — not if you change your mind, '
    'not if the code is unused or unclaimed.';

/// Pre-filled mailto for a data-deletion request from a signed-out user.
///
/// A signed-in user is sent through the in-app deletion flow instead (no email
/// round-trip needed). This route exists for the Android "Update required"
/// wall, where a user stuck on an outdated build may not be able to sign in and
/// therefore cannot self-serve in-app.
const String kDeleteRequestMailtoUrl =
    'mailto:$kSupportEmail'
    '?subject=AnimeQuiz%20%E2%80%93%20Account%20deletion%20request'
    '&body=Please%20delete%20my%20AnimeQuiz%20account.%0A%0A'
    'Registered%20email%3A%0A%0A%0A(I%20understand%20all%20of%20my%20account%20data%20'
    'will%20be%20permanently%20deleted%2C%20and%20that%20records%20we%20are%20legally%20'
    'required%20to%20retain%20will%20be%20kept%20with%20my%20personal%20details%20removed.)';

/// Hosted privacy policy, linked from the update wall for a signed-out user so
/// the data-deletion route is discoverable even when email is not configured.
const String kPrivacyPolicyUrl = '$kShopUrl/privacy.html';
