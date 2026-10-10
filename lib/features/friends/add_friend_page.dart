// lib/features/friends/add_friend_page.dart
//
// Add Friend screen: the only place friendships are created.
//
// Sections: your code (Copy/Share) · enter a code · players from your campus
// (campusRivals suggestions, excluding anyone you already have a link with) ·
// outgoing · incoming (Accept/Decline) · blocked (Unblock).
//
// No username search (locked decision): code entry + campus suggestions only.
// All writes go through friend callables. No listeners: one-shot futures +
// pull-to-refresh.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';

class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key});

  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

class _AddFriendPageState extends State<AddFriendPage> {
  Future<String>? _codeFuture;
  Future<_AddFriendData>? _dataFuture;
  final TextEditingController _codeCtrl = TextEditingController();
  bool _sending = false;
  String? _codeError;
  final Set<String> _busyUids = {};

  @override
  void initState() {
    super.initState();
    _codeFuture = FirestoreService.instance.getMyFriendCode();
    _dataFuture = _load();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<_AddFriendData> _load() async {
    final service = FirestoreService.instance;
    final results = await Future.wait([
      service.getFriendLinkIds(),
      service.getFriendLinksByStatus('incoming'),
      service.getFriendLinksByStatus('outgoing'),
      service.getFriendLinksByStatus('blocked'),
      _loadCampusSuggestions(),
    ]);
    return _AddFriendData(
      linkIds: results[0] as Set<String>,
      incoming: results[1] as List<Map<String, dynamic>>,
      outgoing: results[2] as List<Map<String, dynamic>>,
      blocked: results[3] as List<Map<String, dynamic>>,
      suggestions: results[4] as List<RivalCandidate>?,
    );
  }

  Future<List<RivalCandidate>?> _loadCampusSuggestions() async {
    try {
      final me = FirestoreService.instance.currentUid;
      if (me == null) return [];
      final uni =
          await FirestoreService.instance.getCurrentUserUniversity();
      if (uni == null || uni.isEmpty) return null;
      // Entry week gates visibility (same cohort rule as the board).
      final week = FirestoreService.currentWeekId();
      return FirestoreService.instance.campusRivals(
        university: uni,
        weekId: week,
      );
    } catch (_) {
      return [];
    }
  }

  Future<void> _reload() async {
    setState(() {
      _codeFuture = FirestoreService.instance.getMyFriendCode();
      _dataFuture = _load();
    });
    try {
      await Future.wait([_codeFuture!, _dataFuture!]);
    } catch (_) {
      // Rendered by the FutureBuilders below.
    }
  }

  String _friendlyRequestError(String raw) {
    final s = raw.replaceFirst('Exception: ', '').trim();
    return switch (s) {
      'not_found' => 'No player found with that code.',
      'inbox_full' =>
        'They can\'t accept more requests right now. Try again later.',
      'request_limit_reached' =>
        'Daily request limit reached — max 10 new requests per day.',
      'too_many_attempts' =>
        'Too many wrong codes today — try again tomorrow.',
      'already_friends' => 'You are already friends.',
      'already_pending' => 'A request is already pending.',
      'cannot_friend_yourself' => 'That\'s your own code!',
      _ => s.isEmpty ? 'Something went wrong. Please try again.' : s,
    };
  }

  Future<void> _sendByCode() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6 || _sending) return;
    setState(() {
      _sending = true;
      _codeError = null;
    });
    try {
      await FirestoreService.instance.sendFriendRequest(code: code);
      if (!mounted) return;
      _codeCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Friend request sent!'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
      _reload();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _codeError = _friendlyRequestError(e.message ?? e.code);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _codeError = _friendlyRequestError(e.toString());
      });
    } finally {
      if (mounted && _sending) setState(() => _sending = false);
    }
  }

  Future<void> _runFor(
    String uid,
    Future<void> Function() action,
    String done,
  ) async {
    if (_busyUids.contains(uid)) return;
    setState(() => _busyUids.add(uid));
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(done),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
      _reload();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyRequestError(e.message ?? e.code)),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyRequestError(e.toString())),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyUids.remove(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDim,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Add Friend',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: AppColors.surface,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20.r, 8.r, 20.r, 32.r),
          children: [
            _SectionCard(
              title: 'Your code',
              child: FutureBuilder<String>(
                future: _codeFuture,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      ),
                    );
                  }
                  final code = snap.data ?? '';
                  if (code.isEmpty) {
                    return Text(
                      'Could not load your code. Pull to retry.',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 12.sp),
                    );
                  }
                  return Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 14.r, vertical: 12.r),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceDim
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12.r),
                            border:
                                Border.all(color: AppColors.divider),
                          ),
                          child: Text(
                            code,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 20.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 4,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: 8.w),
                      IconButton(
                        tooltip: 'Copy',
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Code copied!'),
                              behavior: SnackBarBehavior.floating,
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded,
                            color: AppColors.textMuted),
                      ),
                      IconButton(
                        tooltip: 'Share',
                        onPressed: () => Share.share(
                            'Add me on AnimeQuiz! My friend code is $code'),
                        icon: const Icon(Icons.share_rounded,
                            color: AppColors.textMuted),
                      ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(height: 14.h),
            _SectionCard(
              title: 'Enter a code',
              child: Column(
                children: [
                  TextField(
                    controller: _codeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 6,
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: 'ABC123',
                      errorText: _codeError,
                      filled: true,
                      fillColor:
                          AppColors.surfaceDim.withValues(alpha: 0.6),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12.r),
                        borderSide:
                            const BorderSide(color: AppColors.divider),
                      ),
                    ),
                    onSubmitted: (_) => _sendByCode(),
                  ),
                  SizedBox(height: 10.h),
                  SizedBox(
                    width: double.infinity,
                    height: 46.h,
                    child: ElevatedButton(
                      onPressed: _sending ? null : _sendByCode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.r),
                        ),
                      ),
                      child: Text(_sending ? 'Sending…' : 'Send request'),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 14.h),
            FutureBuilder<_AddFriendData>(
              future: _dataFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: CircularProgressIndicator(
                          color: AppColors.primary),
                    ),
                  );
                }
                if (snap.hasError || !snap.hasData) {
                  return _SectionCard(
                    title: 'Players from your campus',
                    child: Text(
                      'Could not load suggestions. Pull to retry.',
                      style: TextStyle(
                          color: AppColors.textMuted, fontSize: 12.sp),
                    ),
                  );
                }
                final data = snap.data!;
                final suggestions = (data.suggestions ?? [])
                    .where((r) =>
                        !data.linkIds.contains(r.uid) &&
                        r.uid !=
                            FirestoreService.instance.currentUid)
                    .toList();
                return Column(
                  children: [
                    _SectionCard(
                      title: 'Players from your campus',
                      child: data.suggestions == null
                          ? Text(
                              'Set your campus and join the weekly board to '
                              'see campus players.',
                              style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12.sp,
                                  height: 1.5),
                            )
                          : suggestions.isEmpty
                              ? Text(
                                  'Nobody new from your campus right now.',
                                  style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 12.sp),
                                )
                              : Column(
                                  children: [
                                    for (final r in suggestions)
                                      _PersonRow(
                                        name: r.username,
                                        detail:
                                            '${r.weeklyPoints} WP this week',
                                        busy: _busyUids.contains(r.uid),
                                        actionLabel: 'Add',
                                        onAction: () => _runFor(
                                          r.uid,
                                          () => FirestoreService.instance
                                              .sendFriendRequest(uid: r.uid),
                                          'Friend request sent!',
                                        ),
                                      ),
                                  ],
                                ),
                    ),
                    SizedBox(height: 14.h),
                    _SectionCard(
                      title: 'Incoming (${data.incoming.length})',
                      child: data.incoming.isEmpty
                          ? Text('No incoming requests.',
                              style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12.sp))
                          : Column(
                              children: [
                                for (final p in data.incoming)
                                  _PersonRow(
                                    name: _linkName(p),
                                    detail: 'Wants to be friends',
                                    busy: _busyUids
                                        .contains(_linkUid(p)),
                                    actionLabel: 'Accept',
                                    secondActionLabel: 'Decline',
                                    onAction: () => _runFor(
                                      _linkUid(p),
                                      () => FirestoreService.instance
                                          .respondFriendRequest(
                                              otherUid: _linkUid(p),
                                              accept: true),
                                      'You are now friends!',
                                    ),
                                    onSecondAction: () => _runFor(
                                      _linkUid(p),
                                      () => FirestoreService.instance
                                          .respondFriendRequest(
                                              otherUid: _linkUid(p),
                                              accept: false),
                                      'Request declined.',
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    SizedBox(height: 14.h),
                    _SectionCard(
                      title: 'Outgoing (${data.outgoing.length})',
                      child: data.outgoing.isEmpty
                          ? Text('No outgoing requests.',
                              style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12.sp))
                          : Column(
                              children: [
                                for (final p in data.outgoing)
                                  _PersonRow(
                                    name: _linkName(p),
                                    detail: 'Request sent',
                                    busy: _busyUids
                                        .contains(_linkUid(p)),
                                    actionLabel: 'Cancel',
                                    onAction: () => _runFor(
                                      _linkUid(p),
                                      () => FirestoreService.instance
                                          .cancelFriendRequest(
                                              otherUid: _linkUid(p)),
                                      'Request cancelled.',
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    SizedBox(height: 14.h),
                    _SectionCard(
                      title: 'Blocked (${data.blocked.length})',
                      child: data.blocked.isEmpty
                          ? Text('Nobody blocked.',
                              style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12.sp))
                          : Column(
                              children: [
                                for (final p in data.blocked)
                                  _PersonRow(
                                    name: 'Blocked user',
                                    detail: 'Unblock to start over',
                                    busy: _busyUids
                                        .contains(_linkUid(p)),
                                    actionLabel: 'Unblock',
                                    onAction: () => _runFor(
                                      _linkUid(p),
                                      () => FirestoreService.instance
                                          .unblockUser(
                                              otherUid: _linkUid(p)),
                                      'Unblocked. They must send a new request.',
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _linkUid(Map<String, dynamic> p) =>
      (p['uid'] as String?) ?? '';
  static String _linkName(Map<String, dynamic> p) =>
      (p['username'] as String?)?.isNotEmpty == true
          ? (p['username'] as String)
          : 'Player';
}

class _AddFriendData {
  final Set<String> linkIds;
  final List<Map<String, dynamic>> incoming;
  final List<Map<String, dynamic>> outgoing;
  final List<Map<String, dynamic>> blocked;
  final List<RivalCandidate>? suggestions;

  const _AddFriendData({
    required this.linkIds,
    required this.incoming,
    required this.outgoing,
    required this.blocked,
    required this.suggestions,
  });
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18.r),
        border: Border.all(color: AppColors.divider.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w800)),
          SizedBox(height: 10.h),
          child,
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final String name;
  final String detail;
  final bool busy;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondActionLabel;
  final VoidCallback? onSecondAction;

  const _PersonRow({
    required this.name,
    required this.detail,
    required this.busy,
    required this.actionLabel,
    required this.onAction,
    this.secondActionLabel,
    this.onSecondAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 8.h),
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 38.w,
            height: 38.h,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 17.sp,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 8.w),
          if (secondActionLabel != null) ...[
            GestureDetector(
              onTap: busy ? null : onSecondAction,
              child: Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 10.r, vertical: 8.r),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(
                      color: AppColors.textMuted.withValues(alpha: 0.4)),
                ),
                child: Text(
                  secondActionLabel!,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            SizedBox(width: 6.w),
          ],
          GestureDetector(
            onTap: busy ? null : onAction,
            child: Container(
              padding:
                  EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                busy ? '…' : actionLabel,
                style: TextStyle(
                  color: AppColors.primary,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
