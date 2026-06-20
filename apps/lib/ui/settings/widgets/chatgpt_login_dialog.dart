import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/services/auth/chatgpt_oauth_flow.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/gradient_text.dart';
import '../../../domain/models/provider_definition.dart';
import '../settings_viewmodel.dart';
import 'add_account_dialog.dart';

/// Dialog that runs the ChatGPT device-code OAuth flow.
///
/// On open it requests a device code, shows the verification URL + user code,
/// opens the browser to the verification page, and polls for completion. On
/// success the dialog closes and the new account appears in the list.
///
/// ChatGPT's device flow does NOT provide a pre-filled URL, so the user
/// must enter the displayed code manually after signing in. There is no
/// callback server and no custom URL scheme — the app just polls until the
/// auth server reports the user completed sign-in.
class ChatGptLoginDialog extends StatefulWidget {
  const ChatGptLoginDialog({super.key, required this.viewModel});

  final SettingsViewModel viewModel;

  @override
  State<ChatGptLoginDialog> createState() => _ChatGptLoginDialogState();
}

class _ChatGptLoginDialogState extends State<ChatGptLoginDialog> {
  DeviceCodeResponse? _deviceCode;
  String _status = 'Starting sign-in…';
  String? _error;
  bool _completing = false;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final DeviceCodeResponse deviceCode = await widget.viewModel
          .startChatGptLogin();
      if (!mounted) return;
      setState(() {
        _deviceCode = deviceCode;
        _status = 'Waiting for sign-in…';
      });
      // Open the verification page so the user can sign in + enter the code.
      await launchUrl(
        Uri.parse(deviceCode.verificationUrl),
        mode: LaunchMode.externalApplication,
      );
      await _poll(deviceCode);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _status = 'Sign-in failed.';
        });
      }
    }
  }

  Future<void> _poll(DeviceCodeResponse deviceCode) async {
    try {
      await widget.viewModel.completeChatGptLogin(
        deviceCode: deviceCode,
        onPolling: () {
          if (mounted) {
            setState(() => _status = 'Waiting for sign-in…');
          }
        },
        shouldCancel: () async => _cancelled,
      );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _status = 'Sign-in failed.';
          _completing = false;
        });
      }
    }
  }

  Future<void> _cancel() async {
    setState(() {
      _cancelled = true;
      _status = 'Cancelling…';
    });
    // The poll loop will see _cancelled and throw ChatGptAuthCancelled.
    // Give it a moment, then close.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final DeviceCodeResponse? dc = _deviceCode;
    return AlertDialog(
      title: const Text('Sign in to ChatGPT'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (dc != null) ...<Widget>[
            Text(
              'A browser window opened to the ChatGPT sign-in page. Sign in, '
              'then enter this code when prompted. This dialog closes '
              'automatically when you\'re done.',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your one-time code:',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            GradientText(
              dc.userCode,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              dc.verificationUrl,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.brandBlue,
                decoration: TextDecoration.underline,
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: <Widget>[
              if (_error == null)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _error ?? _status,
                  style: TextStyle(
                    fontSize: 13,
                    color: _error != null
                        ? AppTheme.brandPink
                        : AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _completing ? null : _cancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Routes an "Add account" tap to the right dialog based on the provider
/// definition's auth requirements.
///
/// - `requiresOAuth` → [ChatGptLoginDialog] (device code flow)
/// - `requiresApiKey` → [AddAccountDialog] (API key form)
///
/// Called from the settings screen's "Add account" action.
void showAddAccountDialog(
  BuildContext context,
  SettingsViewModel viewModel, {
  ProviderDefinition? definition,
}) {
  if (definition != null && definition.requiresOAuth) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) =>
          ChatGptLoginDialog(viewModel: viewModel),
    );
    return;
  }
  showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        AddAccountDialog(viewModel: viewModel, initialDefinition: definition),
  );
}
