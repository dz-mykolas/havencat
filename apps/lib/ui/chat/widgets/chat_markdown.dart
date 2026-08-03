import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/code_highlight_theme.dart';

/// Renders an assistant (or user) message body as rich Markdown with a set of
/// chat-quality-of-life features layered on top of `gpt_markdown`:
///
///  * LaTeX math (inline + block) out of the box.
///  * Code blocks with a header (language label) + copy button.
///  * Inline `` `code` `` spans that copy on tap — the model is instructed
///    (via [SystemPrompts.base]) to wrap anything copy-worthy (redeem codes,
///    API keys, tokens, OTPs, file paths, commands, etc.) in inline code so
///    this chip picks it up automatically. No regex heuristics.
///  * Tappable links opened in the system browser.
///  * Selectable text on desktop/web.
///
/// The rendered subtree is reused while its input is unchanged. Streaming
/// updates are already batched by the generation pipeline, so Markdown is
/// parsed once per visible update rather than from a second animation ticker.
class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown({
    super.key,
    required this.text,
    this.selectable = true,
    this.onLinkTap,
    this.fillWidth = true,
  });

  /// The markdown source. May be partial while streaming.
  final String text;

  /// Whether to wrap in a [SelectionArea] so the whole message is selectable.
  final bool selectable;

  /// Override link handling. Defaults to opening in the system browser.
  final void Function(String url, String title)? onLinkTap;

  /// When true, the widget fills the available width (so block elements like
  /// headings stay left-aligned). When false, it shrinks to fit its content
  /// (so user bubbles are only as wide as their text).
  final bool fillWidth;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  Widget? _rendered;
  String? _renderedText;
  bool? _renderedSelectable;
  bool? _renderedFillWidth;
  void Function(String url, String title)? _renderedOnLinkTap;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rendered = null;
  }

  @override
  Widget build(BuildContext context) {
    if (_rendered != null &&
        _renderedText == widget.text &&
        _renderedSelectable == widget.selectable &&
        _renderedFillWidth == widget.fillWidth &&
        _renderedOnLinkTap == widget.onLinkTap) {
      return _rendered!;
    }

    final ThemeData theme = Theme.of(context);
    final GptMarkdownThemeData mdTheme = GptMarkdownTheme.of(context);

    Widget md = GptMarkdownTheme(
      gptThemeData: mdTheme.copyWith(
        linkColor: context.appColors.brandBlue,
        linkHoverColor: context.appColors.brandPink,
        highlightColor: theme.colorScheme.primary.withValues(alpha: 0.18),
        h1: theme.textTheme.headlineSmall?.copyWith(
          color: context.appColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        h2: theme.textTheme.titleLarge?.copyWith(
          color: context.appColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        h3: theme.textTheme.titleMedium?.copyWith(
          color: context.appColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        h4: theme.textTheme.titleMedium?.copyWith(
          color: context.appColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        h5: theme.textTheme.titleSmall?.copyWith(
          color: context.appColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        h6: theme.textTheme.titleSmall?.copyWith(
          color: context.appColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: GptMarkdown(
        widget.text,
        style: TextStyle(
          color: context.appColors.textPrimary,
          fontSize: 15,
          height: 1.5,
          fontWeight: FontWeight.w400,
        ),
        textDirection: TextDirection.ltr,
        useDollarSignsForLatex: true,
        onLinkTap: widget.onLinkTap ?? _defaultOnLinkTap,
        codeBuilder: (context, name, code, closed) =>
            _ChatCodeBlock(name: name, code: code, closed: closed),
        highlightBuilder: (context, fragment, style) =>
            _InlineCodeChip(text: fragment, style: style),
      ),
    );

    if (widget.fillWidth) {
      md = SizedBox(width: double.infinity, child: md);
    }

    if (widget.selectable) {
      md = SelectionArea(child: md);
    }
    _renderedText = widget.text;
    _renderedSelectable = widget.selectable;
    _renderedFillWidth = widget.fillWidth;
    _renderedOnLinkTap = widget.onLinkTap;
    return _rendered = md;
  }

  Future<void> _defaultOnLinkTap(String url, String title) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// A fenced code block: header row with the language label + a copy button,
/// then a horizontally-scrollable monospace body.
class _ChatCodeBlock extends StatelessWidget {
  const _ChatCodeBlock({
    required this.name,
    required this.code,
    required this.closed,
  });

  final String name;
  final String code;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final String lang = name.trim().isEmpty ? 'text' : name.trim();
    final CodeThemeDefinition codeTheme = CodeHighlightTheme.of(context);
    final Color secondary = codeTheme.foreground.withValues(alpha: 0.72);
    final Color headerBackground = Color.alphaBlend(
      codeTheme.foreground.withValues(alpha: 0.07),
      codeTheme.background,
    );

    return Container(
      margin: EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: codeTheme.background,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            color: headerBackground,
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: <Widget>[
                Icon(Icons.terminal_rounded, size: 14, color: secondary),
                SizedBox(width: 8),
                Text(
                  lang,
                  style: TextStyle(
                    color: secondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Spacer(),
                _CopyButton(text: code, foreground: secondary),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              code,
              language: lang,
              theme: codeTheme.styles,
              padding: EdgeInsets.all(12),
              textStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline `` `code` `` rendered as a small chip that copies its content on tap.
class _InlineCodeChip extends StatefulWidget {
  const _InlineCodeChip({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_InlineCodeChip> createState() => _InlineCodeChipState();
}

class _InlineCodeChipState extends State<_InlineCodeChip> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SelectionContainer.disabled(
      child: Tooltip(
        message: _copied ? 'Copied!' : 'Tap to copy',
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _copy,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    widget.text,
                    softWrap: true,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: (widget.style.fontSize ?? 15) * 0.88,
                      color: _copied
                          ? Colors.green
                          : (widget.style.color ??
                                context.appColors.textPrimary),
                      height: 1.4,
                    ),
                  ),
                ),
                SizedBox(width: 3),
                Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 11,
                  color: _copied
                      ? Colors.green
                      : context.appColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact copy button with a "Copied!" confirmation state.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text, required this.foreground});

  final String text;
  final Color foreground;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _copy,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 13,
                color: _copied ? Colors.green : widget.foreground,
              ),
              SizedBox(width: 4),
              Text(
                _copied ? 'Copied' : 'Copy',
                style: TextStyle(
                  fontSize: 11,
                  color: _copied ? Colors.green : widget.foreground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
