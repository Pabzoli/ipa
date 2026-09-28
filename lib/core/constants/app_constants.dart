/// Single source of truth for the shop URL (mirrors HOSTING_BASE in
/// functions/index.js). Referenced from app UI as plain, non-interactive text
/// only — never as a tappable/launchable link.
const String kShopUrl = 'https://anime-quiz-1ab1b.web.app';

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
