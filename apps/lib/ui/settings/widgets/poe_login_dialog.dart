import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/services/auth/poe_oauth_redirect.dart';
import '../../core/theme/app_theme.dart';
import '../settings_viewmodel.dart';

class PoeLoginDialog extends StatefulWidget {
  const PoeLoginDialog({super.key, required this.viewModel});

  final SettingsViewModel viewModel;

  @override
  State<PoeLoginDialog> createState() => _PoeLoginDialogState();
}

class _PoeLoginDialogState extends State<PoeLoginDialog> {
  PoeOAuthRedirectListener? _listener;
  bool _busy = false;
  bool _cancelled = false;
  String? _error;

  @override
  void dispose() {
    _cancelled = true;
    _listener?.close();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (kIsWeb) {
        final Uri redirectUri = Uri.base.replace(
          path: '/oauth/poe/callback',
          query: null,
          fragment: null,
        );
        final Uri authorization = await widget.viewModel.startPoeLogin(
          redirectUri,
        );
        final bool opened = await launchUrl(
          authorization,
          webOnlyWindowName: '_self',
        );
        if (!opened) {
          await widget.viewModel.cancelPoeLogin();
          throw StateError('Could not open Poe sign-in.');
        }
        return;
      }

      final PoeOAuthRedirectListener? listener =
          await startPoeOAuthRedirectListener();
      if (listener == null) {
        throw StateError('Poe sign-in is not supported on this platform.');
      }
      _listener = listener;
      final Uri authorization = await widget.viewModel.startPoeLogin(
        listener.redirectUri,
      );
      final bool opened = await launchUrl(
        authorization,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw StateError('Could not open Poe sign-in.');
      }
      final Uri callback = await listener.callbackUri;
      await widget.viewModel.completePoeLogin(callback);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (!_cancelled && mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    } finally {
      await _listener?.close();
      _listener = null;
    }
  }

  Future<void> _cancel() async {
    _cancelled = true;
    await widget.viewModel.cancelPoeLogin();
    await _listener?.close();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bool configured = widget.viewModel.isPoeLoginConfigured;
    return AlertDialog(
      title: const Text('Connect Poe'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              configured
                  ? 'Sign in to let HavenCat use your Poe account and '
                        'subscription points.'
                  : 'Poe sign-in is not configured in this build. Add '
                        'POE_CLIENT_ID when building HavenCat.',
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 13,
              ),
            ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 18),
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Text(
                kIsWeb
                    ? 'Opening Poe…'
                    : 'Finish signing in in your browser, then return here.',
                style: TextStyle(
                  color: context.appColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              SelectableText(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        FilledButton(
          onPressed: configured && !_busy ? _start : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
