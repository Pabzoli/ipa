// ── Gauntlet economy (deprecated) ────────────────────────────────────────────
// The Daily Gauntlet is now Gauntlet Blitz (90s time-attack, no streak).
// This file only keeps the old identifiers so existing imports keep
// compiling; all values live in blitz_economy.dart. Do not add new uses —
// import blitz_economy.dart directly.
export 'blitz_economy.dart';

import 'blitz_economy.dart';

/// No milestones exist anymore. Kept (empty) so old iteration code
/// compiles; every loop over it simply does nothing.
@Deprecated('Blitz has no streak milestones')
const Map<int, String> kGauntletMilestones = <int, String>{};

/// Old positional tiers, removed with the 7-question format.
@Deprecated('Use kBlitzWpByDifficulty')
const List<int> kGauntletTiersShim = <int>[];

@Deprecated('Use kBlitzMaxRetries')
const int kGauntletMaxRetries = kBlitzMaxRetries;

@Deprecated('Use kBlitzRetryCostFree')
const List<int> kGauntletRetryCostFree = kBlitzRetryCostFree;

@Deprecated('Use kBlitzRetryCostPremium')
const List<int> kGauntletRetryCostPremium = kBlitzRetryCostPremium;

@Deprecated('Use blitzRetryCost')
int? gauntletRetryCost({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) =>
    blitzRetryCost(
      retryIndex: retryIndex,
      isPremium: isPremium,
      isFreeAttempt: isFreeAttempt,
    );

@Deprecated('Use blitzRetryLabel')
String gauntletRetryLabel({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) =>
    blitzRetryLabel(
      retryIndex: retryIndex,
      isPremium: isPremium,
      isFreeAttempt: isFreeAttempt,
    );

@Deprecated('Use blitzRetryButtonLabel')
String gauntletRetryButtonLabel({
  required int retryIndex,
  required bool isPremium,
  required bool isFreeAttempt,
}) =>
    blitzRetryButtonLabel(
      retryIndex: retryIndex,
      isPremium: isPremium,
      isFreeAttempt: isFreeAttempt,
    );

@Deprecated('Use effectiveBlitzRetryIndex')
int effectiveGauntletRetryIndex({
  required int storedIndex,
  required String storedDate,
  required String todayWAT,
}) =>
    effectiveBlitzRetryIndex(
      storedIndex: storedIndex,
      storedDate: storedDate,
      todayWAT: todayWAT,
    );

@Deprecated('Use blitzTodayWAT')
String gauntletTodayWAT() => blitzTodayWAT();
