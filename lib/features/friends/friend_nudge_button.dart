// lib/features/friends/friend_nudge_button.dart
//
// "Your turn!" nudge, shared by the friends board, the challenge lobby and My
// Challenges. "Nudged" comes from FriendsBoardFetch.friendNudgesToday, so every
// surface agrees and updates the moment one of them sends a nudge. The server
// enforces the turn and the once-per-day limit.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import 'friend_messages.dart';

class FriendNudgeButton extends StatefulWidget {
  final String friendUid;

  /// Pass when nudging from a specific duel; the server otherwise picks the
  /// latest duel that needs the friend.
  final String? challengeId;
  final AppButtonVariant variant;
  final AppButtonSize size;

  /// Renders the nudge as a compact icon button instead of a labelled one.
  /// Used where the row is already dense and the bell says it faster than a
  /// word can.
  final bool iconOnly;

  const FriendNudgeButton({
    super.key,
    required this.friendUid,
    this.challengeId,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.small,
    this.iconOnly = false,
  });

  @override
  State<FriendNudgeButton> createState() => _FriendNudgeButtonState();
}

class _FriendNudgeButtonState extends State<FriendNudgeButton> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Today's nudges come from the board read. Load it when this button opens
    // on a cold cache so it does not offer a nudge that was already sent.
    //
    // Best-effort only: the warm-up must never take the button down with it,
    // and outside the app (widget tests) there is no Firebase app at all.
    try {
      if (!FirestoreService.instance.friendsBoardCacheFresh) {
        FirestoreService.instance.fetchFriendsBoard();
      }
    } catch (_) {
      // Ignored — the button still works.
    }
  }

  Future<void> _nudge() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await FirestoreService.instance.nudgeFriend(
        friendUid: widget.friendUid,
        challengeId: widget.challengeId,
      );
      if (!mounted) return;
      _toast('Nudge sent!');
    } catch (e) {
      if (!mounted) return;
      _toast(friendErrorFrom(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? AppColors.wrong : null,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: FriendsBoardFetch.friendNudgesToday,
      builder: (context, nudged, _) {
        final done = nudged.contains(widget.friendUid);
        final enabled = !_busy && !done && widget.friendUid.isNotEmpty;
        if (widget.iconOnly) {
          return _IconNudgeButton(
            done: done,
            enabled: enabled,
            busy: _busy,
            onPressed: _nudge,
          );
        }
        return AppButton(
          label: done ? 'Nudged' : 'Nudge',
          variant: widget.variant,
          size: widget.size,
          color: done ? AppColors.textMuted : AppColors.secondary,
          loading: _busy,
          onPressed: enabled ? _nudge : null,
        );
      },
    );
  }
}

/// The bell: a nudge waiting to be sent, or one already sent today.
class _IconNudgeButton extends StatelessWidget {
  final bool done;
  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  const _IconNudgeButton({
    required this.done,
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = done ? AppColors.textMuted : AppColors.secondary;
    return Tooltip(
      message: done ? 'Nudged today' : 'Nudge them',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          customBorder: const CircleBorder(),
          child: Container(
            width: 32.r,
            height: 32.r,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: done ? 0.08 : 0.14),
              border: Border.all(
                color: color.withValues(alpha: done ? 0.25 : 0.45),
              ),
            ),
            child: busy
                ? SizedBox(
                    width: 14.r,
                    height: 14.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : Icon(
                    done
                        ? Icons.notifications_off_rounded
                        : Icons.notifications_active_rounded,
                    size: 15.r,
                    color: color,
                  ),
          ),
        ),
      ),
    );
  }
}
