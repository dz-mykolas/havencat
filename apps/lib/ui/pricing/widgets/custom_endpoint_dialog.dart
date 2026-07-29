import 'package:flutter/material.dart';

import '../../../data/services/web_retrieval/web_retrieval_endpoint_policy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_scroll_view.dart';
import '../../core/widgets/credential_security_button.dart';
import '../../settings/settings_viewmodel.dart';

class CustomEndpointDialog extends StatefulWidget {
  const CustomEndpointDialog({super.key, required this.viewModel});

  final SettingsViewModel viewModel;

  @override
  State<CustomEndpointDialog> createState() => _CustomEndpointDialogState();
}

class _CustomEndpointDialogState extends State<CustomEndpointDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _baseUrl = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _model = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onChanged);
    _baseUrl.addListener(_onChanged);
    _key.addListener(_onChanged);
    _model.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _canSubmit =>
      !_saving &&
      _name.text.trim().isNotEmpty &&
      _baseUrl.text.trim().isNotEmpty &&
      _model.text.trim().isNotEmpty &&
      _baseUrlError == null;

  String? get _baseUrlError {
    final String value = _baseUrl.text.trim();
    if (value.isEmpty) return null;
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        !(uri.isScheme('https') || uri.isScheme('http'))) {
      return 'Enter a full HTTP or HTTPS URL.';
    }
    final WebEndpointScope scope = WebRetrievalEndpointPolicy.classifyHost(
      uri.host,
    );
    if (scope == WebEndpointScope.invalid) {
      return 'Enter a valid endpoint URL.';
    }
    if (uri.isScheme('https')) return null;
    if (scope == WebEndpointScope.publicNetwork) {
      return 'Public endpoints require HTTPS.';
    }
    if (_key.text.trim().isNotEmpty && scope != WebEndpointScope.loopback) {
      return 'API keys require HTTPS outside this device.';
    }
    return null;
  }

  bool get _showLocalHttpWarning {
    if (_baseUrlError != null) return false;
    final Uri? uri = Uri.tryParse(_baseUrl.text.trim());
    if (uri == null || !uri.isScheme('http')) return false;
    return WebRetrievalEndpointPolicy.classifyHost(uri.host) ==
        WebEndpointScope.privateNetwork;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.viewModel.addApiKeyAccount(
        definitionId: 'openai_compatible',
        displayName: _name.text.trim(),
        apiKey: _key.text.trim(),
        config: <String, Object?>{
          'baseUrl': _baseUrl.text.trim(),
          'model': _model.text.trim(),
          'providerName': 'Custom endpoint',
          'enabledModels': <String>[_model.text.trim()],
        },
      );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not add endpoint: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Custom endpoint'),
      content: AppScrollView(
        builder: (BuildContext context, AppScrollController controller) =>
            SingleChildScrollView(
              controller: controller,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Connect an OpenAI-compatible hosted or local endpoint.',
                    style: TextStyle(
                      color: context.appColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(height: 14),
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(
                      labelText: 'Display name',
                      hintText: 'Local Ollama',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'http://localhost:11434/v1',
                      errorText: _baseUrlError,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_showLocalHttpWarning) ...<Widget>[
                    SizedBox(height: 5),
                    Text(
                      'Local HTTP traffic is unencrypted and may be visible '
                      'to others on this network.',
                      style: TextStyle(
                        color: context.appColors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                  SizedBox(height: 12),
                  TextField(
                    controller: _model,
                    decoration: InputDecoration(
                      labelText: 'Model',
                      hintText: 'llama3.2',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'API key (optional)',
                      border: OutlineInputBorder(),
                      suffixIcon: CredentialSecurityButton(),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(color: context.appColors.brandPink),
                    ),
                  ],
                ],
              ),
            ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: _saving
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Connect'),
        ),
      ],
    );
  }
}

Future<void> showCustomEndpointDialog(
  BuildContext context,
  SettingsViewModel viewModel,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        CustomEndpointDialog(viewModel: viewModel),
  );
}
