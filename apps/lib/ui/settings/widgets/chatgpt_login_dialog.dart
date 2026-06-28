import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// and polls for completion. On success the dialog closes and the new account
/// appears in the list.
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
  DateTime? _expiresAt;
  Timer? _countdown;
  Duration _remaining = Duration.zero;
  String _status = 'Starting…';
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final DeviceCodeResponse deviceCode = await widget.viewModel
          .startChatGptLogin();
      if (!mounted) return;
      _expiresAt = DateTime.now().add(
        const Duration(seconds: DeviceCodeResponse.lifetimeSeconds),
      );
      _remaining = _expiresAt!.difference(DateTime.now());
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _expiresAt == null) return;
        final Duration left = _expiresAt!.difference(DateTime.now());
        setState(
          () => _remaining = left < Duration.zero ? Duration.zero : left,
        );
        if (left <= Duration.zero) _countdown?.cancel();
      });
      setState(() {
        _deviceCode = deviceCode;
        _status = 'Waiting for sign-in';
      });
      await _poll(deviceCode);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _status = 'Sign-in failed';
        });
      }
    }
  }

  Future<void> _poll(DeviceCodeResponse deviceCode) async {
    try {
      await widget.viewModel.completeChatGptLogin(
        deviceCode: deviceCode,
        onPolling: () {
          if (mounted) setState(() => _status = 'Waiting for sign-in');
        },
        shouldCancel: () async => _cancelled,
      );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _status = 'Sign-in failed';
        });
      }
    }
  }

  Future<void> _copyCode(String code) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
      Feedback.forTap(context);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Code copied'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (_) {
      Feedback.forTap(context);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copy failed — select the text manually'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _cancel() async {
    setState(() {
      _cancelled = true;
      _status = 'Cancelling';
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) Navigator.of(context).pop();
  }

  String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final DeviceCodeResponse? dc = _deviceCode;
    final bool expired = _remaining == Duration.zero && dc != null;
    final bool urgent = _remaining.inSeconds <= 60 && !expired;
    return AlertDialog(
      icon: const Icon(Icons.vpn_key_rounded, color: AppTheme.brandViolet),
      title: const Text('Sign in to ChatGPT'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (dc == null)
            _StatusRow(error: _error, status: _status)
          else ...<Widget>[
            Text(
              'Enter this code on the sign-in page. The dialog closes '
              'automatically when you\'re done.',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            SelectionArea(
              child: Tooltip(
                message: 'Tap to copy',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: expired ? null : () => _copyCode(dc.userCode),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        GradientText(
                          dc.userCode,
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 3,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Icon(
                          Icons.copy_rounded,
                          size: 18,
                          color: AppTheme.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => launchUrl(
                Uri.parse(dc.verificationUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.open_in_new_rounded,
                      size: 16,
                      color: AppTheme.brandBlue,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        dc.verificationUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.brandBlue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(
                  urgent ? Icons.timer_rounded : Icons.schedule_rounded,
                  size: 14,
                  color: urgent ? AppTheme.brandPink : AppTheme.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  expired
                      ? 'Code expired — restart'
                      : 'Expires in ${_fmt(_remaining)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: urgent ? AppTheme.brandPink : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _StatusRow(error: _error, status: _status),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.error, required this.status});

  final String? error;
  final String status;

  @override
  Widget build(BuildContext context) {
    final bool hasError = error != null;
    return Row(
      children: <Widget>[
        if (!hasError)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: AppTheme.brandPink,
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            hasError ? (error!.isNotEmpty ? error! : status) : status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: hasError ? AppTheme.brandPink : AppTheme.textSecondary,
            ),
          ),
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
