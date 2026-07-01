import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      _autoFocusTopic = prefs?.getBool(_autoFocusTopicKey) ?? false;

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
