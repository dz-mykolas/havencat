import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../pricing/pricing_viewmodel.dart';
import 'settings_viewmodel.dart';

class PoeOAuthCallbackScreen extends ConsumerStatefulWidget {
  const PoeOAuthCallbackScreen({
    super.key,
    required this.callbackUri,
    required this.accountsRoute,
  });

  final Uri callbackUri;
  final String accountsRoute;

  @override
  ConsumerState<PoeOAuthCallbackScreen> createState() =>
      _PoeOAuthCallbackScreenState();
}

class _PoeOAuthCallbackScreenState
    extends ConsumerState<PoeOAuthCallbackScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _complete();
  }

  Future<void> _complete() async {
    try {
      await ref
          .read(settingsViewModelProvider)
          .completePoeLogin(widget.callbackUri);
      ref.read(pricingViewModelProvider).setScope(PricingScope.accounts);
      if (mounted) context.go(widget.accountsRoute);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_error == null) ...<Widget>[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 18),
                  const Text('Connecting Poe…'),
                ] else ...<Widget>[
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                    size: 28,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Poe could not be connected',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.appColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () => context.go(widget.accountsRoute),
                    child: const Text('Back to accounts'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
