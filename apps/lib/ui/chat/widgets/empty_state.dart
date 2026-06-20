import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/gradient_text.dart';

/// The home layout shown when the active conversation has no messages: a
/// gradient greeting sitting above center, the message [input] placed just
/// below center, and suggestion chips that prefill the input when tapped.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.onSuggestionTap,
    required this.input,
  });

  final ValueChanged<String> onSuggestionTap;

  /// The message input bar, hosted below center on the home screen.
  final Widget input;

  static const List<String> _suggestions = <String>[
    'Explain a tricky concept simply',
    'Draft a message for me',
    'Brainstorm ideas for a project',
    'Help me debug some code',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // Greeting occupies the upper region and stays anchored just above the
        // input. It can shrink/scroll when the keyboard appears.
        Expanded(
          flex: 6,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _Greeting(),
            ),
          ),
        ),
        const SizedBox(height: 28),
        _Centered(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: input,
          ),
        ),
        const SizedBox(height: 18),
        _Centered(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: _suggestions
                  .map(
                    (String s) => _SuggestionChip(
                      label: s,
                      onTap: () => onSuggestionTap(s),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        // Empty space below keeps the input group sitting below center.
        const Expanded(flex: 4, child: SizedBox()),
      ],
    );
  }
}

/// Constrains [child] to [AppTheme.contentMaxWidth] and centers it
/// horizontally.
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
        child: child,
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppTheme.brandGradient,
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
        ),
        const SizedBox(height: 24),
        GradientText(
          'Hello there',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'How can I help you today?',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.outline),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 14,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}
