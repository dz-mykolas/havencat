import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../providers.dart';
import 'app_notice.dart';
import 'notice_center.dart';

class NoticeHost extends ConsumerStatefulWidget {
  const NoticeHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends ConsumerState<NoticeHost> {
  String? _showingId;

  @override
  Widget build(BuildContext context) {
    final NoticeCenter center = ref.watch(noticeCenterProvider);
    final AppNotice? notice = center.currentFor(NoticePlacement.snackbar);
    if (notice != null && notice.id != _showingId) {
      _showingId = notice.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _show(context, center, notice);
      });
    }
    return widget.child;
  }

  void _show(BuildContext context, NoticeCenter center, AppNotice notice) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) {
      center.dismiss(notice.id);
      _showingId = null;
      return;
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
    final (IconData, Color) appearance = switch (notice.severity) {
      NoticeSeverity.info => (Icons.info_outline, colors.primary),
      NoticeSeverity.success => (Icons.check_circle_outline, Colors.green),
      NoticeSeverity.warning => (Icons.warning_amber_rounded, colors.tertiary),
      NoticeSeverity.error => (Icons.error_outline, colors.error),
      NoticeSeverity.critical => (Icons.dangerous_outlined, colors.error),
    };
    final double width = math.min(MediaQuery.sizeOf(context).width - 32, 560);
    messenger.hideCurrentSnackBar();
    final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> controller =
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            width: width,
            duration: Duration(
              seconds: notice.severity == NoticeSeverity.info ? 5 : 9,
            ),
            content: Row(
              children: <Widget>[
                Icon(appearance.$1, color: appearance.$2),
                const SizedBox(width: 12),
                Expanded(
                  child: SelectionArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          notice.title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(notice.message),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _CopyNoticeButton(
                  text: '${notice.title}\n${notice.message}',
                  error:
                      notice.severity == NoticeSeverity.error ||
                      notice.severity == NoticeSeverity.critical,
                ),
                if (notice.dismissible)
                  IconButton(
                    tooltip: 'Dismiss message',
                    onPressed: messenger.hideCurrentSnackBar,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            action: notice.actions.isEmpty
                ? null
                : SnackBarAction(
                    label: notice.actions.first.label,
                    onPressed: () {
                      unawaited(notice.actions.first.onPressed());
                    },
                  ),
          ),
        );
    unawaited(
      controller.closed.whenComplete(() {
        center.dismiss(notice.id);
        if (_showingId == notice.id) _showingId = null;
      }),
    );
  }
}

class _CopyNoticeButton extends StatefulWidget {
  const _CopyNoticeButton({required this.text, required this.error});

  final String text;
  final bool error;

  @override
  State<_CopyNoticeButton> createState() => _CopyNoticeButtonState();
}

class _CopyNoticeButtonState extends State<_CopyNoticeButton> {
  Timer? _resetTimer;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    _resetTimer?.cancel();
    setState(() => _copied = true);
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: widget.error ? 'Copy error message' : 'Copy message',
      onPressed: _copy,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      iconSize: 18,
      icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
    );
  }
}
