// lib/core/constants/rivalries_paging.dart
//
// Paging shape for the Rivalries list. One rival page is N rivals, and the
// service scans a growing window of the player's recent matches to fill it
// (repeat matches against one rival collapse into a single row, so a raw match
// count is not a rival count).
//
// Display/read-cost constants only — nothing here is mirrored in
// functions/index.js.

/// Rivals revealed per page and per "Show more" tap.
const int kRivalriesPageSize = 10;

/// Hard cap on how many recent matches the list will scan to fill a page.
/// Bounds the read cost against a long history of repeat matches.
const int kRivalriesMaxWindow = 200;
