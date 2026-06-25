import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/models/message.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/typing_indicator.dart';
import 'chat_markdown.dart';

/// Renders a single [ChatMessage].
///
/// User messages are right-aligned rounded bubbles; assistant messages are
/// left-aligned full-width text preceded by a small gradient avatar.
///
/// When an assistant message carries tool calls, the bubble renders a grouped
/// "tool step" card: each call shows a status icon (loading / done / failed)
/// and is expandable to reveal that call's tool-result payload. The final
/// assistant reply is rendered as a normal chat message after the card, not
/// inside it. Tool-result messages ([MessageRole.tool]) are skipped here
/// because they're inlined into the originating tool-call row.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.messages = const <ChatMessage>[],
  });

  final ChatMessage message;
  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    if (message.isTool) return const SizedBox.shrink();
    return message.isUser ? _buildUser(context) : _buildAssistant(context);
  }

  Widget _buildUser(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(maxWidth: AppTheme.contentMaxWidth * 0.7),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(20),
            bottomRight: Radius.circular(6),
          ),
          border: Border.all(color: AppTheme.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ChatMarkdown(
              text: message.text,
              selectable: true,
              fillWidth: false,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssistant(BuildContext context) {
    final bool showTyping = message.isStreaming && message.text.isEmpty;

    // Assistant message with tool calls → grouped tool-step card.
    if (message.toolCalls.isNotEmpty) {
      return _ToolStepCard(assistant: message, messages: messages);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: showTyping
          ? const Align(
              alignment: Alignment.centerLeft,
              child: TypingIndicator(),
            )
          : ChatMarkdown(
              text: message.text,
              selectable: true,
              streaming: message.isStreaming,
            ),
    );
  }
}

/// A grouped card for an assistant turn that emitted one or more tool calls.
///
/// For each tool call, shows:
///   - a pulsing dot while no matching tool-result message exists yet,
///   - a checkmark once the result arrives (expandable to view the result),
///   - a failure icon if the result text starts with "Error".
///
/// The final assistant reply is NOT rendered here — it appears as a normal
/// chat message after the card, exactly as it did before tool-call grouping.
class _ToolStepCard extends StatelessWidget {
  const _ToolStepCard({required this.assistant, required this.messages});

  final ChatMessage assistant;
  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    final calls = assistant.toolCalls;

    // Find tool-result messages that match each call by toolCallId.
    final Map<String, ChatMessage> resultsById = <String, ChatMessage>{};
    for (final m in messages) {
      if (m.isTool && m.toolCallId != null) {
        resultsById[m.toolCallId!] = m;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.outline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final tc in calls)
                    _ToolCallRow(name: tc.name, result: resultsById[tc.id]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single tool call row. Shows a loading dot while pending, a checkmark (or
/// failure icon) once the result arrives, and — when a result exists — an
/// expand arrow to reveal the tool-result payload inline.
class _ToolCallRow extends StatefulWidget {
  const _ToolCallRow({required this.name, required this.result});

  final String name;
  final ChatMessage? result;

  @override
  State<_ToolCallRow> createState() => _ToolCallRowState();
}

class _ToolCallRowState extends State<_ToolCallRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool done = widget.result != null;
    final bool failed = done && widget.result!.text.startsWith('Error');

    final IconData icon;
    final Color iconColor;
    if (!done) {
      icon = Icons.more_horiz;
      iconColor = AppTheme.outline;
    } else if (failed) {
      icon = Icons.close;
      iconColor = theme.colorScheme.error;
    } else {
      icon = Icons.check;
      iconColor = Colors.green;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        MouseRegion(
          cursor: done ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: done ? () => setState(() => _expanded = !_expanded) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: done
                        ? Icon(icon, size: 14, color: iconColor)
                        : const _DotLoader(),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.build_circle_outlined,
                    size: 14,
                    color: AppTheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.55,
                        ),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (done)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: AppTheme.outline,
                    ),
                ],
              ),
            ),
          ),
        ),
        if (done && _expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.result!.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                maxLines: 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// A single pulsing dot sized to fit a 14×14 box — used as the in-row
/// loading indicator for tool calls. Unlike [TypingIndicator] (three dots
/// needing ~36px), this stays within the icon-size envelope.
class _DotLoader extends StatefulWidget {
  const _DotLoader();

  @override
  State<_DotLoader> createState() => _DotLoaderState();
}

class _DotLoaderState extends State<_DotLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        final double t = _controller.value;
        final double pulse =
            0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2 * math.pi));
        return Center(
          child: Opacity(
            opacity: pulse,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppTheme.brandGradient,
              ),
            ),
          ),
        );
      },
    );
  }
}
