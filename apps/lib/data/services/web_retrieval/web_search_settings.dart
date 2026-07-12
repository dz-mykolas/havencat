import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/errors/app_failure.dart';
import '../auth/secret_store.dart';
import 'web_retrieval.dart';
import 'web_retrieval_failure_mapper.dart';
import 'web_retrieval_provider_registry.dart';

class WebSearchProviderPreference {
  const WebSearchProviderPreference({
    required this.kind,
    required this.enabled,
    required this.hasApiKey,
    this.instanceUrl,
  });

  final String kind;
  final bool enabled;
  final bool hasApiKey;
  final String? instanceUrl;

  WebSearchProviderPreference copyWith({
    bool? enabled,
    bool? hasApiKey,
    String? instanceUrl,
  }) => WebSearchProviderPreference(
    kind: kind,
    enabled: enabled ?? this.enabled,
    hasApiKey: hasApiKey ?? this.hasApiKey,
    instanceUrl: instanceUrl ?? this.instanceUrl,
  );
}

class WebSearchSettings extends ChangeNotifier {
  WebSearchSettings({
    required SharedPreferences? preferences,
    required this.secrets,
    required this.adapter,
  }) : _preferences = preferences,
       _providers = _loadMetadata(preferences);

  static const String _preferencesKey = 'web_search.providers::v1';
  static const String _secretPrefix = 'web_search_provider::';
  static const WebRetrievalProviderRegistry _registry =
      WebRetrievalProviderRegistry();
  static const WebRetrievalFailureMapper _failureMapper =
      WebRetrievalFailureMapper();

  final SharedPreferences? _preferences;
  final SecretStore secrets;
  final WebRetrievalAdapter adapter;
  final Map<String, WebSearchProviderPreference> _providers;
  final Map<String, String> _apiKeys = <String, String>{};

  bool _initialized = false;
  bool _applying = false;
  AppFailure? _lastFailure;

  bool get initialized => _initialized;
  bool get applying => _applying;
  AppFailure? get lastFailure => _lastFailure;

  List<WebSearchProviderPreference> get providers =>
      WebRetrievalProviderRegistry.searchProviders
          .map(
            (WebSearchProviderDefinition definition) =>
                _providers[definition.kind] ?? _defaultFor(definition.kind),
          )
          .toList(growable: false);

  WebSearchProviderPreference preferenceFor(String kind) =>
      _providers[kind] ?? _defaultFor(kind);

  Future<void> initialize() async {
    if (_initialized) return;
    for (final WebSearchProviderDefinition definition
        in WebRetrievalProviderRegistry.searchProviders) {
      final String? key = await secrets.read(
        '$_secretPrefix${definition.kind}',
      );
      if (key != null && key.isNotEmpty) _apiKeys[definition.kind] = key;
      final WebSearchProviderPreference current = preferenceFor(
        definition.kind,
      );
      _providers[definition.kind] = current.copyWith(
        hasApiKey: _apiKeys.containsKey(definition.kind),
      );
    }
    try {
      await _apply();
    } on Object catch (error) {
      _lastFailure = _failureMapper.fromException(
        error,
        subsystem: AppSubsystem.webSearch,
        operation: 'configure',
      );
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> setEnabled(String kind, bool enabled) {
    final WebSearchProviderPreference current = preferenceFor(kind);
    return saveProvider(
      kind: kind,
      enabled: enabled,
      instanceUrl: current.instanceUrl,
    );
  }

  Future<void> reapply() async {
    _applying = true;
    _lastFailure = null;
    notifyListeners();
    try {
      await _apply();
    } on Object catch (error) {
      _lastFailure = _failureMapper.fromException(
        error,
        subsystem: AppSubsystem.webSearch,
        operation: 'configure',
      );
      throw _lastFailure!;
    } finally {
      _applying = false;
      notifyListeners();
    }
  }

  Future<void> saveProvider({
    required String kind,
    required bool enabled,
    String? apiKey,
    bool clearApiKey = false,
    String? instanceUrl,
  }) async {
    final WebSearchProviderPreference previous = preferenceFor(kind);
    final String? normalizedUrl = instanceUrl?.trim().isEmpty == true
        ? null
        : instanceUrl?.trim();
    String? nextKey = _apiKeys[kind];
    if (clearApiKey) nextKey = null;
    if (apiKey != null && apiKey.trim().isNotEmpty) nextKey = apiKey.trim();
    final WebSearchProviderPreference next = WebSearchProviderPreference(
      kind: kind,
      enabled: enabled,
      hasApiKey: nextKey != null,
      instanceUrl: normalizedUrl,
    );
    final Map<String, WebSearchProviderPreference> candidate =
        Map<String, WebSearchProviderPreference>.from(_providers)
          ..[kind] = next;
    final Map<String, String> candidateKeys = Map<String, String>.from(
      _apiKeys,
    );
    final Map<String, String> previousKeys = Map<String, String>.from(_apiKeys);
    if (nextKey == null) {
      candidateKeys.remove(kind);
    } else {
      candidateKeys[kind] = nextKey;
    }
    _buildSearchSlots(candidate, candidateKeys);

    _providers[kind] = next;
    _apiKeys
      ..clear()
      ..addAll(candidateKeys);
    _applying = true;
    _lastFailure = null;
    notifyListeners();
    try {
      await _apply();
    } on Object catch (error) {
      _providers[kind] = previous;
      _apiKeys
        ..clear()
        ..addAll(previousKeys);
      _lastFailure = _failureMapper.fromException(
        error,
        subsystem: AppSubsystem.webSearch,
        operation: 'configure',
        provider: kind,
      );
      throw _lastFailure!;
    }
    try {
      if (nextKey == null) {
        await secrets.delete('$_secretPrefix$kind');
      } else if (nextKey != previousKeys[kind]) {
        await secrets.write('$_secretPrefix$kind', nextKey);
      }
      await _persistMetadata();
    } on Object catch (error) {
      _lastFailure = _failureMapper.fromException(
        error,
        subsystem: AppSubsystem.storage,
        operation: 'save_web_search_settings',
        provider: kind,
      );
      throw _lastFailure!;
    } finally {
      _applying = false;
      notifyListeners();
    }
  }

  Future<void> _apply() async {
    if (adapter is! WebRetrievalConfigurator) {
      throw const AppFailure(
        kind: FailureKind.unavailable,
        source: FailureSource(
          subsystem: AppSubsystem.webSearch,
          operation: 'configure',
        ),
        message: 'The web-search backend cannot be configured.',
      );
    }
    await (adapter as WebRetrievalConfigurator).configureProviders(
      searchProviders: _buildSearchSlots(_providers, _apiKeys),
      fetchProviders: _registry.normalizeFetch(const <ProviderSlotConfig>[]),
    );
  }

  List<ProviderSlotConfig> _buildSearchSlots(
    Map<String, WebSearchProviderPreference> preferences,
    Map<String, String> keys,
  ) {
    final List<ProviderSlotConfig> slots = preferences.values
        .where((WebSearchProviderPreference preference) => preference.enabled)
        .map((WebSearchProviderPreference preference) {
          final String? value = preference.kind == 'searxng'
              ? preference.instanceUrl
              : keys[preference.kind];
          return ProviderSlotConfig(kind: preference.kind, secret: value);
        })
        .toList();
    if (slots.isEmpty) {
      throw const AppFailure(
        kind: FailureKind.invalidRequest,
        source: FailureSource(
          subsystem: AppSubsystem.webSearch,
          operation: 'configure',
        ),
        message: 'Keep at least one web-search provider enabled.',
      );
    }
    try {
      return _registry.normalizeSearch(slots);
    } on FormatException catch (error) {
      throw AppFailure(
        kind: FailureKind.invalidRequest,
        source: const FailureSource(
          subsystem: AppSubsystem.webSearch,
          operation: 'configure',
        ),
        message: error.message,
      );
    }
  }

  Future<void> _persistMetadata() async {
    await _preferences?.setString(
      _preferencesKey,
      jsonEncode(<String, Object?>{
        for (final WebSearchProviderPreference provider in _providers.values)
          provider.kind: <String, Object?>{
            'enabled': provider.enabled,
            if (provider.instanceUrl != null)
              'instance_url': provider.instanceUrl,
          },
      }),
    );
  }

  static Map<String, WebSearchProviderPreference> _loadMetadata(
    SharedPreferences? preferences,
  ) {
    final Map<String, WebSearchProviderPreference> result =
        <String, WebSearchProviderPreference>{
          for (final WebSearchProviderDefinition definition
              in WebRetrievalProviderRegistry.searchProviders)
            definition.kind: _defaultFor(definition.kind),
        };
    final String? raw = preferences?.getString(_preferencesKey);
    if (raw == null) return result;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return result;
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final String kind = entry.key as String;
        if (!result.containsKey(kind)) continue;
        final Map<Object?, Object?> value =
            entry.value! as Map<Object?, Object?>;
        result[kind] = WebSearchProviderPreference(
          kind: kind,
          enabled: value['enabled'] as bool? ?? false,
          hasApiKey: false,
          instanceUrl: value['instance_url'] as String?,
        );
      }
    } on Object {
      return result;
    }
    return result;
  }

  static WebSearchProviderPreference _defaultFor(String kind) =>
      WebSearchProviderPreference(
        kind: kind,
        enabled: kind == 'exa',
        hasApiKey: false,
      );
}
