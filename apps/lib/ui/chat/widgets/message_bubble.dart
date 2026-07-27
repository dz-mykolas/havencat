import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/message.dart';
import '../../../domain/models/message_attachment.dart';
import '../../../domain/models/web_search_result_payload.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
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
/// the bubble for a textarea with Save (in-place) and Send again buttons.
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
    this.estimatedCompletionTokens,
    this.contextWindow = 0,
    this.onEditUser,
    this.onRegenerate,
    this.onContinue,
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
  final VoidCallback? onContinue;

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
  final int? estimatedCompletionTokens;
  final int contextWindow;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with AutomaticKeepAliveClientMixin {
  bool _editing = false;
  bool _hovered = false;
  bool _editBranchHovered = false;
  late final TextEditingController _editController;
  late final FocusNode _editFocus;

  @override
  bool get wantKeepAlive => _editing;

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
    _setEditing(true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _editFocus.requestFocus(),
    );
  }

  void _setEditing(bool value) {
    if (_editing == value) return;
    setState(() {
      _editing = value;
      if (!value) _editBranchHovered = false;
    });
    updateKeepAlive();
  }

  void _cancelEdit() => _setEditing(false);

  void _save(bool resend) {
    final String text = _editController.text.trim();
    if (text.isEmpty) return;
    widget.onEditUser?.call(text, resend);
    _setEditing(false);
  }

  void _copyUserMessage() {
    Clipboard.setData(ClipboardData(text: widget.message.text));
  }

  void _showUserActions() {
    final bool canCopy = widget.message.text.isNotEmpty;
    final bool canEdit = widget.onEditUser != null && !widget.isGenerating;
    if (!canCopy && !canEdit) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (canCopy)
                ListTile(
                  leading: Icon(Icons.copy_outlined),
                  title: Text('Copy message'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _copyUserMessage();
                  },
                ),
              if (canEdit)
                ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Edit message'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _startEdit();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.message.isTool) return SizedBox.shrink();
    return widget.message.isUser
        ? _buildUser(context)
        : _buildAssistant(context);
  }

  Widget _buildUser(BuildContext context) {
    if (_editing) return _buildUserEditor(context);
    final bool canCopy = widget.message.text.isNotEmpty;
    final bool canEdit = widget.onEditUser != null && !widget.isGenerating;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxBubbleWidth = math.min(
          AppTheme.contentMaxWidth * 0.7,
          constraints.maxWidth,
        );
        return MouseRegion(
          onEnter: (_) {
            if (canCopy || canEdit) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPress: _showUserActions,
            child: Align(
              alignment: Alignment.centerRight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Container(
                    margin: EdgeInsets.only(top: 6),
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                    decoration: BoxDecoration(
                      color: context.appColors.surface,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(6),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (widget.message.attachments.isNotEmpty)
                          _AttachmentGallery(
                            attachments: widget.message.attachments,
                          ),
                        if (widget.message.attachments.isNotEmpty &&
                            widget.message.text.isNotEmpty)
                          SizedBox(height: 8),
                        if (widget.message.text.isNotEmpty)
                          ChatMarkdown(
                            text: widget.message.text,
                            selectable: false,
                            fillWidth: false,
                          ),
                        _buildActionsRow(context, isUser: true),
                      ],
                    ),
                  ),
                  if (canCopy || canEdit)
                    SizedBox(
                      height: 38,
                      child: AnimatedOpacity(
                        key: const ValueKey<String>('user-message-actions'),
                        opacity: _hovered ? 1 : 0,
                        duration: const Duration(milliseconds: 100),
                        child: IgnorePointer(
                          ignoring: !_hovered,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (canCopy)
                                KeyedSubtree(
                                  key: const ValueKey<String>(
                                    'user-copy-control',
                                  ),
                                  child: _IconButton(
                                    icon: Icons.copy_outlined,
                                    tooltip: 'Copy',
                                    onTap: _copyUserMessage,
                                    iconSize: 18,
                                    padding: 6,
                                  ),
                                ),
                              if (canCopy && canEdit) SizedBox(width: 4),
                              if (canEdit)
                                KeyedSubtree(
                                  key: const ValueKey<String>(
                                    'user-edit-control',
                                  ),
                                  child: _IconButton(
                                    icon: Icons.edit_outlined,
                                    tooltip: 'Edit',
                                    onTap: _startEdit,
                                    iconSize: 18,
                                    padding: 6,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(height: 6),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUserEditor(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.symmetric(vertical: 6),
        padding: EdgeInsets.all(8),
        constraints: BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
        decoration: BoxDecoration(
          color: context.appColors.surface,
          borderRadius: BorderRadius.all(Radius.circular(20)),
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
                decoration: InputDecoration(
                  filled: false,
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
            SizedBox(height: 4),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _editController,
              builder: (BuildContext context, TextEditingValue value, Widget? child) {
                final String text = value.text.trim();
                final bool canCommit =
                    text.isNotEmpty && text != widget.message.text.trim();
                final ButtonStyle textActionStyle = TextButton.styleFrom(
                  minimumSize: Size(0, 36),
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  visualDensity: VisualDensity.compact,
                );
                final ButtonStyle filledActionStyle = FilledButton.styleFrom(
                  minimumSize: Size(0, 36),
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  visualDensity: VisualDensity.compact,
                );
                return Row(
                  children: <Widget>[
                    if (widget.descendantCount > 0)
                      MouseRegion(
                        onEnter: (_) =>
                            setState(() => _editBranchHovered = true),
                        onExit: (_) =>
                            setState(() => _editBranchHovered = false),
                        child: AnimatedOpacity(
                          opacity: _editBranchHovered ? 1 : 0.5,
                          duration: Duration(milliseconds: 100),
                          child: Tooltip(
                            message:
                                '${widget.descendantCount} later '
                                'message${widget.descendantCount == 1 ? '' : 's'} '
                                '${widget.descendantCount == 1 ? 'stays' : 'stay'} '
                                'available after sending',
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(
                                    Icons.call_split_rounded,
                                    size: 14,
                                    color: context.appColors.textSecondary,
                                  ),
                                  SizedBox(width: 5),
                                  Text(
                                    '${widget.descendantCount}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color:
                                              context.appColors.textSecondary,
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Spacer(),
                    PopupMenuButton<String>(
                      enabled: canCommit,
                      tooltip: 'More edit options',
                      icon: Icon(Icons.more_horiz_rounded, size: 18),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        fixedSize: Size.square(36),
                        padding: EdgeInsets.zero,
                      ),
                      onSelected: (String action) {
                        if (action == 'save') _save(false);
                      },
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                              value: 'save',
                              child: Text('Save without sending'),
                            ),
                          ],
                    ),
                    SizedBox(width: 2),
                    TextButton(
                      onPressed: _cancelEdit,
                      style: textActionStyle,
                      child: Text('Cancel'),
                    ),
                    SizedBox(width: 6),
                    FilledButton(
                      onPressed: canCommit ? () => _save(true) : null,
                      style: filledActionStyle,
                      child: Text('Send'),
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

  Widget _buildAssistant(BuildContext context) {
    final bool hasReasoning = widget.message.reasoning.isNotEmpty;
    final bool reasoningStreaming = widget.message.isStreaming && hasReasoning;
    final bool showTyping =
        widget.message.isStreaming &&
        widget.message.text.isEmpty &&
        !hasReasoning;

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
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (hasReasoning)
              _ThinkingRow(
                reasoning: widget.message.reasoning,
                streaming: reasoningStreaming,
              ),
            if (widget.message.attachments.isNotEmpty)
              _AttachmentGallery(attachments: widget.message.attachments),
            if (widget.message.attachments.isNotEmpty &&
                widget.message.text.isNotEmpty)
              SizedBox(height: 8),
            if (showTyping)
              Align(alignment: Alignment.centerLeft, child: TypingIndicator())
            else if (widget.message.text.isNotEmpty)
              ChatMarkdown(text: widget.message.text, selectable: true),
            if (widget.message.generationStatus ==
                    MessageGenerationStatus.interrupted ||
                widget.message.generationStatus ==
                    MessageGenerationStatus.failed)
              _InterruptedGenerationRow(
                failed:
                    widget.message.generationStatus ==
                    MessageGenerationStatus.failed,
                onContinue: widget.onContinue,
              ),
            _buildActionsRow(context, isUser: false),
          ],
        ),
      ),
    );
  }

  /// Row of message actions: sibling counter, regenerate, revert, and usage.
  Widget _buildActionsRow(BuildContext context, {required bool isUser}) {
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
            widget.estimatedTokens != null ||
            widget.estimatedCompletionTokens != null);
    final bool chipVisible = hasUsage && (widget.isLast || _hovered);

    if (!canRegenerate && !hasSiblings && !canRevert && !hasUsage) {
      return SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(top: 4),
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
                estimatedCompletionTokens: widget.estimatedCompletionTokens,
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
      constraints: BoxConstraints(),
      onSelected: (String? suggestion) {
        widget.onRegenerate?.call(suggestion: suggestion);
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: '', child: Text('Regenerate')),
        PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'Please provide more details and elaboration.',
          child: Text('Add Details'),
        ),
        PopupMenuItem<String>(
          value: 'Please be more concise and to the point.',
          child: Text('More Concise'),
        ),
        PopupMenuItem<String>(
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
            padding: EdgeInsets.only(left: 2),
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

class _InterruptedGenerationRow extends StatelessWidget {
  const _InterruptedGenerationRow({
    required this.failed,
    required this.onContinue,
  });

  final bool failed;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.appColors.surfaceHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.appColors.divider),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                failed ? Icons.error_outline : Icons.pause_circle_outline,
                size: 16,
                color: context.appColors.textSecondary,
              ),
              SizedBox(width: 7),
              Flexible(
                child: Text(
                  failed ? 'Response failed' : 'Response interrupted',
                  style: TextStyle(
                    color: context.appColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              if (onContinue != null) ...<Widget>[
                SizedBox(width: 8),
                TextButton(onPressed: onContinue, child: Text('Continue')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders the non-text parts of a message using their local bytes or URL.
class _AttachmentGallery extends StatelessWidget {
  const _AttachmentGallery({required this.attachments});

  final List<MessageAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: attachments
          .map(
            (MessageAttachment attachment) => ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: 120,
                  minHeight: 120,
                  maxWidth: 420,
                  maxHeight: 420,
                ),
                child: _attachmentImage(context, attachment),
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _attachmentImage(BuildContext context, MessageAttachment attachment) {
    final bool svg = attachment.mimeType == 'image/svg+xml';
    final bytes = attachment.inlineBytes;
    if (bytes != null) {
      if (svg) return SvgPicture.memory(bytes, fit: BoxFit.contain);
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallback(context),
      );
    }
    if (attachment.source == AttachmentSource.url) {
      if (svg) return SvgPicture.network(attachment.data, fit: BoxFit.contain);
      return Image.network(
        attachment.data,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallback(context),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    return ColoredBox(
      color: context.appColors.surfaceHigh,
      child: Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}

/// A compact hover-visible icon button used in message action rows.
class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 16,
    this.padding = 4,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double iconSize;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Icon(
            icon,
            size: iconSize,
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
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: context.appColors.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final tc in calls)
                    _ToolCallRow(call: tc, result: resultsById[tc.id]),
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
  const _ToolCallRow({required this.call, required this.result});

  final ToolCall call;
  final ChatMessage? result;

  @override
  State<_ToolCallRow> createState() => _ToolCallRowState();
}

class _ToolCallRowState extends State<_ToolCallRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String? requestValue = _toolCallRequestValue(widget.call);
    final bool done = widget.result != null;
    final bool failed =
        done &&
        (widget.result!.hasError ||
            widget.result!.text.startsWith('Error') ||
            widget.result!.text.startsWith('The web tool failed:'));
    final Color statusColor = failed
        ? theme.colorScheme.error
        : done
        ? const Color(0xFF3BAF7A)
        : context.appColors.brandViolet;
    final String statusLabel = failed
        ? 'Failed'
        : done
        ? 'Completed'
        : _toolCallPendingLabel(widget.call);
    final WebSearchResultPayload? searchResults =
        done && !failed && widget.call.name == 'web_search'
        ? WebSearchResultPayload.tryDecode(widget.result!.text)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          button: done,
          expanded: done ? _expanded : null,
          label: '${_toolCallLabel(widget.call)}, $statusLabel',
          child: MouseRegion(
            cursor: done ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: done ? () => setState(() => _expanded = !_expanded) : null,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    SizedBox(
                      height: 30,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: context.appColors.brandViolet.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              _toolCallIcon(widget.call),
                              size: 16,
                              color: context.appColors.brandViolet,
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    _toolCallLabel(widget.call),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: context.appColors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (done) ...<Widget>[
                                  SizedBox(width: 5),
                                  SizedBox.square(
                                    dimension: 14,
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 140,
                                      ),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      transitionBuilder:
                                          (
                                            Widget child,
                                            Animation<double> animation,
                                          ) => FadeTransition(
                                            opacity: animation,
                                            child: SlideTransition(
                                              position: Tween<Offset>(
                                                begin: const Offset(-0.12, 0),
                                                end: Offset.zero,
                                              ).animate(animation),
                                              child: child,
                                            ),
                                          ),
                                      child: _expanded
                                          ? const SizedBox(
                                              key: ValueKey<String>(
                                                'header-status-hidden',
                                              ),
                                            )
                                          : Icon(
                                              key: const ValueKey<String>(
                                                'header-status-visible',
                                              ),
                                              failed
                                                  ? Icons.error_outline
                                                  : Icons.check,
                                              size: 14,
                                              color: statusColor,
                                            ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (done)
                            Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 18,
                              color: context.appColors.outline,
                            ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 40,
                      top: 23,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 140),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder:
                            (Widget child, Animation<double> animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(-0.12, 0),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                        child: !done || _expanded
                            ? SizedBox(
                                key: ValueKey<String>(statusLabel),
                                height: 14,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: <Widget>[
                                    SizedBox.square(
                                      dimension: 12,
                                      child: done
                                          ? Icon(
                                              failed
                                                  ? Icons.error_outline
                                                  : Icons.check,
                                              size: 12,
                                              color: statusColor,
                                            )
                                          : _DotLoader(),
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      statusLabel,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: statusColor,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w600,
                                            height: 1,
                                          ),
                                    ),
                                  ],
                                ),
                              )
                            : const SizedBox(
                                key: ValueKey<String>('status-hidden'),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (done && _expanded)
          Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (requestValue != null)
                  _ToolDetailSection(
                    icon: Icons.north_east_rounded,
                    label: 'Request',
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: context.appColors.brandViolet.withValues(
                          alpha: 0.08,
                        ),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: context.appColors.brandViolet.withValues(
                            alpha: 0.18,
                          ),
                        ),
                      ),
                      child: SelectableText(
                        requestValue,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: context.appColors.textPrimary,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                _ToolDetailSection(
                  icon: failed
                      ? Icons.error_outline_rounded
                      : Icons.south_west_rounded,
                  label: failed
                      ? 'Error'
                      : searchResults != null
                      ? 'Results'
                      : 'Result',
                  accentColor: failed
                      ? theme.colorScheme.error
                      : context.appColors.textSecondary,
                  child: searchResults != null
                      ? _WebSearchResults(payload: searchResults)
                      : _ToolResultText(
                          text: widget.result!.text,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: failed
                                ? theme.colorScheme.error
                                : context.appColors.textPrimary,
                            fontFamily: 'monospace',
                            height: 1.45,
                          ),
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _WebSearchResults extends StatelessWidget {
  const _WebSearchResults({required this.payload});

  final WebSearchResultPayload payload;

  @override
  Widget build(BuildContext context) {
    if (payload.results.isEmpty) {
      return Row(
        children: <Widget>[
          Icon(
            Icons.search_off_rounded,
            size: 16,
            color: context.appColors.textSecondary,
          ),
          SizedBox(width: 7),
          Text(
            'No results found',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.appColors.textSecondary,
            ),
          ),
        ],
      );
    }

    final double maxHeight = math.min(
      360,
      MediaQuery.sizeOf(context).height * 0.45,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: AppScrollView(
        builder: (BuildContext context, AppScrollController controller) =>
            SingleChildScrollView(
              controller: controller,
              child: Column(
                children: <Widget>[
                  for (int index = 0; index < payload.results.length; index++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: index == payload.results.length - 1 ? 0 : 14,
                      ),
                      child: _WebSearchResultRow(
                        index: index,
                        result: payload.results[index],
                      ),
                    ),
                  if (payload.warnings.isNotEmpty) ...<Widget>[
                    SizedBox(height: 16),
                    SelectionArea(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 15,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              payload.warnings.join(' '),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                    height: 1.35,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
      ),
    );
  }
}

class _WebSearchResultRow extends StatelessWidget {
  const _WebSearchResultRow({required this.index, required this.result});

  final int index;
  final WebSearchResultItem result;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uri? uri = Uri.tryParse(result.url);
    final bool canOpen =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final DateTime? publishedAt = result.publishedAt;
    final String metadata = <String>[
      _displayWebResultUrl(result.url),
      if (publishedAt != null)
        MaterialLocalizations.of(
          context,
        ).formatShortDate(publishedAt.toLocal()),
    ].join(' · ');

    final String title = result.title.isEmpty ? result.url : result.title;
    final VoidCallback? onOpen = canOpen
        ? () => launchUrl(uri, mode: LaunchMode.externalApplication)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: context.appColors.textSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Flexible(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                child: Semantics(
                  link: canOpen,
                  label: canOpen ? '$title, $metadata' : null,
                  child: MouseRegion(
                    key: ValueKey<String>('web-search-result-cursor-$index'),
                    cursor: canOpen
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      key: ValueKey<String>('web-search-result-$index'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onOpen,
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 2),
                        child: Text.rich(
                          TextSpan(
                            children: <InlineSpan>[
                              TextSpan(
                                text: title,
                                style: TextStyle(
                                  color: context.appColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: '  ·  ',
                                style: TextStyle(
                                  color: context.appColors.outline,
                                ),
                              ),
                              TextSpan(
                                text: metadata,
                                style: TextStyle(
                                  color: context.appColors.brandViolet,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (canOpen)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(
                                      Icons.open_in_new_rounded,
                                      size: 12,
                                      color: context.appColors.textSecondary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (result.snippet.isNotEmpty) ...<Widget>[
          SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.only(left: 24),
            child: SelectionArea(
              child: Text(
                result.snippet,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.appColors.textSecondary,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

String _displayWebResultUrl(String value) {
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return value;
  final String host = uri.host.startsWith('www.')
      ? uri.host.substring(4)
      : uri.host;
  final String path = uri.path == '/' ? '' : uri.path;
  return '$host$path';
}

class _ToolResultText extends StatelessWidget {
  const _ToolResultText({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle effectiveStyle = DefaultTextStyle.of(
      context,
    ).style.merge(style);
    final double maxHeight =
        (effectiveStyle.fontSize ?? 14) * (effectiveStyle.height ?? 1.2) * 12;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: AppScrollView(
        builder: (BuildContext context, AppScrollController controller) =>
            SingleChildScrollView(
              controller: controller,
              child: SelectionArea(child: Text(text, style: effectiveStyle)),
            ),
      ),
    );
  }
}

class _ToolDetailSection extends StatelessWidget {
  const _ToolDetailSection({
    required this.icon,
    required this.label,
    required this.child,
    this.accentColor,
  });

  final IconData icon;
  final String label;
  final Widget child;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final Color color = accentColor ?? context.appColors.textSecondary;
    return Padding(
      padding: EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 13, color: color),
              SizedBox(width: 5),
              Text(
                label.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
          SizedBox(height: 7),
          child,
        ],
      ),
    );
  }
}

String _toolCallLabel(ToolCall call) {
  return switch (call.name) {
    'web_search' => 'Web search',
    'fetch_page' => 'Open page',
    _ =>
      call.name
          .split('_')
          .where((String part) => part.isNotEmpty)
          .map(
            (String part) =>
                '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
          )
          .join(' '),
  };
}

IconData _toolCallIcon(ToolCall call) {
  return switch (call.name) {
    'web_search' => Icons.travel_explore_rounded,
    'fetch_page' => Icons.article_outlined,
    _ => Icons.build_circle_outlined,
  };
}

String _toolCallPendingLabel(ToolCall call) {
  return switch (call.name) {
    'web_search' => 'Searching',
    'fetch_page' => 'Opening',
    _ => 'Running',
  };
}

String? _toolCallRequestValue(ToolCall call) {
  if (call.args.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(call.args);
    if (decoded is! Map<String, dynamic>) return null;
    final Object? value = switch (call.name) {
      'web_search' => decoded['query'],
      'fetch_page' => decoded['url'],
      _ => null,
    };
    if (value is! String) return null;
    return value.isEmpty ? '(empty)' : value;
  } on FormatException {
    return null;
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
    duration: Duration(milliseconds: 900),
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
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: context.appColors.brandGradient,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Collapsible "Thinking" row shown above an assistant reply when the model
/// emitted a reasoning stream. Folded by default; the user opens/closes it
/// manually. While [streaming] is true a spinner is shown next to the label.
class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow({required this.reasoning, required this.streaming});

  final String reasoning;
  final bool streaming;

  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 210),
  );
  late final Animation<double> _size = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.18, 1, curve: Curves.easeOut),
    reverseCurve: const Interval(0.45, 1, curve: Curves.easeIn),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.035),
    end: Offset.zero,
  ).animate(_size);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool expanded = _expanded;

    return Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: Material(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                button: true,
                expanded: expanded,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggle,
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: <Widget>[
                          Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: widget.streaming
                                ? SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        colors.primary,
                                      ),
                                    ),
                                  )
                                : RotationTransition(
                                    turns: Tween<double>(
                                      begin: -0.25,
                                      end: 0,
                                    ).animate(_size),
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 16,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                          Text(
                            'Thinking',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ClipRect(
                child: SizeTransition(
                  sizeFactor: _size,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(
                    opacity: _opacity,
                    child: SlideTransition(
                      position: _slide,
                      child: Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: ChatMarkdown(
                          text: widget.reasoning,
                          selectable: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
