import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/services/auth/chatgpt_oauth_flow.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/gradient_text.dart';
import '../settings_viewmodel.dart';

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
  late final AppLifecycleListener _lifecycleListener;
  final _PollingWakeSignal _pollingWakeSignal = _PollingWakeSignal();

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onResume: _pollingWakeSignal.wake,
    );
    _start();
  }

  @override
  void dispose() {
    _cancelled = true;
    _pollingWakeSignal.wake();
    _lifecycleListener.dispose();
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final DeviceCodeResponse deviceCode = await widget.viewModel
          .startChatGptLogin();
      if (!mounted) return;
      _expiresAt = DateTime.now().add(
        Duration(seconds: DeviceCodeResponse.lifetimeSeconds),
      );
      _remaining = _expiresAt!.difference(DateTime.now());
      _countdown = Timer.periodic(Duration(seconds: 1), (_) {
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
        waitForNextPoll: _pollingWakeSignal.wait,
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
    bool copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: code));
      copied = true;
    } on Object {
      copied = false;
    }
    if (!mounted) return;
    await Feedback.forTap(context);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          copied ? 'Code copied' : 'Copy failed — select the text manually',
        ),
        duration: Duration(seconds: copied ? 2 : 3),
      ),
    );
  }

  Future<void> _cancel() async {
    setState(() {
      _cancelled = true;
      _status = 'Cancelling';
    });
    await Future<void>.delayed(Duration(milliseconds: 500));
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
      icon: Icon(Icons.vpn_key_rounded, color: context.appColors.brandViolet),
      title: Text('Sign in to ChatGPT'),
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
              style: TextStyle(
                color: context.appColors.textSecondary,
                fontSize: 13,
              ),
            ),
            SizedBox(height: 16),
            SelectionArea(
              child: Tooltip(
                message: 'Tap to copy',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: expired ? null : () => _copyCode(dc.userCode),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        GradientText(
                          dc.userCode,
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 3,
                          ),
                        ),
                        SizedBox(width: 10),
                        Icon(
                          Icons.copy_rounded,
                          size: 18,
                          color: context.appColors.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => launchUrl(
                Uri.parse(dc.verificationUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: context.appColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 16,
                      color: context.appColors.brandBlue,
                    ),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        dc.verificationUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: context.appColors.brandBlue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(
                  urgent ? Icons.timer_rounded : Icons.schedule_rounded,
                  size: 14,
                  color: urgent
                      ? context.appColors.brandPink
                      : context.appColors.textSecondary,
                ),
                SizedBox(width: 6),
                Text(
                  expired
                      ? 'Code expired — restart'
                      : 'Expires in ${_fmt(_remaining)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: urgent
                        ? context.appColors.brandPink
                        : context.appColors.textSecondary,
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            _StatusRow(error: _error, status: _status),
          ],
        ],
      ),
      actions: <Widget>[TextButton(onPressed: _cancel, child: Text('Cancel'))],
    );
  }
}

class _PollingWakeSignal {
  Completer<void>? _waiter;
  bool _pendingWake = false;

  Future<void> wait(Duration interval) async {
    if (_pendingWake) {
      _pendingWake = false;
      return;
    }

    final Completer<void> waiter = Completer<void>();
    _waiter = waiter;
    final Timer timer = Timer(interval, waiter.complete);
    await waiter.future;
    timer.cancel();
    if (identical(_waiter, waiter)) _waiter = null;
  }

  void wake() {
    final Completer<void>? waiter = _waiter;
    if (waiter == null) {
      _pendingWake = true;
    } else if (!waiter.isCompleted) {
      waiter.complete();
    }
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
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: context.appColors.brandPink,
          ),
        SizedBox(width: 10),
        Expanded(
          child: hasError
              ? SelectableText(
                  error!.isNotEmpty ? error! : status,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.appColors.brandPink,
                  ),
                )
              : Text(
                  status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.appColors.textSecondary,
                  ),
                ),
        ),
      ],
    );
  }
}
