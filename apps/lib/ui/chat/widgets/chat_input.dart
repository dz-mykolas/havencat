import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../branding.dart';
import '../../../data/services/web_retrieval/web_retrieval.dart';
import '../../../domain/models/content_modality.dart';
import '../../../domain/models/message_attachment.dart';
import '../../core/theme/app_theme.dart';
import 'chat_tools_sheet.dart';
import 'model_selector_bar.dart';

/// The bottom input bar: a multiline text field inside a themed surface with
/// clear focus and generation states.
class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.textController,
    required this.isGenerating,
    required this.queuedCount,
    required this.onSend,
    required this.onCancel,
    required this.onSteer,
    required this.onShowQueue,
    required this.toolsEnabled,
    required this.onToggleTools,
    required this.webRetrievalAdapter,
    required this.imageUploadEnabled,
  });

  final TextEditingController textController;
  final bool isGenerating;
  final int queuedCount;
  final void Function(String text, List<MessageAttachment> attachments) onSend;
  final VoidCallback onCancel;
  final ValueChanged<String> onSteer;
  final VoidCallback onShowQueue;
  final bool toolsEnabled;

  /// Called with the new desired enabled value on every toggle.
  final ValueChanged<bool> onToggleTools;
  final WebRetrievalAdapter webRetrievalAdapter;
  final bool imageUploadEnabled;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput>
    with SingleTickerProviderStateMixin {
  late final AnimationController _activityController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _plusButtonKey = GlobalKey();
  bool _hasText = false;
  bool _focused = false;
  bool _hovered = false;
  bool _popoverOpen = false;
  final List<MessageAttachment> _attachments = <MessageAttachment>[];

  static const Uuid _uuid = Uuid();
  static const int _maxImages = 10;
  static const int _maxTotalBytes = 20 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    widget.textController.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    _syncActivity();
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isGenerating != widget.isGenerating) {
      _syncActivity();
    }
  }

  void _syncActivity() {
    if (widget.isGenerating) {
      _activityController.repeat(reverse: true);
    } else {
      _activityController.stop();
      _activityController.value = 0;
    }
  }

  void _onTextChanged() {
    final String text = widget.textController.text;
    final bool hasText = text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus != _focused) {
      setState(() => _focused = _focusNode.hasFocus);
    }
  }

  void _onHoverChanged(bool hovered) {
    if (hovered != _hovered) {
      setState(() => _hovered = hovered);
    }
  }

  void _submit() {
    final String text = widget.textController.text;
    final bool canSendAttachments =
        _attachments.isEmpty || widget.imageUploadEnabled;
    if ((text.trim().isEmpty && _attachments.isEmpty) || !canSendAttachments) {
      return;
    }
    widget.onSend(text, List<MessageAttachment>.unmodifiable(_attachments));
    widget.textController.clear();
    setState(_attachments.clear);
  }

  void _steer() {
    final String text = widget.textController.text.trim();
    if (text.isEmpty || _attachments.isNotEmpty) return;
    widget.onSteer(text);
    widget.textController.clear();
  }

  Future<void> _pickImages() async {
    if (!widget.imageUploadEnabled) return;
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['png', 'jpg', 'jpeg', 'webp', 'gif'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null || !mounted) return;

    int totalBytes = _attachments.fold<int>(
      0,
      (int total, MessageAttachment value) =>
          total + (value.data.length * 3 ~/ 4),
    );
    final List<MessageAttachment> accepted = <MessageAttachment>[];
    for (final PlatformFile file in result.files) {
      if (_attachments.length + accepted.length >= _maxImages) break;
      final bytes = file.bytes ?? await file.xFile.readAsBytes();
      if (totalBytes + bytes.length > _maxTotalBytes) continue;
      final String extension = (file.extension ?? '').toLowerCase();
      accepted.add(
        MessageAttachment.inline(
          id: 'attachment-${_uuid.v4()}',
          modality: ContentModality.image,
          mimeType: switch (extension) {
            'jpg' || 'jpeg' => 'image/jpeg',
            'webp' => 'image/webp',
            'gif' => 'image/gif',
            _ => 'image/png',
          },
          bytes: bytes,
          name: file.name,
        ),
      );
      totalBytes += bytes.length;
    }
    if (accepted.isNotEmpty) {
      setState(() => _attachments.addAll(accepted));
    }
    if (accepted.length < result.files.length && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Some images were skipped. Add up to $_maxImages images with '
            '20 MB total.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.textController.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _activityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onHoverChanged(true),
      onExit: (_) => _onHoverChanged(false),
      child: AnimatedBuilder(
        animation: _activityController,
        builder: (BuildContext context, Widget? child) {
          final AppThemeColors colors = context.appColors;
          final double activity = Curves.easeInOut.transform(
            _activityController.value,
          );
          final bool engaged = _focused || _popoverOpen;
          final Color borderColor = widget.isGenerating
              ? colors.brandViolet.withValues(alpha: 0.62 + activity * 0.28)
              : engaged
              ? colors.brandViolet.withValues(alpha: 0.9)
              : _hovered
              ? colors.outline.withValues(alpha: 0.85)
              : colors.divider;
          final Color fillColor = widget.isGenerating
              ? Color.alphaBlend(
                  colors.brandViolet.withValues(
                    alpha: 0.025 + activity * 0.025,
                  ),
                  colors.surface,
                )
              : engaged
              ? Color.alphaBlend(
                  colors.brandViolet.withValues(alpha: 0.025),
                  colors.surface,
                )
              : colors.surface;
          return Container(
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: borderColor,
                width: widget.isGenerating
                    ? 2
                    : engaged
                    ? 1.5
                    : 1,
              ),
            ),
            padding: EdgeInsets.fromLTRB(16, 4, 6, 4),
            child: child,
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.isGenerating)
              Row(
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: widget.queuedCount == 0
                            ? null
                            : widget.onShowQueue,
                        child: Text(
                          widget.queuedCount == 0
                              ? 'Generating'
                              : 'Generating · ${widget.queuedCount} queued',
                          style: TextStyle(
                            color: context.appColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _hasText && _attachments.isEmpty ? _steer : null,
                    child: Text('Steer'),
                  ),
                  IconButton(
                    tooltip: 'Cancel generation',
                    onPressed: widget.onCancel,
                    icon: Icon(Icons.stop_rounded, size: 18),
                  ),
                ],
              ),
            if (_attachments.isNotEmpty) ...<Widget>[
              SizedBox(
                height: 70,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _attachments.length,
                  separatorBuilder: (_, _) => SizedBox(width: 8),
                  itemBuilder: (BuildContext context, int index) {
                    return _PendingImage(
                      attachment: _attachments[index],
                      onRemove: () =>
                          setState(() => _attachments.removeAt(index)),
                    );
                  },
                ),
              ),
              SizedBox(height: 4),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _PlusButton(
                  key: _plusButtonKey,
                  active: widget.toolsEnabled,
                  popoverOpen: _popoverOpen,
                  onTap: () async {
                    // Guard against re-entry: a tap while the popover is
                    // already open (or opening) is a no-op. Without this,
                    // spamming the button stacks multiple dialogs, each
                    // with its own switch, and their toggles fight.
                    if (_popoverOpen) return;
                    setState(() => _popoverOpen = true);
                    try {
                      await showChatToolsMenu(
                        context: context,
                        enabled: widget.toolsEnabled,
                        onToggle: widget.onToggleTools,
                        adapter: widget.webRetrievalAdapter,
                        anchorKey: _plusButtonKey,
                        imageUploadEnabled: widget.imageUploadEnabled,
                        onUploadImages: _pickImages,
                      );
                    } finally {
                      if (mounted) {
                        setState(() => _popoverOpen = false);
                      }
                    }
                  },
                ),
                SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: widget.textController,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    cursorColor: context.appColors.brandViolet,
                    style: TextStyle(
                      color: context.appColors.textPrimary,
                      fontSize: 15,
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      filled: false,
                      border: InputBorder.none,
                      hintText: 'Message $appName',
                      hintStyle: TextStyle(
                        color: context.appColors.textSecondary,
                      ),
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                ModelSelectorBar(compact: true),
                SizedBox(width: 4),
                _SendButton(
                  enabled:
                      (_hasText || _attachments.isNotEmpty) &&
                      (_attachments.isEmpty || widget.imageUploadEnabled),
                  queued: widget.isGenerating,
                  onTap: _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingImage extends StatelessWidget {
  const _PendingImage({required this.attachment, required this.onRemove});

  final MessageAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final bytes = attachment.inlineBytes;
    return Stack(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 70,
            height: 70,
            child: bytes == null
                ? ColoredBox(color: context.appColors.surfaceHigh)
                : Image.memory(bytes, fit: BoxFit.cover),
          ),
        ),
        Positioned(
          top: 3,
          right: 3,
          child: Material(
            color: Colors.black.withValues(alpha: 0.65),
            shape: CircleBorder(),
            child: InkWell(
              customBorder: CircleBorder(),
              onTap: onRemove,
              child: Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The "+" affordance on the left of the input. When web search is enabled,
/// it lights up with the brand gradient so the user can see at a glance that
/// the next message will pull fresh context from the web.
class _PlusButton extends StatelessWidget {
  const _PlusButton({
    super.key,
    required this.active,
    required this.popoverOpen,
    required this.onTap,
  });

  final bool active;
  final bool popoverOpen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool highlighted = active || popoverOpen;
    return Tooltip(
      message: active ? 'Tools on' : 'Tools',
      child: SizedBox(
        width: 32,
        height: 32,
        child: Material(
          color: highlighted
              ? context.appColors.brandViolet.withValues(alpha: 0.15)
              : Colors.transparent,
          shape: CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Icon(
              active ? Icons.travel_explore_rounded : Icons.add_rounded,
              size: 22,
              color: highlighted
                  ? context.appColors.brandViolet
                  : context.appColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.queued,
    required this.onTap,
  });

  final bool enabled;
  final bool queued;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: Duration(milliseconds: 200),
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.transparent,
        shape: CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled
                  ? context.appColors.brandViolet
                  : context.appColors.surfaceHigh,
            ),
            child: Icon(
              queued ? Icons.playlist_add_rounded : Icons.arrow_upward_rounded,
              size: 20,
              color: enabled
                  ? context.appColors.background
                  : context.appColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
