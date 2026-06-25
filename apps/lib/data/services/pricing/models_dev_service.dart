import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../domain/models/model_pricing.dart';

/// Fetches and caches the public model database from models.dev.
///
/// The endpoint (`https://models.dev/catalog.json`) is a single JSON blob
/// served with `Access-Control-Allow-Origin: *`, so the web build can hit it
/// directly — no LLM proxy needed. It bundles both the canonical model
/// registry (keyed by `<lab>/<model-id>`, e.g. `openai/gpt-5.5`) and the
/// per-provider serving entries (keyed by provider id). The canonical
/// registry is what lets us collapse the same model served under different
/// ids/names (`gpt-5.5`, `openai-gpt-5.5`, `gpt-5-5`, `GPT 5.5`…) into one
/// lab + display name. Because it's large and rarely changes, we keep an
/// in-memory [ModelsCatalog] for the session — fetch once, reuse until the
/// app restarts or [refresh] is called.
class ModelsDevService {
  ModelsDevService({Dio? dio}) : _dio = dio ?? Dio();

  static const String endpoint = 'https://models.dev/catalog.json';

  final Dio _dio;

  ModelsCatalog? _memory;

  /// Returns the catalog, using the in-memory copy if available and only
  /// going to the network on first call or [forceRefresh].
  ///
  /// Throws if there is no usable cache *and* the network request fails, so
  /// the UI can show an error + retry. If a stale cache exists but the
  /// refresh fails, the stale cache is returned (better than nothing / offline).
  Future<ModelsCatalog> load({bool forceRefresh = false}) async {
    final ModelsCatalog? cached = _memory;

    if (cached != null && !forceRefresh) {
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
    return catalog;
  }

  ModelsCatalog _parse(String raw, DateTime fetchedAt) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('models.dev: unexpected payload shape');
    }
    return ModelsCatalog.fromCatalogJson(decoded, fetchedAt: fetchedAt);
  }
}
