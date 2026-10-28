// ── Anime catalogue (bundled fallback) ─────────────────────────────────────
// The full list lives ONLY on the server: app_config/anime_catalog is denied
// to clients in firestore.rules (functions/index.js mirrors it as
// ANIME_CATALOG_FALLBACK). Clients render just the server-rotated 9 from
// app_config/featured_rotation. This constant is the offline fallback for
// that shelf. Titles are lowercase and each needs a poster in assets/ for
// its tile art.

const List<String> kAnimeCatalog = [
  'attack on titan',
  'berserk',
  'black clover',
  'bleach',
  'blue lock',
  'chainsaw man',
  'classroom of the elite',
  'death note',
  'demon slayer',
  'dragon ball z',
  'dr stone',
  'fairy tail',
  'fire force',
  'hell\'s paradise',
  'hunter x hunter',
  'jojo\'s bizarre adventure',
  'jujutsu kaisen',
  'kuroko\'s basketball',
  'mushoku tensei',
  'my hero academia',
  'naruto',
  'one piece',
  'one punch man',
  're zero',
  'solo leveling',
  'sword art online',
  'that time i got reincarnated as a slime',
  'tokyo ghoul',
  'tokyo revengers',
  'tower of god',
  'vinland saga',
  'wind breaker',
];
