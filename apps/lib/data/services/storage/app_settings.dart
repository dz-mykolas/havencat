import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/models/app_theme_preferences.dart';

/// Global, app-wide user preferences (not tied to any single account).
///
/// Backed by [SharedPreferences] when injected (the running app), with an
/// in-memory fallback for widget tests — mirroring [AccountStore]. Notifies
/// listeners on change so view models can react immediately.
class AppSettings extends ChangeNotifier {
  AppSettings({SharedPreferences? prefs})
    : _prefs = prefs,
      _showHiddenModels = prefs?.getBool(_showHiddenModelsKey) ?? false,
      _redactSecrets = prefs?.getBool(_redactSecretsKey) ?? true,
      _temporalAnchoring = prefs?.getBool(_temporalAnchoringKey) ?? true,
      _antiThrash = prefs?.getBool(_antiThrashKey) ?? true,
      _staticFallback = prefs?.getBool(_staticFallbackKey) ?? true,
      _abortOnSummaryFailure =
          prefs?.getBool(_abortOnSummaryFailureKey) ?? false,
      _autoFocusTopic = prefs?.getBool(_autoFocusTopicKey) ?? false,
      _toolsEnabled = prefs?.getBool(_toolsEnabledKey) ?? false,
      _useDeviceTheme = prefs?.getBool(_useDeviceThemeKey) ?? false,
      _theme = _loadManualTheme(prefs),
      _lightTheme = _loadLightTheme(prefs),
      _darkTheme = _loadDarkTheme(prefs);

  final SharedPreferences? _prefs;

  static const String _showHiddenModelsKey = 'show_hidden_models::v1';
  static const String _redactSecretsKey = 'compaction.redact_secrets::v1';
  static const String _temporalAnchoringKey =
      'compaction.temporal_anchoring::v1';
  static const String _antiThrashKey = 'compaction.anti_thrash::v1';
  static const String _staticFallbackKey = 'compaction.static_fallback::v1';
  static const String _abortOnSummaryFailureKey =
      'compaction.abort_on_summary_failure::v1';
  static const String _autoFocusTopicKey = 'compaction.auto_focus_topic::v1';
  static const String _toolsEnabledKey = 'chat.tools_enabled::v1';
  static const String _legacyThemeSlotKey = 'appearance.theme_slot::v1';
  static const String _useDeviceThemeKey = 'appearance.use_device_theme::v2';
  static const String _themeKey = 'appearance.theme::v2';
  static const String _lightThemeKey = 'appearance.light_theme::v1';
  static const String _darkThemeKey = 'appearance.dark_theme::v1';

  bool _useDeviceTheme;
  AppThemePreset _theme;
  AppThemePreset _lightTheme;
  AppThemePreset _darkTheme;

  bool get useDeviceTheme => _useDeviceTheme;
  AppThemePreset get theme => _theme;
  AppThemePreset get lightTheme => _lightTheme;
  AppThemePreset get darkTheme => _darkTheme;

  static AppThemePreset _loadManualTheme(SharedPreferences? prefs) {
    final String? stored = prefs?.getString(_themeKey);
    if (stored != null) {
      return enumByNameOr(AppThemePreset.values, stored, AppThemePreset.haven);
    }
    final bool legacyLight = prefs?.getString(_legacyThemeSlotKey) == 'light';
    return enumByNameOr(
      AppThemePreset.values,
      prefs?.getString(legacyLight ? _lightThemeKey : _darkThemeKey),
      legacyLight ? AppThemePreset.parchment : AppThemePreset.haven,
    );
  }

  static AppThemePreset _loadLightTheme(SharedPreferences? prefs) {
    final AppThemePreset value = enumByNameOr(
      AppThemePreset.values,
      prefs?.getString(_lightThemeKey),
      AppThemePreset.parchment,
    );
    return value.isDark ? AppThemePreset.parchment : value;
  }

  static AppThemePreset _loadDarkTheme(SharedPreferences? prefs) {
    final AppThemePreset value = enumByNameOr(
      AppThemePreset.values,
      prefs?.getString(_darkThemeKey),
      AppThemePreset.haven,
    );
    return value.isDark ? value : AppThemePreset.haven;
  }

  Future<void> setUseDeviceTheme(bool value) async {
    if (value == _useDeviceTheme) return;
    _useDeviceTheme = value;
    notifyListeners();
    await _prefs?.setBool(_useDeviceThemeKey, value);
  }

  Future<void> setTheme(AppThemePreset value) async {
    if (value == _theme) return;
    _theme = value;
    notifyListeners();
    await _prefs?.setString(_themeKey, value.name);
  }

  Future<void> setLightTheme(AppThemePreset value) async {
    if (value.isDark) {
      throw ArgumentError.value(value, 'value', 'Must be a light theme.');
    }
    if (value == _lightTheme) return;
    _lightTheme = value;
    notifyListeners();
    await _prefs?.setString(_lightThemeKey, value.name);
  }

  Future<void> setDarkTheme(AppThemePreset value) async {
    if (!value.isDark) {
      throw ArgumentError.value(value, 'value', 'Must be a dark theme.');
    }
    if (value == _darkTheme) return;
    _darkTheme = value;
    notifyListeners();
    await _prefs?.setString(_darkThemeKey, value.name);
  }

  bool _showHiddenModels;

  /// Whether provider-hidden/internal models (e.g. ChatGPT's
  /// `codex-auto-review`) are shown in the model picker. Off by default.
  bool get showHiddenModels => _showHiddenModels;

  Future<void> setShowHiddenModels(bool value) async {
    if (value == _showHiddenModels) return;
    _showHiddenModels = value;
    notifyListeners();
    await _prefs?.setBool(_showHiddenModelsKey, value);
  }

  bool _toolsEnabled;

  bool get toolsEnabled => _toolsEnabled;

  Future<void> setToolsEnabled(bool value) async {
    if (value == _toolsEnabled) return;
    _toolsEnabled = value;
    notifyListeners();
    await _prefs?.setBool(_toolsEnabledKey, value);
  }

  // ── Compaction settings ──────────────────────────────────────────────────

  bool _redactSecrets;

  /// Whether API keys, tokens, and passwords are redacted to `[REDACTED]`
  /// before being sent to the summarizer LLM and persisted in the summary.
  /// On by default. Disable only if you need raw secrets preserved for
  /// debugging — the summary is sent to the LLM provider and stored on disk.
  bool get redactSecrets => _redactSecrets;

  Future<void> setRedactSecrets(bool value) async {
    if (value == _redactSecrets) return;
    _redactSecrets = value;
    notifyListeners();
    await _prefs?.setBool(_redactSecretsKey, value);
  }

  bool _temporalAnchoring;

  /// Whether the summarizer rewrites relative/pending references into
  /// absolute dated past-tense facts (e.g. "currently doing X" → "on
  /// 2026-06-30, did X") so a resumed conversation doesn't re-execute
  /// completed actions. On by default.
  bool get temporalAnchoring => _temporalAnchoring;

  Future<void> setTemporalAnchoring(bool value) async {
    if (value == _temporalAnchoring) return;
    _temporalAnchoring = value;
    notifyListeners();
    await _prefs?.setBool(_temporalAnchoringKey, value);
  }

  bool _antiThrash;

  /// Whether the compactor tracks ineffective compressions and backs off
  /// when a compression pass produces no savings (prevents no-op loops).
  /// On by default.
  bool get antiThrash => _antiThrash;

  Future<void> setAntiThrash(bool value) async {
    if (value == _antiThrash) return;
    _antiThrash = value;
    notifyListeners();
    await _prefs?.setBool(_antiThrashKey, value);
  }

  bool _staticFallback;

  /// Whether a deterministic fallback summary (built from user asks + tool
  /// names + file paths) is inserted when the LLM summary call fails. On by
  /// default. When off, a failed summary falls back to the cleared history.
  bool get staticFallback => _staticFallback;

  Future<void> setStaticFallback(bool value) async {
    if (value == _staticFallback) return;
    _staticFallback = value;
    notifyListeners();
    await _prefs?.setBool(_staticFallbackKey, value);
  }

  bool _abortOnSummaryFailure;

  /// When true, a failed summary call aborts compression entirely (returns
  /// messages unchanged, freezes the chat until manual retry). When false
  /// (default), a static fallback is inserted and the conversation continues.
  bool get abortOnSummaryFailure => _abortOnSummaryFailure;

  Future<void> setAbortOnSummaryFailure(bool value) async {
    if (value == _abortOnSummaryFailure) return;
    _abortOnSummaryFailure = value;
    notifyListeners();
    await _prefs?.setBool(_abortOnSummaryFailureKey, value);
  }

  bool _autoFocusTopic;

  /// Whether the compactor auto-infers a focus topic from recent user turns
  /// to prioritize preserving related info in the summary. Off by default —
  /// can be noisy. Use explicit `/compact <focus>` for reliable control.
  bool get autoFocusTopic => _autoFocusTopic;

  Future<void> setAutoFocusTopic(bool value) async {
    if (value == _autoFocusTopic) return;
    _autoFocusTopic = value;
    notifyListeners();
    await _prefs?.setBool(_autoFocusTopicKey, value);
  }
}
