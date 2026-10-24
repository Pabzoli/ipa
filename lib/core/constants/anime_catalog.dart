// ── Anime catalogue (bundled fallback) ─────────────────────────────────────
// The live list is app_config/anime_catalog.titles in Firestore: the home grid
// streams it and functions/index.js validates against it (ANIME_CATALOG_FALLBACK
// there mirrors this list). This constant is only used until that doc exists.
// Titles are lowercase and each needs a poster in assets/ for its tile art.

const List<String> kAnimeCatalog = [
  'attack on titan',
  'demon slayer',
  'jujutsu kaisen',
  'naruto',
  'one piece',
  'one punch man',
  'bleach',
  'dragon ball z',
  'my hero academia',
  'death note',
];
