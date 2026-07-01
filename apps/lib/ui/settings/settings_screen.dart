import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/fade_slide_in.dart';
import '../../data/services/storage/app_settings.dart';
import '../../providers.dart';
import '../pricing/discover_panel.dart';

/// Settings screen: Discover (catalog + accounts, via the Discover panel's
/// Accounts tab) and Preferences. Account management — adding, activating,
/// removing provider accounts — lives in the Discover panel's Accounts tab
/// now, so this screen no longer hosts an Accounts section or an "Add
/// account" app-bar button.
///
/// Layout is responsive: on desktop/wide screens the content is centered in a
/// fixed-width column (so it doesn't hug the left edge); on phones it's a
/// single edge-to-edge column. Sections animate in with a soft stagger.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTheme.panelMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: <Widget>[
                FadeSlideIn(
                  delay: const Duration(milliseconds: 20),
                  child: _Section(
                    label: 'Discover',
                    child: const _DiscoverCard(),
                  ),
                ),
                const SizedBox(height: 24),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 90),
                  child: _Section(
                    label: 'Preferences',
                    child: _PreferencesCard(settings: settings),
                  ),
                ),
                const SizedBox(height: 24),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 160),
                  child: _Section(
                    label: 'Context compaction',
                    child: _CompactionCard(settings: settings),
                  ),
                ),
                const SizedBox(height: 24),
                const FadeSlideIn(
                  delay: Duration(milliseconds: 230),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: _SecureStorageNote(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled group: a small caption above a content area.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Rounded surface container used to group related controls into a "card".
class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    // A [Material] (not a plain DecoratedBox) so any ListTile/InkWell children
    // paint their background + ink on this surface rather than asserting.
    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding ?? const EdgeInsets.all(6), child: child),
    );
  }
}

/// Bounded-height card hosting the four-tab [DiscoverPanel]. The panel renders
/// its own scrolling content (groups grid + drill-in model list), so we clamp
/// the height — taller on wide screens so the two-up grids breathe, shorter on
/// phones so it doesn't dominate the settings scroll.
class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard();

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final double height = width >= AppTheme.wideBreakpoint ? 560 : 460;
    return _Card(
      padding: const EdgeInsets.all(8),
      child: SizedBox(height: height, child: const DiscoverPanel()),
    );
  }
}

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SwitchListTile(
        value: settings.showHiddenModels,
        onChanged: settings.setShowHiddenModels,
        title: const Text(
          'Show hidden models',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        ),
        subtitle: const Text(
          "Include models providers mark as internal (e.g. ChatGPT's "
          'codex-auto-review). Off by default.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    );
  }
}

class _CompactionCard extends StatelessWidget {
  const _CompactionCard({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: <Widget>[
          SwitchListTile(
            value: settings.redactSecrets,
            onChanged: settings.setRedactSecrets,
            title: const Text(
              'Redact secrets in summaries',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'Strip API keys, tokens, and passwords before the summarizer '
              'sees them. On by default — disable only for debugging.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          SwitchListTile(
            value: settings.temporalAnchoring,
            onChanged: settings.setTemporalAnchoring,
            title: const Text(
              'Temporal anchoring',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'Rewrite "currently doing" into dated past-tense so resumed '
              'chats don\'t re-execute completed actions. On by default.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          SwitchListTile(
            value: settings.antiThrash,
            onChanged: settings.setAntiThrash,
            title: const Text(
              'Anti-thrash guard',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'Back off when a compression pass produces no savings. '
              'On by default.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          SwitchListTile(
            value: settings.staticFallback,
            onChanged: settings.setStaticFallback,
            title: const Text(
              'Static fallback summary',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'Insert a deterministic summary (user asks + tool names + file '
              'paths) when the LLM summary call fails. On by default.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          SwitchListTile(
            value: settings.abortOnSummaryFailure,
            onChanged: settings.setAbortOnSummaryFailure,
            title: const Text(
              'Abort on summary failure',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'Freeze the chat when summarization fails instead of using a '
              'fallback. Off by default — only enable for strict workflows.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          SwitchListTile(
            value: settings.autoFocusTopic,
            onChanged: settings.setAutoFocusTopic,
            title: const Text(
              'Auto focus topic',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'Infer a focus topic from recent turns to prioritize related '
              'info in the summary. Off by default — can be noisy.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          ),
        ],
      ),
    );
  }
}

class _SecureStorageNote extends StatelessWidget {
  const _SecureStorageNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.lock_outline, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "API keys are stored in this device's secure storage and never "
            'leave it except to call the provider directly.',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
