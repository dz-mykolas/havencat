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
      _showHiddenModels =
          prefs?.getBool(_showHiddenModelsKey) ?? false;

  final SharedPreferences? _prefs;

  static const String _showHiddenModelsKey = 'show_hidden_models::v1';

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
}
