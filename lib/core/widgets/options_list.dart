// =============================================================================
// widgets/options_list.dart
// =============================================================================
// What changed and why:
//
//  STAGGERED ENTRY
//  • Each option gets its own AnimationController (280 ms, Curves.easeOut).
//  • didChangeDependencies (with an _initialized guard) sets up fresh
//    controllers and fires a 60 ms stagger per option.
//  • The widget is keyed with ValueKey(qIndex) from its parent so Flutter
//    destroys and recreates the State on every question advance, naturally
//    replaying the stagger entry for the new set of options.
//
//  WHY didChangeDependencies NOT initState
//  • context.read<QuizController>() requires InheritedWidget ancestors to be
//    fully attached. didChangeDependencies is the first lifecycle hook where
//    that is guaranteed — initState is called before the widget is inserted
//    into the tree's InheritedWidget chain.
//
//  DISPOSAL SAFETY
//  • All AnimationControllers are disposed in dispose().
//  • Stagger Future.delayed calls check mounted before forwarding, so there
//    is no setState-after-dispose crash if the widget is keyed away mid-stagger.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/app_theme.dart';
import '../../features/quiz/quiz_controller.dart';
import 'option_tile.dart';

class OptionsListWidget extends StatefulWidget {
  // key is set to ValueKey(ctrl.qIndex) by the parent — see questions_page.dart
  const OptionsListWidget({super.key});

  @override
  State<OptionsListWidget> createState() => _OptionsListWidgetState();
}

class _OptionsListWidgetState extends State<OptionsListWidget>
    with TickerProviderStateMixin {
  List<AnimationController> _ctrlList  = [];
  List<Animation<double>>   _fadeList  = [];
  List<Animation<Offset>>   _slideList = [];
  bool _initialized = false;

  // ── Setup ──────────────────────────────────────────────────────────────────

  void _setup(int count) {
    _ctrlList = List.generate(
      count,
      (_) => AnimationController(
        vsync:    this,
        duration: const Duration(milliseconds: 280),
      ),
    );

    _fadeList = _ctrlList
        .map((c) => CurvedAnimation(parent: c, curve: Curves.easeOut)
            as Animation<double>)
        .toList();

    _slideList = _ctrlList
        .map(
          (c) => Tween<Offset>(
            begin: const Offset(0, 0.07),
            end:   Offset.zero,
          ).animate(CurvedAnimation(parent: c, curve: Curves.easeOut)),
        )
        .toList();
  }

  void _runStagger(int count) {
    for (var i = 0; i < count; i++) {
      Future.delayed(Duration(milliseconds: 60 * i), () {
        if (mounted && i < _ctrlList.length) {
          _ctrlList[i].forward();
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final ctrl = context.read<QuizController>();
    final q    = ctrl.currentQuestion;
    if (q == null) return;

    _setup(q.options.length);
    _runStagger(q.options.length);
  }

  @override
  void dispose() {
    for (final c in _ctrlList) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<QuizController>();
    final q    = ctrl.currentQuestion;

    if (q == null || _fadeList.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Column(
        children: List.generate(q.options.length, (i) {
          // Guard: if option count somehow differs from animation count.
          if (i >= _fadeList.length) return const SizedBox.shrink();

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FadeTransition(
              opacity: _fadeList[i],
              child: SlideTransition(
                position: _slideList[i],
                child: OptionTileWidget(optionIndex: i),
              ),
            ),
          );
        }),
      ),
    );
  }
}
