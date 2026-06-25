import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';

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
/// When [streaming] is true, the text is revealed smoothly character-by-
/// character using a per-frame ticker, so chunky token arrivals from the LLM
/// still look like fluid typing (like ChatGPT/Gemini). When not streaming, the
/// full text is rendered immediately.
class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown({
    super.key,
    required this.text,
    this.selectable = true,
    this.onLinkTap,
    this.streaming = false,
    this.fillWidth = true,
  });

  /// The markdown source. May be partial while streaming.
  final String text;

  /// Whether to wrap in a [SelectionArea] so the whole message is selectable.
  final bool selectable;

  /// Override link handling. Defaults to opening in the system browser.
  final void Function(String url, String title)? onLinkTap;

  /// When true, the text is revealed smoothly character-by-character. When
  /// false, the full text is shown immediately.
  final bool streaming;

  /// When true, the widget fills the available width (so block elements like
  /// headings stay left-aligned). When false, it shrinks to fit its content
  /// (so user bubbles are only as wide as their text).
  final bool fillWidth;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

class _ChatMarkdownState extends State<ChatMarkdown>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late Duration _lastElapsed;
  bool _ticking = false;

  /// How many characters of [widget.text] are currently rendered.
  double _revealed = 0;

  /// Timestamp of the last [setState] that triggered a [GptMarkdown] re-parse.
  /// We throttle these to at most one every ~50ms (20fps) because re-parsing
  /// the full markdown is expensive; the ticker still advances [_revealed]
  /// every frame for smooth animation, but we only rebuild on a cadence.
  Duration _lastRender = Duration.zero;
  static const Duration _renderInterval = Duration(milliseconds: 50);

  // ── Dynamic speed tracking ──────────────────────────────────────────────
  // The reveal speed is driven by a "pursuit" model: we always aim to close
  // the gap to the model's latest text, but the speed scales with how far
  // behind we are. This means:
  //  - Small gap (model trickling): we match its pace → smooth, no chunking.
  //  - Large gap (model bursted): we speed up dramatically → catch up fast.
  //  - The gap naturally decelerates the reveal as we approach → no snap.
  //
  // Formula: revealCps = modelCps + remaining / catchupTime
  //   where catchupTime ≈ 1.2s. This gives a pursuit curve: if we're 500 chars
  //   behind, we get +416 cps bonus; if 10 behind, +8 cps. The gap closes
  //   exponentially, which feels natural.

  int _lastTarget = 0;
  Duration _lastTargetTime = Duration.zero;
  double _modelCps = 0;
  double _revealCps = 60;

  static const double _minCps = 25;
  static const double _maxCps = 5000;

  /// Target time (seconds) to close the gap to the model's output.
  static const double _catchupTime = 1.2;

  /// EMA smoothing factor for the model rate (0–1).
  static const double _emaAlpha = 0.2;

  @override
  void initState() {
    super.initState();
    _revealed = widget.streaming ? 0 : widget.text.length.toDouble();
    _lastElapsed = Duration.zero;
    _lastRender = Duration.zero;
    _lastTarget = widget.text.length;
    _lastTargetTime = Duration.zero;
    _ticker = createTicker(_onTick);
    if (widget.streaming) _startTicker();
  }

  @override
  void didUpdateWidget(covariant ChatMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the text changed to a completely different message (not just
    // appended tokens during streaming), snap to full reveal immediately.
    // This happens on branch switches — re-animating would look like the
    // message is regenerating.
    final bool isExtension =
        oldWidget.text.isEmpty || widget.text.startsWith(oldWidget.text);
    if (!isExtension) {
      _revealed = widget.text.length.toDouble();
      _lastTarget = widget.text.length;
      _lastTargetTime = Duration.zero;
      _modelCps = 0;
      _stopTicker();
      setState(() {});
      return;
    }
    if (widget.text.length < _revealed.round()) {
      _revealed = widget.text.length.toDouble();
      _lastTarget = widget.text.length;
    }
    if (widget.streaming && !_ticking) {
      _lastElapsed = Duration.zero;
      _lastRender = Duration.zero;
      _lastTarget = widget.text.length;
      _lastTargetTime = Duration.zero;
      _startTicker();
    } else if (!widget.streaming &&
        !_ticking &&
        _revealed.round() < widget.text.length) {
      // Streaming ended but there's still buffered text to reveal — start
      // the ticker so it smoothly catches up instead of snapping.
      _lastElapsed = Duration.zero;
      _lastRender = Duration.zero;
      _startTicker();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _startTicker() {
    if (_ticking) return;
    _ticking = true;
    _lastElapsed = Duration.zero;
    _lastRender = Duration.zero;
    _lastTargetTime = Duration.zero;
    _ticker.start();
  }

  void _stopTicker() {
    if (!_ticking) return;
    _ticking = false;
    _ticker.stop();
  }

  void _onTick(Duration elapsed) {
    final double dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (dt <= 0) return;

    final int target = widget.text.length;
    final double remaining = target - _revealed;

    if (remaining <= 0.5) {
      _revealed = target.toDouble();
      _lastTarget = target;
      _lastTargetTime = elapsed;
      _stopTicker();
      setState(() {});
      return;
    }

    // ── Measure the model's output rate since the last tick ──────────────
    final int newChars = target - _lastTarget;
    if (newChars > 0) {
      final double tickSec = (elapsed - _lastTargetTime).inMicroseconds / 1e6;
      if (tickSec > 0) {
        final double instantCps = newChars / tickSec;
        _modelCps = _modelCps == 0
            ? instantCps
            : _modelCps + _emaAlpha * (instantCps - _modelCps);
      }
      _lastTarget = target;
      _lastTargetTime = elapsed;
    } else {
      // No new text — decay the model rate so the reveal slows naturally
      // when the model pauses, but never below _minCps.
      _modelCps *= 0.9;
    }

    // ── Pursuit-based reveal speed ───────────────────────────────────────
    // Base = model rate (match its pace). Bonus = gap / catchupTime (close
    // the gap over ~1.2s). This scales dynamically: small gap → barely above
    // model rate; large gap → much faster. The gap shrinks exponentially.
    //
    // When streaming has finished (we're just flushing buffered text), use a
    // higher floor so the tail doesn't crawl — the model is done, there's no
    // reason to keep matching its (now zero) pace.
    final bool flushing = !widget.streaming;
    final double floor = flushing ? 400 : _minCps;
    final double targetCps = (_modelCps + remaining / _catchupTime).clamp(
      floor,
      _maxCps,
    );
    // Smoothly approach the target speed (avoid jarring jumps).
    _revealCps += (targetCps - _revealCps) * (flushing ? 0.3 : 0.15);

    _revealed = (_revealed + _revealCps * dt).clamp(0, target.toDouble());

    if (_revealed.round() >= target) {
      _revealed = target.toDouble();
      _stopTicker();
    }

    // Throttle the expensive GptMarkdown re-parse to ~20fps.
    if (elapsed - _lastRender >= _renderInterval ||
        _revealed.round() >= target) {
      _lastRender = elapsed;
      setState(() {});
    }
  }

  String get _visibleText {
    final int n = _revealed.round().clamp(0, widget.text.length);
    return widget.text.substring(0, n);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final GptMarkdownThemeData mdTheme = GptMarkdownTheme.of(context);

    Widget md = GptMarkdownTheme(
      gptThemeData: mdTheme.copyWith(
        linkColor: AppTheme.brandBlue,
        linkHoverColor: AppTheme.brandPink,
        highlightColor: theme.colorScheme.primary.withValues(alpha: 0.18),
        h1: theme.textTheme.headlineSmall?.copyWith(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        h2: theme.textTheme.titleLarge?.copyWith(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        h3: theme.textTheme.titleMedium?.copyWith(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        h4: theme.textTheme.titleMedium?.copyWith(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        h5: theme.textTheme.titleSmall?.copyWith(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        h6: theme.textTheme.titleSmall?.copyWith(
          color: AppTheme.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: GptMarkdown(
        _visibleText,
        style: const TextStyle(
          color: Colors.white,
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
    return md;
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

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            color: AppTheme.background,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.terminal_rounded,
                  size: 14,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  lang,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                _CopyButton(text: code),
              ],
            ),
          ),
          Container(
            color: AppTheme.surfaceHigh,
            padding: const EdgeInsets.all(12),
            child: Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: HighlightView(
                  code,
                  language: lang,
                  theme: atomOneDarkTheme.map(
                    (key, value) => MapEntry(
                      key,
                      value.copyWith(backgroundColor: Colors.transparent),
                    ),
                  ),
                  padding: EdgeInsets.zero,
                  textStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
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
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Tooltip(
      message: _copied ? 'Copied!' : 'Tap to copy',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: _copy,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: (widget.style.fontSize ?? 15) * 0.88,
                  color: _copied
                      ? Colors.green
                      : (widget.style.color ?? AppTheme.textPrimary),
                  height: 1.4,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 11,
                color: _copied ? Colors.green : AppTheme.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact copy button with a "Copied!" confirmation state.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: _copy,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 13,
              color: _copied ? Colors.green : AppTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: 11,
                color: _copied ? Colors.green : AppTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
