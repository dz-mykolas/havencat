import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/models/model_pricing.dart';

/// Fetches and caches the public model database from models.dev.
///
/// The endpoint (`https://models.dev/api.json`) is a single ~2.4 MB JSON blob
/// served with `Access-Control-Allow-Origin: *`, so the web build can hit it
/// directly — no LLM proxy needed. Because it's large and rarely changes, we:
///   1. keep an in-memory [ModelsCatalog] for the session,
///   2. persist the raw JSON (+ fetch time) to [SharedPreferences] so a restart
///      / browser refresh shows data instantly and works offline, and
///   3. only re-fetch from the network when the cache is older than [_ttl] (or
///      when the caller forces a refresh).
class ModelsDevService {
  // Private fields can't be named initializing formals (`this._prefs`), so we
  // assign in the initializer list and keep the public `prefs:` parameter.
  ModelsDevService({Dio? dio, SharedPreferences? prefs})
    : _dio = dio ?? Dio(),
      // ignore: prefer_initializing_formals
      _prefs = prefs;

  static const String endpoint = 'https://models.dev/api.json';
  static const String _cacheKey = 'models_dev_cache::v1';
  static const String _cacheAtKey = 'models_dev_cached_at::v1';
  static const Duration _ttl = Duration(hours: 12);

  final Dio _dio;
  final SharedPreferences? _prefs;

  ModelsCatalog? _memory;

  /// Returns the catalog, preferring a fresh in-memory/persisted copy and only
  /// going to the network when the cache is stale or [forceRefresh] is set.
  ///
  /// Throws if there is no usable cache *and* the network request fails, so the
  /// UI can show an error + retry. If a stale cache exists but the refresh
  /// fails, the stale cache is returned (better than nothing / offline).
  Future<ModelsCatalog> load({bool forceRefresh = false}) async {
    final ModelsCatalog? cached = _memory ?? _readPersisted();
    _memory ??= cached;

    final bool fresh =
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _ttl;
    if (cached != null && fresh && !forceRefresh) {
      return cached;
    }

    try {
      return await _fetch();
    } catch (_) {
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<ModelsCatalog> refresh() => load(forceRefresh: true);

  Future<ModelsCatalog> _fetch() async {
    final Response<Object?> response = await _dio.get<Object?>(
      endpoint,
      options: Options(responseType: ResponseType.plain),
    );
    final Object? body = response.data;
    final String raw = body is String ? body : jsonEncode(body);
    final DateTime now = DateTime.now();
    final ModelsCatalog catalog = _parse(raw, now);
    _memory = catalog;
    await _persist(raw, now);
    return catalog;
  }

  ModelsCatalog _parse(String raw, DateTime fetchedAt) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('models.dev: unexpected payload shape');
    }
    return ModelsCatalog.fromApiJson(decoded, fetchedAt: fetchedAt);
  }

  ModelsCatalog? _readPersisted() {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return null;
    final String? raw = prefs.getString(_cacheKey);
    final int? atMs = prefs.getInt(_cacheAtKey);
    if (raw == null || atMs == null) return null;
    try {
      return _parse(raw, DateTime.fromMillisecondsSinceEpoch(atMs));
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist(String raw, DateTime at) async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(_cacheKey, raw);
    await prefs.setInt(_cacheAtKey, at.millisecondsSinceEpoch);
  }
}
