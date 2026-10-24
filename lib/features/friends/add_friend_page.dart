// lib/features/friends/add_friend_page.dart
//
// Add Friend screen: the only place friendships are created.
//
// Sections: your code (copy / share) · add by code · incoming (accept/decline)
// · outgoing (cancel) · players from your campus · blocked (unblock).
//
// No username search (locked decision): code entry + campus suggestions only.
// All writes go through friend callables. No listeners: one-shot futures +
// pull-to-refresh.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/share_links.dart';
import '../../core/services/firestore_service.dart';
import '../../core/services/share_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/weekly_points_pill.dart';
import 'friend_messages.dart';
import 'friend_widgets.dart';

class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key});

  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

enum _CampusState { noCampus, loaded, failed }

class _AddFriendData {
  final List<FriendLink> incoming;
  final List<FriendLink> outgoing;
  final List<FriendLink> blocked;
  final List<RivalCandidate> suggestions;
  final _CampusState campus;

  const _AddFriendData({
    required this.incoming,
    required this.outgoing,
    required this.blocked,
    required this.suggestions,
    required this.campus,
  });
}

class _AddFriendPageState extends State<AddFriendPage> {
  Future<String>? _codeFuture;
  Future<_AddFriendData>? _dataFuture;
  String _code = '';
  final TextEditingController _codeCtrl = TextEditingController();
  bool _sending = false;
  String? _codeError;
  final Set<String> _busyUids = {};

  @override
  void initState() {
    super.initState();
    _codeFuture = _loadCode();
    _dataFuture = _load();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  /// The code never changes once minted, so it is fetched again only while we
  /// still don't have one.
  Future<String> _loadCode() async {
    try {
      _code = await FirestoreService.instance.getMyFriendCode();
    } catch (_) {
      _code = '';
    }
    return _code;
  }

  Future<_AddFriendData> _load() async {
    final service = FirestoreService.instance;
    final links = await service.getFriendLinks();
    final linked = {for (final l in links) l.uid};
    var campus = _CampusState.noCampus;
    var suggestions = <RivalCandidate>[];
    try {
      final uni = await service.getCurrentUserUniversity();
      if (uni != null && uni.isNotEmpty) {
        final raw = await service.campusRivals(
          university: uni,
          weekId: FirestoreService.currentWeekId(),
          limit: 60,
        );
        // Filter after the read so already-linked players don't eat the list.
        suggestions = raw
            .where((r) => !linked.contains(r.uid) && r.uid != service.currentUid)
            .take(12)
            .toList();
        campus = _CampusState.loaded;
      }
    } catch (_) {
      campus = _CampusState.failed;
    }
    return _AddFriendData(
      incoming: links.where((l) => l.status == 'incoming').toList(),
      outgoing: links.where((l) => l.status == 'outgoing').toList(),
      blocked: links.where((l) => l.status == 'blocked').toList(),
      suggestions: suggestions,
      campus: campus,
    );
  }

  Future<void> _reload() async {
    setState(() {
      if (_code.isEmpty) _codeFuture = _loadCode();
      _dataFuture = _load();
    });
    final code = _codeFuture;
    final data = _dataFuture;
    try {
      await Future.wait<Object?>([
        if (code != null) code,
        if (data != null) data,
      ]);
    } catch (_) {
      // Rendered by the FutureBuilders below.
    }
  }

  void _toast(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? AppColors.wrong : null,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 2 : 1),
      ),
    );
  }

  Future<void> _sendByCode() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6 || _sending) return;
    setState(() {
      _sending = true;
      _codeError = null;
    });
    try {
      final status =
          await FirestoreService.instance.sendFriendRequest(code: code);
      if (!mounted) return;
      _codeCtrl.clear();
      setState(() => _sending = false);
      _toast(status == 'active' ? 'You are now friends!' : 'Friend request sent!');
      _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _codeError = friendErrorFrom(e);
      });
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
      _toast(done);
      _reload();
    } catch (e) {
      if (!mounted) return;
      _toast(friendErrorFrom(e), error: true);
    } finally {
      if (mounted) setState(() => _busyUids.remove(uid));
    }
  }

  /// Campus Add: the server accepts on the spot when that player already asked
  /// us, so the message depends on the returned status.
  Future<void> _addFromCampus(String uid) async {
    if (_busyUids.contains(uid)) return;
    setState(() => _busyUids.add(uid));
    try {
      final status =
          await FirestoreService.instance.sendFriendRequest(uid: uid);
      if (!mounted) return;
      _toast(status == 'active' ? 'You are now friends!' : 'Friend request sent!');
      _reload();
    } catch (e) {
      if (!mounted) return;
      _toast(friendErrorFrom(e), error: true);
    } finally {
      if (mounted) setState(() => _busyUids.remove(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Add friend', style: AppTypography.heading3),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: AppSpacing.md),
            child: const WeeklyPointsPill(),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor: AppColors.surface,
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.sm,
            AppSpacing.page,
            AppSpacing.xxl,
          ),
          children: [
            _codeCard(),
            SizedBox(height: AppSpacing.lg),
            _addByCodeCard(),
            SizedBox(height: AppSpacing.xl),
            FutureBuilder<_AddFriendData>(
              future: _dataFuture,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    ),
                  );
                }
                if (snap.hasError || !snap.hasData) {
                  return FriendInlineNote(
                    'Could not load your friends. Pull down to retry.',
                  );
                }
                return _sections(snap.data!);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _codeCard() {
    return AppCard(
      tier: AppCardTier.elevated,
      padding: EdgeInsets.all(AppSpacing.lg),
      gradient: const LinearGradient(
        colors: AppColors.cardGradient,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderColor: AppColors.primaryBorder,
      child: FutureBuilder<String>(
        future: _codeFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return SizedBox(
              height: 72.r,
              child: const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.primary,
                ),
              ),
            );
          }
          final code = snap.data ?? '';
          if (code.isEmpty) {
            return Column(
              children: [
                Text(
                  'Could not load your code.',
                  style: AppTypography.bodyMedium,
                ),
                SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: 'Try again',
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.small,
                  onPressed: _reload,
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'YOUR FRIEND CODE',
                textAlign: TextAlign.center,
                style: AppTypography.labelSmall.copyWith(
                  color: AppColors.textSecondary,
                  letterSpacing: 1.4,
                ),
              ),
              SizedBox(height: AppSpacing.sm),
              Text(
                code,
                textAlign: TextAlign.center,
                style: AppTypography.heading1.copyWith(
                  letterSpacing: 8,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: AppSpacing.xs),
              Text(
                'Share it so friends can add you.',
                textAlign: TextAlign.center,
                style: AppTypography.bodySmall,
              ),
              SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Copy',
                      variant: AppButtonVariant.outline,
                      size: AppButtonSize.small,
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      onPressed: () => ShareService.instance.copyText(
                        context,
                        code,
                        message: 'Code copied!',
                      ),
                    ),
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      label: 'Share',
                      variant: AppButtonVariant.outline,
                      size: AppButtonSize.small,
                      icon: const Icon(Icons.share_rounded, size: 16),
                      onPressed: () => ShareService.instance.shareText(
                        context,
                        text: friendCodeShareMessage(code),
                        subject: 'Add me on AnimeQuiz',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _addByCodeCard() {
    return AppCard(
      padding: EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add with a code', style: AppTypography.titleMedium),
          SizedBox(height: AppSpacing.xs),
          Text(
            'Referral codes go on the sign-up screen.',
            style: AppTypography.bodySmall,
          ),
          SizedBox(height: AppSpacing.md),
          TextField(
            controller: _codeCtrl,
            textCapitalization: TextCapitalization.characters,
            textAlign: TextAlign.center,
            maxLength: 6,
            style: AppTypography.titleMedium.copyWith(letterSpacing: 6),
            decoration: InputDecoration(
              counterText: '',
              hintText: 'ABC123',
              errorText: _codeError,
            ),
            onSubmitted: (_) => _sendByCode(),
          ),
          SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Send request',
            loading: _sending,
            onPressed: _sending ? null : _sendByCode,
          ),
        ],
      ),
    );
  }

  Widget _sections(_AddFriendData data) {
    final busy = _busyUids.contains;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FriendSectionTitle(title: 'Incoming', count: data.incoming.length),
        SizedBox(height: AppSpacing.sm),
        if (data.incoming.isEmpty)
          const FriendInlineNote('No requests waiting for you.')
        else
          for (final link in data.incoming)
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: FriendTile(
                name: _linkName(link),
                subtitle: 'Wants to be friends',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppButton(
                      label: 'Decline',
                      variant: AppButtonVariant.outline,
                      size: AppButtonSize.small,
                      onPressed: busy(link.uid)
                          ? null
                          : () => _runFor(
                                link.uid,
                                () => FirestoreService.instance
                                    .respondFriendRequest(
                                  otherUid: link.uid,
                                  accept: false,
                                ),
                                'Request declined.',
                              ),
                    ),
                    SizedBox(width: AppSpacing.xs),
                    AppButton(
                      label: 'Accept',
                      size: AppButtonSize.small,
                      loading: busy(link.uid),
                      onPressed: busy(link.uid)
                          ? null
                          : () => _runFor(
                                link.uid,
                                () => FirestoreService.instance
                                    .respondFriendRequest(
                                  otherUid: link.uid,
                                  accept: true,
                                ),
                                'You are now friends!',
                              ),
                    ),
                  ],
                ),
              ),
            ),
        SizedBox(height: AppSpacing.xl),
        FriendSectionTitle(title: 'Sent', count: data.outgoing.length),
        SizedBox(height: AppSpacing.sm),
        if (data.outgoing.isEmpty)
          const FriendInlineNote('No requests waiting on them.')
        else
          for (final link in data.outgoing)
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: FriendTile(
                name: _linkName(link),
                subtitle: 'Waiting for them to answer',
                trailing: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.outline,
                  size: AppButtonSize.small,
                  loading: busy(link.uid),
                  onPressed: busy(link.uid)
                      ? null
                      : () => _runFor(
                            link.uid,
                            () => FirestoreService.instance
                                .cancelFriendRequest(otherUid: link.uid),
                            'Request cancelled.',
                          ),
                ),
              ),
            ),
        SizedBox(height: AppSpacing.xl),
        FriendSectionTitle(
          title: 'From your campus',
          count: data.campus == _CampusState.loaded
              ? data.suggestions.length
              : null,
        ),
        SizedBox(height: AppSpacing.sm),
        ..._campusRows(data),
        SizedBox(height: AppSpacing.xl),
        FriendSectionTitle(title: 'Blocked', count: data.blocked.length),
        SizedBox(height: AppSpacing.sm),
        if (data.blocked.isEmpty)
          const FriendInlineNote('No one is blocked.')
        else
          for (final link in data.blocked)
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: FriendTile(
                name: 'Blocked player',
                subtitle: 'Unblock to let them send a new request',
                trailing: AppButton(
                  label: 'Unblock',
                  variant: AppButtonVariant.outline,
                  size: AppButtonSize.small,
                  loading: busy(link.uid),
                  onPressed: busy(link.uid)
                      ? null
                      : () => _runFor(
                            link.uid,
                            () => FirestoreService.instance
                                .unblockUser(otherUid: link.uid),
                            'Unblocked. They must send a new request.',
                          ),
                ),
              ),
            ),
      ],
    );
  }

  List<Widget> _campusRows(_AddFriendData data) {
    switch (data.campus) {
      case _CampusState.noCampus:
        return [
          const FriendInlineNote(
            'Set your campus and join the weekly board to see players here.',
          ),
        ];
      case _CampusState.failed:
        return [const FriendInlineNote('Could not load campus players. Pull down to retry.')];
      case _CampusState.loaded:
        if (data.suggestions.isEmpty) {
          return [const FriendInlineNote('No new players from your campus this week.')];
        }
        return [
          for (final r in data.suggestions)
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: FriendTile(
                name: r.username,
                subtitle: '${r.weeklyPoints} WP this week',
                trailing: AppButton(
                  label: 'Add',
                  size: AppButtonSize.small,
                  loading: _busyUids.contains(r.uid),
                  onPressed: _busyUids.contains(r.uid)
                      ? null
                      : () => _addFromCampus(r.uid),
                ),
              ),
            ),
        ];
    }
  }

  static String _linkName(FriendLink l) => l.username.isEmpty ? 'Player' : l.username;
}

