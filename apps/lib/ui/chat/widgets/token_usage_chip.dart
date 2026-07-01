import 'package:flutter/material.dart';

/// Token-usage indicator for the app bar.
///
/// Three visual states:
///  * **Generating** — a subtle pulsing opacity animation signals the count
///    is live/updating. The number shown is the estimate (or the last actual
///    if the provider reported one on a prior turn).
///  * **Idle + actual** — solid text, no animation. The provider reported
///    the real `prompt_tokens` for the last completed request.
///  * **Idle + estimate only** — prefixed with `~` to signal the number is
///    always approximate (provider never reports usage, e.g. Ollama).
///
/// The chip is hidden entirely until the first request is sent.
class TokenUsageChip extends StatefulWidget {
  const TokenUsageChip({
    super.key,
    required this.actualTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.estimatedTokens,
    required this.contextWindow,
    required this.isGenerating,
  });

  /// Real `prompt_tokens`/`input_tokens` reported by the provider for the
  /// last completed request. Null when the provider doesn't report usage or
  /// before the first reply completes.
  final int? actualTokens;

  /// Real `completion_tokens`/`output_tokens` reported by the provider for
  /// the last completed request. Null when the provider doesn't report
  /// usage or before the first reply completes.
  final int? completionTokens;

  /// Real `total_tokens` (input + output) reported by the provider for the
  /// last completed request. Null when the provider doesn't report usage or
  /// before the first reply completes.
  final int? totalTokens;

  /// Our char/4 estimate for the current/last request. Set immediately on
  /// send so the chip never lags a turn behind.
  final int? estimatedTokens;

  /// The model's context window in tokens.
  final int contextWindow;

  /// Whether a request is currently streaming.
  final bool isGenerating;

  @override
  State<TokenUsageChip> createState() => _TokenUsageChipState();
}

class _TokenUsageChipState extends State<TokenUsageChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _opacity =
        Tween<double>(begin: 0.45, end: 1.0).animate(
          CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _pulse.reverse();
          if (status == AnimationStatus.dismissed) _pulse.forward();
        });
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant TokenUsageChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isGenerating != widget.isGenerating) _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.isGenerating) {
      _pulse.forward();
    } else {
      _pulse.stop();
      _pulse.value = 1.0; // fully opaque when idle
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String _format(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return n.toString();
  }

  /// Compact formatting with k/M/B suffixes. Truncates (not rounds) to 1
  /// decimal, then drops the decimal entirely if < 0.5 — so 1.05M → 1M,
  /// 1.49M → 1.4M, 1.5M → 1.5M, 1.9M → 1.9M, 2M → 2M.
  String _formatCompact(int n) {
    const List<String> suffixes = <String>['', 'k', 'M', 'B', 'T'];
    if (n < 1000) return n.toString();
    int i = 0;
    double v = n.toDouble();
    while (v >= 1000 && i < suffixes.length - 1) {
      v /= 1000;
      i++;
    }
    // Truncate to 1 decimal place (floor, not round).
    final int tenths = (v * 10).floor() % 10;
    final int whole = v.floor();
    if (tenths == 0) return '$whole${suffixes[i]}';
    return '$whole.$tenths${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final int? prompt = widget.actualTokens;
    final int? completion = widget.completionTokens;
    final int? total = widget.totalTokens;
    final int? estimate = widget.estimatedTokens;

    // Main displayed value: total tokens when available, otherwise fall back
    // to the input estimate (the estimate only covers input/prompt tokens, so
    // it's a lower bound during generation).
    final int? value = widget.isGenerating
        ? (estimate ?? total)
        : (total ?? estimate);
    if (value == null) return const SizedBox.shrink();

    // "Confirmed" = we're showing the provider-reported total for the
    // current/last request. During generation that's never true (the actual
    // is stale), so the chip shows the estimate icon even if a prior actual
    // exists.
    final bool confirmed = !widget.isGenerating && total != null;
    final Color baseColor = Theme.of(context).colorScheme.onSurfaceVariant;
    // Dim the chip slightly so the model selector stands out as the primary
    // affordance in the input bar.
    final Color color = baseColor.withValues(alpha: 0.6);
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: color);

    final String prefix = confirmed ? '' : '~';
    final String statusLine = widget.isGenerating
        ? 'Estimated (live)'
        : (confirmed ? 'Confirmed usage' : 'Estimated (no usage reported)');

    // Enriched tooltip: status + input/output/total breakdown + context.
    final StringBuffer tip = StringBuffer(statusLine);
    tip.writeln();
    tip.write('Input: ');
    tip.write(prompt != null ? _format(prompt) : '—');
    tip.writeln();
    tip.write('Output: ');
    tip.write(completion != null ? _format(completion) : '—');
    tip.writeln();
    tip.write('Total: ');
    tip.write(total != null ? _format(total) : '~${_format(value)}');
    tip.writeln();
    tip.write('Context: ${_format(widget.contextWindow)}');
    final String tooltip = tip.toString();

    final Widget content = Text(
      '$prefix${_formatCompact(value)} / ${_formatCompact(widget.contextWindow)}',
      style: style,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: Tooltip(
          message: tooltip,
          child: widget.isGenerating
              ? AnimatedBuilder(
                  animation: _opacity,
                  builder: (context, child) =>
                      Opacity(opacity: _opacity.value, child: child),
                  child: content,
                )
              : content,
        ),
      ),
    );
  }
}
