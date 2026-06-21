import 'package:flutter/material.dart';

import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/provider_definition.dart';
import '../../core/theme/app_theme.dart';
import '../../settings/settings_viewmodel.dart';

/// Dialog for adding a custom provider endpoint — any OpenAI-compatible,
/// Anthropic, or Gemini API the user wants to wire up by hand (e.g. a
/// self-hosted vLLM server, a proxy, a regional Anthropic endpoint).
///
/// Unlike [AddAccountDialog] (which starts from a known [ProviderDefinition]
/// and prefills its config template), this dialog lets the user pick the
/// adapter family first, then fills in display name / base URL / API key /
/// model from scratch. On submit it calls
/// [SettingsViewModel.addApiKeyAccount] with the matching definition id
/// (`openai_compatible`, `anthropic`, or `gemini_native`).
class CustomEndpointDialog extends StatefulWidget {
  const CustomEndpointDialog({super.key, required this.viewModel});

  final SettingsViewModel viewModel;

  @override
  State<CustomEndpointDialog> createState() => _CustomEndpointDialogState();
}

class _CustomEndpointDialogState extends State<CustomEndpointDialog> {
  /// The three adapter families a custom endpoint can target. Ordered to
  /// match [ProviderCatalog.apiKey] minus the generic fallback ordering —
  /// OpenAI-compatible first because it's by far the most common case
  /// (Ollama, vLLM, OpenRouter, custom proxies…).
  static const List<_AdapterOption> _adapters = <_AdapterOption>[
    _AdapterOption(
      definitionId: 'openai_compatible',
      label: 'OpenAI-compatible',
      hint: 'Any /v1/chat/completions endpoint (OpenAI, Ollama, vLLM…)',
      defaultBaseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-4o-mini',
      showBaseUrl: true,
    ),
    _AdapterOption(
      definitionId: 'anthropic',
      label: 'Anthropic',
      hint: 'Claude Messages API (api.anthropic.com)',
      defaultBaseUrl: 'https://api.anthropic.com',
      defaultModel: 'claude-3-5-sonnet-latest',
      showBaseUrl: true,
    ),
    _AdapterOption(
      definitionId: 'gemini_native',
      label: 'Gemini',
      hint: 'Google Gemini native API',
      defaultBaseUrl: '',
      defaultModel: 'gemini-1.5-flash',
      showBaseUrl: false,
    ),
  ];

  _AdapterOption _adapter = _adapters.first;
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
    _key.addListener(_onChanged);
    _applyAdapterDefaults();
  }

  void _applyAdapterDefaults() {
    _baseUrl.text = _adapter.defaultBaseUrl;
    _model.text = _adapter.defaultModel;
  }

  void _onAdapterChanged(_AdapterOption? next) {
    if (next == null) return;
    setState(() {
      _adapter = next;
      _error = null;
      _applyAdapterDefaults();
    });
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _canSubmit {
    if (_saving) return false;
    if (_name.text.trim().isEmpty || _key.text.trim().isEmpty) return false;
    if (_adapter.showBaseUrl && _baseUrl.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Map<String, Object?> config = <String, Object?>{};
      if (_adapter.showBaseUrl) {
        final String url = _baseUrl.text.trim();
        if (url.isNotEmpty) config['baseUrl'] = url;
      }
      final String model = _model.text.trim();
      if (model.isNotEmpty) config['model'] = model;
      await widget.viewModel.addApiKeyAccount(
        definitionId: _adapter.definitionId,
        displayName: _name.text.trim(),
        apiKey: _key.text.trim(),
        config: config.isEmpty ? null : config,
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
      title: const Text('Custom endpoint'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<_AdapterOption>(
              initialValue: _adapter,
              decoration: const InputDecoration(
                labelText: 'Adapter',
                border: OutlineInputBorder(),
              ),
              items: _adapters
                  .map(
                    (_AdapterOption a) => DropdownMenuItem<_AdapterOption>(
                      value: a,
                      child: Text(a.label),
                    ),
                  )
                  .toList(),
              onChanged: _saving ? null : _onAdapterChanged,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                _adapter.hint,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'API key',
                border: OutlineInputBorder(),
              ),
            ),
            if (_adapter.showBaseUrl) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Default model',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppTheme.brandPink)),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

class _AdapterOption {
  const _AdapterOption({
    required this.definitionId,
    required this.label,
    required this.hint,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.showBaseUrl,
  });

  final String definitionId;
  final String label;
  final String hint;
  final String defaultBaseUrl;
  final String defaultModel;
  final bool showBaseUrl;
}

/// Convenience for callers that just want to pop the dialog up.
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

/// The [AdapterKind] a custom endpoint maps to, for callers that want to
/// label chips or group accounts. Resolved from the definition id.
AdapterKind adapterKindForDefinitionId(String id) {
  switch (id) {
    case 'openai_compatible':
      return AdapterKind.openaiCompatible;
    case 'anthropic':
      return AdapterKind.anthropic;
    case 'gemini_native':
      return AdapterKind.geminiNative;
    case 'chatgpt_subscription':
    case 'poe_subscription':
      return AdapterKind.subscription;
    default:
      return AdapterKind.openaiCompatible;
  }
}
