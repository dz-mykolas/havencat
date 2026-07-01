import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/message.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/typing_indicator.dart';
import 'chat_markdown.dart';
import 'token_usage_chip.dart';

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
///
/// Editing: user messages show a pencil affordance on hover; tapping swaps
/// the bubble for a textarea with Save (in-place) and Send (resend) buttons.
/// Assistant messages show a regenerate button. When a message has siblings
/// (alternate versions from edits/regenerations), a `‹ 2/3 ›` counter lets
/// the user switch branches.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.messages = const <ChatMessage>[],
    this.siblings = const <String>[],
    this.isLast = false,
    this.isGenerating = false,
    this.descendantCount = 0,
    this.actualTokens,
    this.completionTokens,
    this.totalTokens,
    this.estimatedTokens,
    this.contextWindow = 0,
    this.onEditUser,
    this.onRegenerate,
    this.onRevert,
    this.onPrevSibling,
    this.onNextSibling,
  });

  final ChatMessage message;
  final List<ChatMessage> messages;

  /// Sibling message ids of [message.id] (including itself). Empty for a root
  /// or a message with no alternate versions.
  final List<String> siblings;

  /// True when this is the last message on the active path. Used to decide
  /// whether to show the regenerate affordance (only on the last assistant).
  final bool isLast;

  /// True while the repository is streaming a reply. Disables edit/regenerate
  /// actions to avoid racing the stream.
  final bool isGenerating;

  /// Number of messages downstream of this one. Used to show a cache-cost
  /// hint when editing a message that has descendants.
  final int descendantCount;

  /// Called when the user saves an edit to a user message. [resend] = true
  /// creates a sibling and re-streams; false mutates in place. Null when the
  /// message isn't editable (non-user, or generation in flight).
  final void Function(String newText, bool resend)? onEditUser;

  /// Called when the user requests regeneration of an assistant message. The
  /// optional [suggestion] is appended to the parent user message for this
  /// turn only. Null when regeneration isn't available.
  final void Function({String? suggestion})? onRegenerate;

  /// Called when the user reverts an in-place edit. Null when the message
  /// wasn't edited in place.
  final VoidCallback? onRevert;

  /// Navigate to the previous / next sibling branch. Null when there are no
  /// siblings (counter hidden).
  final VoidCallback? onPrevSibling;
  final VoidCallback? onNextSibling;

  /// Token usage data for the token chip shown on the last assistant
  /// message's action row.
  final int? actualTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? estimatedTokens;
  final int contextWindow;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  bool _editing = false;
  bool _hovered = false;
  late final TextEditingController _editController;
  late final FocusNode _editFocus;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.message.text);
    _editFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the underlying message changed (e.g. branch switch) while not
    // editing, sync the controller so a future edit starts from current text.
    if (!_editing && oldWidget.message.text != widget.message.text) {
      _editController.text = widget.message.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _startEdit() {
    _editController.text = widget.message.text;
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _editFocus.requestFocus(),
    );
  }

  /// Breakdown of messages below this one on the active path, e.g.
  /// "1 reply, 2 user messages, 2 replies" — shown as a tooltip on the
  /// cost hint so the user knows what they're replacing.
  String get _downstreamBreakdown {
    final int idx = widget.messages.indexOf(widget.message);
    if (idx < 0) return '';
    final List<ChatMessage> below = widget.messages.sublist(idx + 1);
    final int replies = below.where((m) => m.isAssistant).length;
    final int userMsgs = below.where((m) => m.isUser).length;
    final List<String> parts = <String>[];
    if (replies > 0) {
      parts.add('$replies repl${replies == 1 ? 'y' : 'ies'}');
    }
    if (userMsgs > 0) {
      parts.add('$userMsgs user message${userMsgs == 1 ? '' : 's'}');
    }
    return parts.isEmpty ? 'Nothing below' : parts.join(', ');
  }

  void _cancelEdit() => setState(() => _editing = false);

  void _save(bool resend) {
    final String text = _editController.text.trim();
    if (text.isEmpty) return;
    widget.onEditUser?.call(text, resend);
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.message.isTool) return const SizedBox.shrink();
    return widget.message.isUser
        ? _buildUser(context)
        : _buildAssistant(context);
  }

  Widget _buildUser(BuildContext context) {
    if (_editing) return _buildUserEditor(context);
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
          children: <Widget>[
            ChatMarkdown(
              text: widget.message.text,
              selectable: true,
              fillWidth: false,
            ),
            _buildActionsRow(context, isUser: true),
          ],
        ),
      ),
    );
  }

  Widget _buildUserEditor(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(8),
        constraints: BoxConstraints(maxWidth: AppTheme.contentMaxWidth * 0.85),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          border: Border.all(color: AppTheme.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: (KeyEvent e) {
                if (e is KeyDownEvent &&
                    e.logicalKey == LogicalKeyboardKey.escape) {
                  _cancelEdit();
                }
              },
              child: TextField(
                controller: _editController,
                focusNode: _editFocus,
                minLines: 1,
                maxLines: 12,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: InputBorder.none,
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 4),
            if (widget.descendantCount > 0)
              Tooltip(
                message: _downstreamBreakdown,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.info_outline,
                        size: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.descendantCount} '
                        'message${widget.descendantCount == 1 ? '' : 's'} '
                        'below will branch off',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextButton(onPressed: _cancelEdit, child: const Text('Cancel')),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => _save(false),
                  child: const Text('Save'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => _save(true),
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssistant(BuildContext context) {
    final bool showTyping =
        widget.message.isStreaming && widget.message.text.isEmpty;

    // Assistant message with tool calls → grouped tool-step card.
    if (widget.message.toolCalls.isNotEmpty) {
      return _ToolStepCard(
        assistant: widget.message,
        messages: widget.messages,
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            showTyping
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: TypingIndicator(),
                  )
                : ChatMarkdown(
                    text: widget.message.text,
                    selectable: true,
                    streaming: widget.message.isStreaming,
                  ),
            _buildActionsRow(context, isUser: false),
          ],
        ),
      ),
    );
  }

  /// Row of hover-visible actions: sibling counter (if siblings > 1),
  /// edit (user only), regenerate menu (assistant, last only, not while
  /// generating), revert (if edited in place).
  Widget _buildActionsRow(BuildContext context, {required bool isUser}) {
    final bool canEdit =
        isUser && widget.onEditUser != null && !widget.isGenerating;
    final bool canRegenerate =
        !isUser &&
        widget.isLast &&
        widget.onRegenerate != null &&
        !widget.isGenerating;
    final bool canRevert =
        isUser && widget.message.isEdited && widget.onRevert != null;
    final bool hasSiblings = widget.siblings.length > 1;

    // Token chip: shown on assistant messages that have usage data. The last
    // assistant message always shows it; earlier ones show it on hover. Space
    // is always reserved (via Visibility with maintainSize) so hovering
    // doesn't shift the layout.
    final bool hasUsage =
        !isUser &&
        widget.contextWindow > 0 &&
        (widget.totalTokens != null ||
            widget.actualTokens != null ||
            widget.estimatedTokens != null);
    final bool chipVisible = hasUsage && (widget.isLast || _hovered);

    if (!canEdit && !canRegenerate && !hasSiblings && !canRevert && !hasUsage) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: <Widget>[
          if (hasSiblings) _buildSiblingCounter(context),
          if (canRevert)
            _IconButton(
              icon: Icons.undo,
              tooltip: 'Revert edit',
              onTap: widget.onRevert,
            ),
          if (canEdit)
            _IconButton(
              icon: Icons.edit_outlined,
              tooltip: 'Edit',
              onTap: _startEdit,
            ),
          if (canRegenerate) _buildRegenerateMenu(context),
          if (hasUsage)
            Visibility(
              visible: chipVisible,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: TokenUsageChip(
                actualTokens: widget.actualTokens,
                completionTokens: widget.completionTokens,
                totalTokens: widget.totalTokens,
                estimatedTokens: widget.estimatedTokens,
                contextWindow: widget.contextWindow,
                isGenerating: widget.isGenerating,
              ),
            ),
        ],
      ),
    );
  }

  /// Regenerate button with a dropdown menu of suggestion prompts.
  Widget _buildRegenerateMenu(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Regenerate',
      icon: Icon(
        Icons.refresh,
        size: 16,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onSelected: (String? suggestion) {
        widget.onRegenerate?.call(suggestion: suggestion);
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: '', child: Text('Regenerate')),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'Please provide more details and elaboration.',
          child: Text('Add Details'),
        ),
        const PopupMenuItem<String>(
          value: 'Please be more concise and to the point.',
          child: Text('More Concise'),
        ),
        const PopupMenuItem<String>(
          value: 'Please be more specific and precise.',
          child: Text('Be More Specific'),
        ),
      ],
    );
  }

  Widget _buildSiblingCounter(BuildContext context) {
    final int idx = widget.siblings.indexOf(widget.message.id);
    final int pos = idx < 0 ? 1 : idx + 1;
    final theme = Theme.of(context);
    final bool failed = widget.message.hasError;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _IconButton(
          icon: Icons.chevron_left,
          tooltip: 'Previous version',
          onTap: widget.onPrevSibling,
        ),
        Text(
          '$pos/${widget.siblings.length}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: failed
                ? theme.colorScheme.error
                : theme.colorScheme.onSurface.withValues(alpha: 0.55),
            fontWeight: FontWeight.w600,
          ),
        ),
        if (failed)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Icon(
              Icons.error_outline,
              size: 14,
              color: theme.colorScheme.error,
            ),
          ),
        _IconButton(
          icon: Icons.chevron_right,
          tooltip: 'Next version',
          onTap: widget.onNextSibling,
        ),
      ],
    );
  }
}

/// A compact hover-visible icon button used in message action rows.
class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
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
