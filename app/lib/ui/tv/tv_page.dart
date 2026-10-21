import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tv_mode.dart';

/// Keep each page in go_router's Navigator so route history and focus restoration stay intact.
class TvPage extends ConsumerWidget {
  const TvPage({super.key, required this.child, required this.tvChild});
  final Widget child;
  final Widget tvChild;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref.watch(tvModeProvider) ? tvChild : child;
}
