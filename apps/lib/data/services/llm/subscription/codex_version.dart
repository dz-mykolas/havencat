import 'package:dio/dio.dart';

import '../llm_endpoint.dart';
import 'codex_protocol.dart';

/// Resolves a current `@openai/codex` release to advertise as `client_version`
/// to the version-gated Codex models endpoint.
///
/// Reporting a stale version makes `/codex/models` return an old, smaller model
/// set (missing e.g. `gpt-5.5`), so we look up the latest published version from
/// the npm registry once per session and cache it. Any failure (offline,
/// registry hiccup) falls back to [CodexProtocol.defaultClientVersion] without
/// caching, so a later call can try again.
class CodexVersionResolver {
  CodexVersionResolver({required this._dio, required this._endpoint});

  final Dio _dio;
  final LlmEndpoint _endpoint;

  static const String _registryUrl =
      'https://registry.npmjs.org/@openai/codex/latest';
  static final RegExp _semver = RegExp(r'\d+\.\d+\.\d+');

  String? _cached;
  Future<String>? _inflight;

  /// The version to use, resolving (and caching) the live one on first call.
  Future<String> resolve() {
    final String? cached = _cached;
    if (cached != null) return Future<String>.value(cached);

    return _inflight ??= _fetch()
        .then((String version) {
          _cached = version;
          _inflight = null;
          return version;
        })
        .catchError((Object _) {
          _inflight = null;
          return CodexProtocol.defaultClientVersion;
        });
  }

  Future<String> _fetch() async {
    final ResolvedRequest resolved = _endpoint.resolve(
      _registryUrl,
      const <String, String>{'Accept': 'application/json'},
    );
    final Response<dynamic> response = await _dio.get<dynamic>(
      resolved.url,
      options: Options(headers: resolved.headers),
    );
    final Object? data = response.data;
    final Object? version = data is Map<String, dynamic>
        ? data['version']
        : null;
    final Match? match = version is String ? _semver.firstMatch(version) : null;
    if (match != null) return match.group(0)!;
    throw StateError('No usable version in registry response.');
  }
}
