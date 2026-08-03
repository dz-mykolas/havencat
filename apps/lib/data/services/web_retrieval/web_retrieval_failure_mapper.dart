import 'dart:convert';

import '../../../domain/errors/app_failure.dart';
import '../llm/secret_redaction.dart';
import 'web_retrieval.dart';

class WebRetrievalFailureMapper {
  const WebRetrievalFailureMapper();

  AppFailure fromIssue(
    WebProviderIssue issue, {
    required String operation,
    bool degraded = false,
  }) {
    final FailureKind kind = _kindFromCode(issue.kind);
    final String detail = _safeDetail(issue.detail);
    final String summary = _message(kind, issue.provider, operation);
    return AppFailure(
      kind: kind,
      source: FailureSource(
        subsystem: operation == 'fetch'
            ? AppSubsystem.webFetch
            : AppSubsystem.webSearch,
        operation: operation,
        providerId: issue.provider,
      ),
      message: degraded
          ? '${_displayName(issue.provider)} was unavailable, but other search providers returned results.'
          : _withDetail(summary, detail),
      retryAt: issue.retryAfter == null
          ? null
          : DateTime.now().add(issue.retryAfter!),
      isRetryable: _isRetryable(kind),
      impact: degraded ? FailureImpact.degraded : FailureImpact.operationFailed,
      safeDetail: detail,
    );
  }

  AppFailure fromException(
    Object error, {
    required AppSubsystem subsystem,
    required String operation,
    String? provider,
  }) {
    if (error is AppFailure) return error;
    final String detail = _safeDetail(error.toString());
    final String normalized = detail.toLowerCase();
    final FailureKind kind = normalized.contains('rate limit')
        ? FailureKind.rateLimited
        : normalized.contains('quota') || normalized.contains('credit')
        ? FailureKind.quotaExhausted
        : normalized.contains('auth') || normalized.contains('unauthorized')
        ? FailureKind.authentication
        : normalized.contains('invalid request')
        ? FailureKind.invalidRequest
        : normalized.contains('not configured') ||
              normalized.contains('provider not found')
        ? FailureKind.unavailable
        : normalized.contains('timeout') || normalized.contains('timed out')
        ? FailureKind.timeout
        : FailureKind.network;
    return AppFailure(
      kind: kind,
      source: FailureSource(
        subsystem: subsystem,
        operation: operation,
        providerId: provider,
      ),
      message: _withDetail(_message(kind, provider, operation), detail),
      isRetryable: _isRetryable(kind),
      safeDetail: detail,
    );
  }

  AppFailure fromHttp({
    required int status,
    required String body,
    required AppSubsystem subsystem,
    required String operation,
  }) {
    String? code;
    String? provider;
    String? message;
    String? detail;
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        final Object? error = decoded['error'];
        if (error is Map) {
          code = error['code']?.toString();
          provider = error['provider']?.toString();
          message = error['message']?.toString();
          detail = error['detail']?.toString();
        }
      }
    } on FormatException {
      code = null;
    }
    final FailureKind kind = code == null
        ? _kindFromStatus(status)
        : _kindFromCode(code);
    final String safeDetail = detail == null ? '' : _safeDetail(detail);
    final String safeMessage = message == null ? '' : _safeDetail(message);
    return AppFailure(
      kind: kind,
      source: FailureSource(
        subsystem: subsystem,
        operation: operation,
        providerId: provider,
      ),
      message: safeMessage.isEmpty
          ? _withDetail(_message(kind, provider, operation), safeDetail)
          : safeMessage,
      httpStatus: status,
      providerCode: code,
      isRetryable: _isRetryable(kind),
      safeDetail: safeDetail.isEmpty ? null : safeDetail,
    );
  }

  static FailureKind _kindFromCode(String code) => switch (code) {
    'authentication' => FailureKind.authentication,
    'rate_limited' || 'rateLimited' => FailureKind.rateLimited,
    'quota_exhausted' || 'quotaExhausted' => FailureKind.quotaExhausted,
    'invalid_request' || 'invalidRequest' => FailureKind.invalidRequest,
    'unavailable' => FailureKind.unavailable,
    'storage' => FailureKind.serverError,
    'network' => FailureKind.network,
    _ => FailureKind.unknown,
  };

  static FailureKind _kindFromStatus(int status) => switch (status) {
    400 => FailureKind.invalidRequest,
    401 => FailureKind.authentication,
    402 => FailureKind.quotaExhausted,
    403 => FailureKind.permission,
    408 => FailureKind.timeout,
    429 => FailureKind.rateLimited,
    final int value when value >= 500 => FailureKind.serverError,
    _ => FailureKind.unknown,
  };

  static bool _isRetryable(FailureKind kind) => switch (kind) {
    FailureKind.network ||
    FailureKind.timeout ||
    FailureKind.rateLimited ||
    FailureKind.overloaded ||
    FailureKind.serverError => true,
    _ => false,
  };

  static String _message(FailureKind kind, String? provider, String operation) {
    final String name = _displayName(provider);
    final String action = operation == 'fetch'
        ? 'fetch the page'
        : 'search the web';
    return switch (kind) {
      FailureKind.authentication => '$name credentials were rejected.',
      FailureKind.quotaExhausted => '$name search quota is exhausted.',
      FailureKind.rateLimited => '$name is temporarily rate limited.',
      FailureKind.invalidRequest => '$name rejected the search request.',
      FailureKind.timeout => '$name took too long to respond.',
      FailureKind.unavailable => 'No usable web provider is configured.',
      _ => '$name could not $action.',
    };
  }

  static String _displayName(String? provider) {
    if (provider == null || provider.isEmpty) return 'Web search';
    return switch (provider.toLowerCase()) {
      'exa' => 'Exa',
      'brave' => 'Brave Search',
      'searxng' => 'SearXNG',
      _ => provider,
    };
  }

  static String _safeDetail(String value) {
    final String detail = redactSecrets(value).trim();
    return detail.length <= 600 ? detail : '${detail.substring(0, 600)}…';
  }

  static String _withDetail(String summary, String detail) {
    if (detail.isEmpty) return summary;
    return '$summary\n$detail';
  }
}
