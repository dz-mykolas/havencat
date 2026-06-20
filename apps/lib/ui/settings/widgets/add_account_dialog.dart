import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../../domain/models/provider_definition.dart';
import '../settings_viewmodel.dart';

/// Dialog form for adding an API-key provider account.
///
/// The user picks a provider from [SettingsViewModel.apiKeyCatalog], enters a
/// display name + API key, and may override the default base URL / model from
/// the provider's [ProviderDefinition.configTemplate]. On submit the dialog
/// calls [SettingsViewModel.addApiKeyAccount], which writes the key to
/// `SecretStore` and adds the account to the repository.
class AddAccountDialog extends StatefulWidget {
  const AddAccountDialog({
    super.key,
    required this.viewModel,
    this.initialDefinition,
  });

  final SettingsViewModel viewModel;
  final ProviderDefinition? initialDefinition;

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  String? _definitionId;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onFieldChanged);
    _keyController.addListener(_onFieldChanged);
    // Pre-select if the router passed an initial definition (e.g. user picked
    // a specific provider from a menu).
    final ProviderDefinition? initial = widget.initialDefinition;
    if (initial != null) {
      _onDefinitionChanged(initial.id);
    }
  }

  ProviderDefinition? get _definition {
    final String? id = _definitionId;
    if (id == null) return null;
    for (final ProviderDefinition d in widget.viewModel.apiKeyCatalog) {
      if (d.id == id) return d;
    }
    return null;
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  void _onDefinitionChanged(String? id) {
    setState(() {
      _definitionId = id;
      _error = null;
      final ProviderDefinition? def = _definition;
      _nameController.text = def?.displayName ?? '';
      _baseUrlController.text =
          (def?.configTemplate['baseUrl'] as String?) ?? '';
      _modelController.text = (def?.configTemplate['model'] as String?) ?? '';
    });
  }

  bool get _canSubmit {
    if (_saving || _definition == null) return false;
    return _nameController.text.trim().isNotEmpty &&
        _keyController.text.trim().isNotEmpty;
  }

  Future<void> _submit() async {
    final ProviderDefinition? def = _definition;
    if (def == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Map<String, Object?> config = <String, Object?>{};
      final String baseUrl = _baseUrlController.text.trim();
      final String model = _modelController.text.trim();
      if (baseUrl.isNotEmpty) config['baseUrl'] = baseUrl;
      if (model.isNotEmpty) config['model'] = model;
      await widget.viewModel.addApiKeyAccount(
        definitionId: def.id,
        displayName: _nameController.text.trim(),
        apiKey: _keyController.text.trim(),
        config: config.isEmpty ? null : config,
      );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not add account: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _keyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ProviderDefinition? def = _definition;
    final bool showBaseUrl =
        def?.configTemplate.containsKey('baseUrl') ?? false;
    final bool showModel = def?.configTemplate.containsKey('model') ?? false;
    return AlertDialog(
      title: const Text('Add account'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              initialValue: _definitionId,
              decoration: const InputDecoration(
                labelText: 'Provider',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Select a provider'),
              items: widget.viewModel.apiKeyCatalog
                  .map(
                    (ProviderDefinition d) => DropdownMenuItem<String>(
                      value: d.id,
                      child: Text(d.displayName),
                    ),
                  )
                  .toList(),
              onChanged: _saving ? null : _onDefinitionChanged,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'API key',
                border: OutlineInputBorder(),
              ),
            ),
            if (showBaseUrl) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            if (showModel) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
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
