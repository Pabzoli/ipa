// ─── Centralised icon set ──────────────────────────────────────────────────
// Use Material Icons exclusively. All emoji symbols (🪙, ⚔️, etc.) are
// replaced with their Material equivalent. This ensures consistent rendering,
// accessibility (semantics), and theming across the app.
//
// Mapping:
//   🪙 → Icons.monetization_on_rounded
//   ⚔️ → Icons.sports_esports_rounded or Icons.swords_rounded (if available)
//   🎯 → Icons.track_changes_rounded
//   🏆 → Icons.emoji_events_rounded
//   👑 → Icons.crown_rounded (use Icons.star_rounded as fallback)
//   etc.

// No code required – this file serves as a contract.
// All widgets should import 'package:flutter/material.dart' and use Icons.* directly.
// For custom icon widgets, use Icon(Icons.xxx, ...).