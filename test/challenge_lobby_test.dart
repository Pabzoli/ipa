import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:quiz/core/providers/user_data_provider.dart';
import 'package:quiz/core/theme/app_theme.dart';
import 'package:quiz/features/multiplayer/challenge_lobby_page.dart';
import 'package:quiz/features/multiplayer/challenge_model.dart';

// UserDataProvider starts Connectivity and Firestore listeners from its
// constructor, which cannot run under flutter_test. The lobby only reads two
// balances, so the fake skips init() and reports fixed values.
class _FakeUserData extends UserDataProvider {
  _FakeUserData({required this.animeCoins, required this.weeklyPoints});

  @override
  void init() {}

  @override
  final int animeCoins;

  @override
  final int weeklyPoints;
}

ChallengeModel _challenge({
  ChallengeStatus status = ChallengeStatus.waiting,
  String challengeType = 'rival',
  String? opponentUid = 'u2',
  String? opponentUsername,
  int stake = 50,
  int? wpStake = 20,
  int? creatorScore,
  int? opponentScore,
}) {
  final now = DateTime.now();
  return ChallengeModel(
    challengeId: 'abc123',
    creatorUid: 'u1',
    creatorUsername: 'Ayo',
    opponentUid: opponentUid,
    opponentUsername: opponentUsername,
    stakeAmount: stake,
    wpStake: wpStake,
    animeTitle: 'Naruto',
    questionIds: const ['q1', 'q2'],
    creatorScore: creatorScore,
    opponentScore: opponentScore,
    status: status,
    createdAt: now.subtract(const Duration(hours: 1)),
    expiresAt: now.add(const Duration(hours: 20)),
    challengeType: challengeType,
  );
}

Widget _wrap({
  required ChallengeModel challenge,
  required String uid,
  int animeCoins = 1000,
  int weeklyPoints = 1000,
}) {
  return ChangeNotifierProvider<UserDataProvider>.value(
    value: _FakeUserData(animeCoins: animeCoins, weeklyPoints: weeklyPoints),
    child: MaterialApp(
      home: ScreenUtilInit(
        designSize: const Size(390, 844),
        child: Scaffold(
          body: ChallengeLobbyContent(challenge: challenge, currentUid: uid),
        ),
      ),
    ),
  );
}

Future<void> _pumpLobby(
  WidgetTester tester, {
  required ChallengeModel challenge,
  required String uid,
  int animeCoins = 1000,
  int weeklyPoints = 1000,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_wrap(
    challenge: challenge,
    uid: uid,
    animeCoins: animeCoins,
    weeklyPoints: weeklyPoints,
  ));
  // Not pumpAndSettle: the waiting note spins a progress indicator forever.
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  // flutter_test falls back to Ahem, whose glyphs are square, so text would
  // wrap and overflow in ways a phone never does. Load the app's real font.
  setUpAll(() async {
    final loader = FontLoader(AppTypography.fontFamily);
    for (final weight in [
      'Regular',
      'SemiBold',
      'Bold',
      'ExtraBold',
      'Black'
    ]) {
      loader.addFont(rootBundle.load('assets/fonts/Nunito-$weight.ttf'));
    }
    await loader.load();
  });

  testWidgets('leads with the match, not a title block', (tester) async {
    await _pumpLobby(tester, challenge: _challenge(), uid: 'u2');

    expect(find.text('Naruto'), findsNothing);
    expect(find.text('⚔️ Rival Challenge'), findsNothing);
    expect(find.text('Stake'), findsOneWidget);
    expect(find.text('50 AC + 20 WP'), findsOneWidget);
    expect(find.text('Time left'), findsOneWidget);
    expect(find.text('Created by'), findsNothing);
    expect(find.text('Opponent'), findsNothing);
  });

  testWidgets('invited opponent can accept or decline a pending duel',
      (tester) async {
    await _pumpLobby(tester, challenge: _challenge(), uid: 'u2');

    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('⚔️ Accept & Play'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
  });

  testWidgets('accept is blocked with a notice when the stake is unaffordable',
      (tester) async {
    await _pumpLobby(
      tester,
      challenge: _challenge(),
      uid: 'u2',
      animeCoins: 0,
      weeklyPoints: 1000,
    );

    expect(
        find.text('You need 50 AC to accept this challenge.'), findsOneWidget);

    await tester.tap(find.text('⚔️ Accept & Play'));
    await tester.pump();

    expect(find.text('Insufficient balance for this stake.'), findsOneWidget);
  });

  testWidgets('decline asks first and Cancel leaves the challenge alone',
      (tester) async {
    await _pumpLobby(tester, challenge: _challenge(), uid: 'u2');

    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();

    expect(find.text('Decline challenge?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Decline challenge?'), findsNothing);
    expect(find.text('⚔️ Accept & Play'), findsOneWidget);
  });

  testWidgets('creator of a code challenge sees the code to share',
      (tester) async {
    await _pumpLobby(
      tester,
      challenge: _challenge(
        challengeType: 'code',
        opponentUid: null,
        stake: 0,
        wpStake: null,
      ),
      uid: 'u1',
    );

    expect(find.text('Waiting for opponent to join…'), findsOneWidget);
    expect(find.text('Challenge code'), findsOneWidget);
    expect(find.text('abc123'), findsOneWidget);
    expect(find.text('Tap to copy'), findsOneWidget);
    expect(find.text('Accept & Play'), findsNothing);
  });

  testWidgets('tapping the code copies it to the clipboard', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpLobby(
      tester,
      challenge: _challenge(
        challengeType: 'code',
        opponentUid: null,
        stake: 0,
        wpStake: null,
      ),
      uid: 'u1',
    );

    await tester.tap(find.text('Tap to copy'));
    await tester.pump();

    expect(copied, 'abc123');
  });

  testWidgets('creator is prompted to play once the opponent has joined',
      (tester) async {
    await _pumpLobby(
      tester,
      challenge: _challenge(
        status: ChallengeStatus.opponentJoined,
        opponentUsername: 'Kira',
      ),
      uid: 'u1',
    );

    expect(find.text('Opponent joined — Ready to play'), findsOneWidget);
    expect(find.text('⚡ Play Now'), findsOneWidget);
    expect(find.text('Kira'), findsWidgets);
  });

  testWidgets('opponent cannot see the creator score before playing',
      (tester) async {
    await _pumpLobby(
      tester,
      challenge: _challenge(
        status: ChallengeStatus.creatorSubmitted,
        opponentUsername: 'Kira',
        creatorScore: 7,
      ),
      uid: 'u2',
    );

    expect(find.text('🔒'), findsOneWidget);
    expect(find.text('7'), findsNothing);
    expect(find.text('Creator played — Your turn!'), findsOneWidget);
  });

  testWidgets('player who finished waits and can nudge the opponent',
      (tester) async {
    await _pumpLobby(
      tester,
      challenge: _challenge(
        status: ChallengeStatus.creatorSubmitted,
        opponentUsername: 'Kira',
        creatorScore: 6,
      ),
      uid: 'u1',
    );

    expect(find.text('Waiting for opponent to play…'), findsOneWidget);
    expect(find.text('Nudge'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
  });

  testWidgets('layout fits a small phone without overflow', (tester) async {
    await _pumpLobby(
      tester,
      challenge: _challenge(opponentUsername: 'A Very Long Opponent Name'),
      uid: 'u2',
      animeCoins: 0,
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
  });
}
