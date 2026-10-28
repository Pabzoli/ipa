// lib/features/friends/friend_actions.dart
//
// Friendship management lives on the head-to-head page, not in the friends
// list: the board row stays a quiet ranking line, and the two destructive
// actions are asked for deliberately, where the player is already looking at
// that friend.
//
// PLACEMENT: the relationship is visible (the face-off card badges the rival
// "FRIEND"), the actions are hidden — behind the ⋯ in this page's AppBar. A
// destructive action should be findable when looked for, never a stray tap
// between Duel and Spar, and the page body stays about the match.
//
// No stacked dialog: tapping Remove / Block swaps the sheet into its own
// confirmation panel, so the consequences are read where the action was.

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/services/firestore_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_button.dart';
import '../../core/widgets/app_sheet.dart';
import '../../core/widgets/rival_avatar.dart';
import 'friend_messages.dart';

/// What the player actually did. The host page uses it to word its snackbar
/// and leave: the two are no longer friends, so the page has nothing to show.
enum FriendManageResult { removed, blocked }

/// Opens the per-friend menu. Resolves with what changed, or null on dismiss.
Future<FriendManageResult?> showFriendManageSheet(
  BuildContext context, {
  required String uid,
  required String name,
}) {
  return showAppSheet<FriendManageResult>(
    context,
    builder: (_) => _FriendManageSheet(uid: uid, name: name),
  );
}

enum _Action { remove, block }

class _FriendManageSheet extends StatefulWidget {
  final String uid;
  final String name;

  const _FriendManageSheet({required this.uid, required this.name});

  @override
  State<_FriendManageSheet> createState() => _FriendManageSheetState();
}

class _FriendManageSheetState extends State<_FriendManageSheet> {
  _Action? _confirm;
  bool _busy = false;

  Future<void> _run(_Action action) async {
    setState(() => _busy = true);
    try {
      if (action == _Action.remove) {
        await FirestoreService.instance.removeFriend(otherUid: widget.uid);
      } else {
        await FirestoreService.instance.blockUser(otherUid: widget.uid);
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        action == _Action.remove
            ? FriendManageResult.removed
            : FriendManageResult.blocked,
      );
    } catch (e) {
      if (!mounted) return;
      // Stay on the sheet so the action can be retried in place.
      setState(() {
        _busy = false;
        _confirm = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendErrorFrom(e)),
          backgroundColor: AppColors.wrong,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          SizedBox(height: 14.h),
          if (_confirm == null) _menu() else _confirmBody(_confirm!),
        ],
      ),
    );
  }

  /// Who this is about — the sheet is per friend, so it says which one.
  Widget _header() {
    return Row(
      children: [
        RivalAvatar(name: widget.name, size: 46.r, color: AppColors.primary),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.titleMedium,
              ),
              SizedBox(height: 2.h),
              Text(
                'You\'re friends',
                style: AppTypography.bodySmall.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _menu() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _actionRow(
          icon: Icons.person_remove_outlined,
          label: 'Remove friend',
          hint: 'They would have to send a new request.',
          color: AppColors.textPrimary,
          onTap: _busy ? null : () => setState(() => _confirm = _Action.remove),
        ),
        Divider(height: 1, color: AppColors.divider),
        _actionRow(
          icon: Icons.block_rounded,
          label: 'Block',
          hint: 'They can\'t send you requests or duels.',
          color: AppColors.readable(AppColors.wrong),
          onTap: _busy ? null : () => setState(() => _confirm = _Action.block),
        ),
      ],
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required String hint,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      splashColor: color.withValues(alpha: 0.10),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 10.r, vertical: 12.r),
        child: Row(
          children: [
            Icon(icon, size: 20.r, color: color),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: AppTypography.labelLarge
                  .copyWith(color: AppColors.readable(color)),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    hint,
                    style: AppTypography.bodySmall.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirmation replaces the menu in place: a tinted warning panel, so the
  /// sheet keeps saying which friend and what will happen, without stacking a
  /// second dialog over the page.
  Widget _confirmBody(_Action action) {
    final isBlock = action == _Action.block;
    final body = isBlock
        ? 'They can\'t send you requests or duels, and any open invites between '
            'you are cancelled. You can unblock them later from Add Friend.'
        : 'You will both lose the friendship. You can add each other again '
            'later with a new request.';

    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: AppColors.wrong.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.wrong.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isBlock ? 'Block ${widget.name}?' : 'Remove ${widget.name}?',
            style: AppTypography.titleMedium,
          ),
          SizedBox(height: 6.h),
          Text(
            body,
            style: AppTypography.bodySmall.copyWith(
              color: AppColors.textSecondary,
              height: 1.45,
            ),
          ),
          SizedBox(height: 14.h),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.outline,
                  size: AppButtonSize.small,
                  color: AppColors.textSecondary,
                  onPressed:
                      _busy ? null : () => setState(() => _confirm = null),
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: isBlock ? 'Block' : 'Remove',
                  size: AppButtonSize.small,
                  color: AppColors.readable(AppColors.wrong),
                  loading: _busy,
                  onPressed: _busy ? null : () => _run(action),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
