import 'package:flutter/material.dart';

import '../../../data/services/web_retrieval/web_retrieval.dart';
import '../../core/theme/app_theme.dart';

/// Adaptive surface for the chat input's "+" menu.
///
/// On wide screens (>= 720px) it renders as a popover anchored to the button;
/// on phones it slides up as a bottom sheet (drawer-style). The content is the
/// same: a list of available tools (web search/fetch providers, etc.) with
/// toggles controlling whether they're attached to the next outgoing message.
///
/// This is intentionally minimal for now — custom per-tool configuration
/// (API keys, endpoints) will come later. The tools themselves are always
/// enabled at startup; this UI only controls whether they're attached to the
/// next outgoing message.
///
/// The sheet owns its toggle state internally (seeded from [initialEnabled])
/// and reports each change via [onToggle] with the new desired value. This
/// avoids the stale-closure bug where a `VoidCallback` captured an outdated
/// `enabled` flag and oscillated instead of flipping.
class ChatToolsSheet extends StatefulWidget {
  const ChatToolsSheet({
    super.key,
    required this.initialEnabled,
    required this.onToggle,
    required this.adapter,
  });

  /// Starting value for the toggle, from the live source of truth.
  final bool initialEnabled;

  /// Called with the new desired enabled value on every toggle.
  final ValueChanged<bool> onToggle;

  final WebRetrievalAdapter adapter;

  @override
  State<ChatToolsSheet> createState() => _ChatToolsSheetState();
}

class _ChatToolsSheetState extends State<ChatToolsSheet> {
  late bool _enabled = widget.initialEnabled;

  void _toggle() {
    setState(() => _enabled = !_enabled);
    widget.onToggle(_enabled);
  }

  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ToggleRow(label: 'Web search', value: _enabled, onToggle: _toggle),
          ],
        ),
      ),
    );
  }
}

/// A single tappable row with a label and a switch. The whole row is the tap
/// target (via [InkWell]) so the switch's gesture detection never drops a
/// tap during its animation; the switch reflects state visually and also
/// routes through [onToggle] if tapped directly.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onToggle,
  });

  final String label;
  final bool value;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Theme(
          data: Theme.of(context).copyWith(
            splashColor: AppTheme.textPrimary.withValues(alpha: 0.04),
            highlightColor: AppTheme.textPrimary.withValues(alpha: 0.06),
            hoverColor: AppTheme.textPrimary.withValues(alpha: 0.03),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            // Material *inside* the clip so the InkWell's ink (splash + hover)
            // is painted on a canvas that the ClipRRect actually clips.
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onToggle,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: double.infinity),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    child: Row(
                      children: <Widget>[
                        Text(
                          label,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        SizedBox(
                          height: 24,
                          child: FittedBox(
                            child: Switch.adaptive(
                              value: value,
                              activeThumbColor: AppTheme.brandViolet,
                              activeTrackColor: AppTheme.brandViolet.withValues(
                                alpha: 0.4,
                              ),
                              onChanged: (_) => onToggle(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the [ChatToolsSheet] adaptively: popover on desktop, bottom sheet
/// on mobile. Anchored to [anchorKey] (the + button's RenderBox) on wide
/// screens.
Future<void> showChatToolsMenu({
  required BuildContext context,
  required bool enabled,
  required ValueChanged<bool> onToggle,
  required WebRetrievalAdapter adapter,
  required GlobalKey anchorKey,
}) async {
  final bool wide = MediaQuery.of(context).size.width >= 720;
  if (wide) {
    final RenderBox? box =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final Offset target = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final Size size = box?.size ?? Size.zero;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      builder: (BuildContext _) {
        return _PopoverDialog(
          anchorTopLeft: target,
          anchorSize: size,
          child: ChatToolsSheet(
            initialEnabled: enabled,
            onToggle: onToggle,
            adapter: adapter,
          ),
        );
      },
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (BuildContext _) {
        return ChatToolsSheet(
          initialEnabled: enabled,
          onToggle: onToggle,
          adapter: adapter,
        );
      },
    );
  }
}

/// A lightweight popover anchored to a button. Renders below the anchor when
/// there's room, otherwise flips above. Tapping outside dismisses it. Uses
/// [showDialog] with a transparent barrier so the popover stays open while the
/// user interacts with the Switch inside.
class _PopoverDialog extends StatelessWidget {
  const _PopoverDialog({
    required this.anchorTopLeft,
    required this.anchorSize,
    required this.child,
  });

  final Offset anchorTopLeft;
  final Size anchorSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.of(context).size;
    final double anchorBottom = anchorTopLeft.dy + anchorSize.height;
    final double spaceBelow = viewport.height - anchorBottom;
    final double spaceAbove = anchorTopLeft.dy;

    // Default: below the anchor. Flip above if there's not enough room below
    // but there is above. The 320 width + ~280 estimated sheet height is the
    // threshold; we measure the actual child via a LayoutBuilder below to
    // position precisely.
    final bool preferBelow = spaceBelow >= spaceAbove;

    return Stack(
      children: <Widget>[
        // Tap-catcher to dismiss — fills the screen behind the popover.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: anchorTopLeft.dx,
          top: preferBelow ? anchorBottom + 6 : null,
          bottom: preferBelow ? null : (viewport.height - anchorTopLeft.dy + 6),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.surfaceHigh),
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}
