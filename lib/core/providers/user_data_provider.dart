import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/firestore_service.dart';

class UserDataProvider extends ChangeNotifier {
  // ── Defaults are 0, NOT fake numbers.
  // The stream will replace these with real Firestore values as soon as
  // the user is authenticated and online. Using 500/5 as defaults was the
  // root cause of the "score frozen at 500" bug.
  int  _score               = 0;
  int  _hints               = 0;
  int  _weeklyPoints        = 0;
  bool _loading             = true;
  bool _isOnline            = false;
  bool _connectivityChecked = false;

  int  get score                => _score;
  int  get hints                => _hints;
  int  get weeklyPoints         => _weeklyPoints;
  bool get loading              => _loading;
  bool get isOnline             => _isOnline;
  bool get connectivityChecked  => _connectivityChecked;

  StreamSubscription<List<ConnectivityResult>>? _connectSub;
  StreamSubscription<User?>?                    _authSub;   // NEW
  StreamSubscription<int>?                      _scoreSub;
  StreamSubscription<int>?                      _hintSub;
  StreamSubscription<int>?                      _weeklyPointsSub;

  void init() {
    // ── 1. Connectivity: one-shot + live changes ─────────────────────────────
    Connectivity().checkConnectivity()
    .timeout(
      const Duration(seconds: 4),
      onTimeout: () => [ConnectivityResult.wifi], // assume online if it hangs
    )
    .then((results) {
      _isOnline            = _hasConnection(results);
      _connectivityChecked = true;
      notifyListeners();
    });

    _connectSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = _hasConnection(results);
      if (online != _isOnline) {
        _isOnline = online;
        notifyListeners();
        // Only restart streams when we come back online AND a user is signed in
        if (online && FirebaseAuth.instance.currentUser != null) {
          _startFirestoreStreams();
        }
      }
    });

    // ── 2. Auth state listener — the core fix ────────────────────────────────
    // This fires immediately with the current user (or null), and again
    // whenever the user signs in or out. It replaces the old one-time
    // _startFirestoreStreams() call that never re-ran on account switches.
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        // User signed out → kill streams and wipe local state so the next
        // user never sees stale data (fixes the "previous account hints" bug)
        _cancelFirestoreStreams();
        _resetLocalState();
        notifyListeners();
      } else {
        // User signed in (or app started with an existing session) →
        // start fresh streams for this UID
        _startFirestoreStreams();
      }
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  bool _hasConnection(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  /// Wipes in-memory state to 0. Called on sign-out so the next user
  /// never sees a previous user's score/hints on the home screen.
  void _resetLocalState() {
    _score        = 0;
    _hints        = 0;
    _weeklyPoints = 0;
    _loading      = true;
  }

  void _cancelFirestoreStreams() {
    _scoreSub?.cancel();        _scoreSub        = null;
    _hintSub?.cancel();         _hintSub         = null;
    _weeklyPointsSub?.cancel(); _weeklyPointsSub = null;
  }

  void _startFirestoreStreams() {
    // Always cancel before re-subscribing to avoid duplicate listeners
    _cancelFirestoreStreams();

    _scoreSub = FirestoreService.instance.scoreStream().listen(
      (s) {
        _score   = s;
        _loading = false;
        notifyListeners();
      },
      onError: (_) {
        _loading = false;
        notifyListeners();
      },
    );

    _hintSub = FirestoreService.instance.hintStream().listen(
      (h) {
        _hints = h;
        notifyListeners();
      },
    );

    _weeklyPointsSub = FirestoreService.instance.weeklyPointsStream().listen(
      (wp) {
        _weeklyPoints = wp;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _connectSub?.cancel();
    _authSub?.cancel();         // NEW — always clean up the auth listener
    _cancelFirestoreStreams();
    super.dispose();
  }

  // ── Public API ───────────────────────────────────────────────────────────────
  // These methods write to Firestore; the live streams above automatically
  // reflect the change in the UI, so no manual setState is needed here.

  Future<void> addScore(int amount) async {
    await FirestoreService.instance.addToScore(amount);
  }

  Future<void> subtractScore(int amount) async {
    await FirestoreService.instance.subtractFromScore(amount);
  }

  Future<void> addWeeklyPoints(int amount) async {
    await FirestoreService.instance.addWeeklyPoints(amount);
  }

  Future<void> deductHint() async {
    if (_hints <= 0) return;
    await FirestoreService.instance.deductHint();
  }

  Future<void> addHint() async {
    await FirestoreService.instance.addHint();
  }
}