import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';

import '../../../domain/errors/app_failure.dart';
import '../llm/secret_redaction.dart';

enum ProviderErrorFlavor { generic, openAi, codex, exa }

class ProviderFailureMapper {
  const ProviderFailureMapper();

  AppFailure fromException(
    Object exception, {
    required FailureSource source,
    ProviderErrorFlavor flavor = ProviderErrorFlavor.generic,
    String? fallbackMessage,
  }) {
    if (exception is AppFailure) return exception;
    if (exception is DioException) {
      return fromDio(exception, source: source, flavor: flavor);
    }
    return AppFailure(
      kind: FailureKind.unknown,
      source: source,
      message: fallbackMessage ?? 'The operation could not be completed.',
      safeDetail: _safeDetail(exception),
    );
  }

  AppFailure fromDio(
    DioException exception, {
    required FailureSource source,
    ProviderErrorFlavor flavor = ProviderErrorFlavor.generic,
  }) {
    if (CancelToken.isCancel(exception)) {
      return AppFailure(
        kind: FailureKind.cancelled,
        source: source,
        message: 'Request cancelled.',
      );
    }

    final int? status = exception.response?.statusCode;
    final Object? data = exception.response?.data;
    final Map<String, dynamic>? payload = _decodePayload(data);
    final Headers? headers = exception.response?.headers;

    if (status == null) {
      final FailureKind kind = switch (exception.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => FailureKind.timeout,
        DioExceptionType.connectionError => FailureKind.network,
        _ => FailureKind.unknown,
      };
      return AppFailure(
        kind: kind,
        source: source,
        message: kind == FailureKind.timeout
            ? 'The request timed out.'
            : kind == FailureKind.network
            ? 'Could not connect to the provider.'
            : 'The provider request failed.',
        isRetryable: kind == FailureKind.timeout || kind == FailureKind.network,
        safeDetail: _safeDetail(data ?? exception.message),
      );
    }

    return fromPayload(
      payload,
      source: source,
      flavor: flavor,
      status: status,
      headers: headers,
      fallbackDetail: data?.toString(),
    );
  }

  AppFailure fromPayload(
    Map<String, dynamic>? payload, {
    required FailureSource source,
    ProviderErrorFlavor flavor = ProviderErrorFlavor.generic,
    int? status,
    Headers? headers,
    String? fallbackDetail,
  }) {
    final String? providerCode = _providerCode(payload);
    final String normalizedCode = providerCode?.toLowerCase() ?? '';
    final String? providerMessage = _providerMessage(payload);
    final String? requestId =
        _header(headers, 'x-request-id') ??
        _header(headers, 'request-id') ??
        _stringAt(payload, const <String>['request_id']);
    final DateTime? retryAt = _retryAt(headers);
    final DateTime? resetAt = flavor == ProviderErrorFlavor.codex
        ? _codexResetAt(headers) ?? retryAt
        : retryAt;

    final bool explicitQuota = _containsAny(normalizedCode, const <String>[
      'insufficient_quota',
      'quota_exhausted',
      'usage_limit_reached',
      'no_more_credits',
      'budget_exceeded',
      'billing_hard_limit',
      'credit_balance',
    ]);
    final bool explicitRateLimit = _containsAny(normalizedCode, const <String>[
      'rate_limit',
      'too_many_requests',
      'resource_exhausted',
      'requests_per_minute',
      'tokens_per_minute',
    ]);
    final bool explicitPermission = _containsAny(normalizedCode, const <String>[
      'permission',
      'access_denied',
      'forbidden',
      'model_not_allowed',
    ]);
    final bool explicitAuth = _containsAny(normalizedCode, const <String>[
      'authentication',
      'invalid_api_key',
      'invalid_token',
      'unauthorized',
    ]);

    final FailureKind kind;
    if (explicitQuota) {
      kind = FailureKind.quotaExhausted;
    } else if (explicitAuth || status == 401) {
      kind = FailureKind.authentication;
    } else if (explicitPermission || status == 403) {
      kind = FailureKind.permission;
    } else if (explicitRateLimit || status == 429) {
      kind = FailureKind.rateLimited;
    } else {
      kind = switch (status) {
        402 => FailureKind.billingRequired,
        404 => FailureKind.notFound,
        408 => FailureKind.timeout,
        409 => FailureKind.conflict,
        413 => FailureKind.payloadTooLarge,
        400 || 405 || 406 || 415 || 422 => FailureKind.invalidRequest,
        503 || 529 => FailureKind.overloaded,
        final int value when value >= 500 => FailureKind.serverError,
        _ => FailureKind.unknown,
      };
    }

    return AppFailure(
      kind: kind,
      source: source,
      message: _messageFor(kind, source.providerId),
      providerCode: providerCode,
      httpStatus: status,
      requestId: requestId,
      retryAt: kind == FailureKind.rateLimited ? retryAt : null,
      resetAt: kind == FailureKind.quotaExhausted ? resetAt : null,
      isRetryable: _isRetryable(kind),
      safeDetail: _safeDetail(providerMessage ?? fallbackDetail),
    );
  }

  static bool _isRetryable(FailureKind kind) => switch (kind) {
    FailureKind.network ||
    FailureKind.timeout ||
    FailureKind.rateLimited ||
    FailureKind.overloaded ||
    FailureKind.serverError => true,
    _ => false,
  };

  static String _messageFor(FailureKind kind, String? provider) {
    final String name = provider?.trim().isNotEmpty == true
        ? provider!.trim()
        : 'provider';
    return switch (kind) {
      FailureKind.cancelled => 'Request cancelled.',
      FailureKind.offline => 'You appear to be offline.',
      FailureKind.network => 'Could not connect to $name.',
      FailureKind.timeout => '$name took too long to respond.',
      FailureKind.authentication =>
        'Authentication failed. Reconnect the $name account.',
      FailureKind.permission =>
        'This account does not have permission for that request.',
      FailureKind.regionRestricted =>
        'This service is not available in your region.',
      FailureKind.billingRequired =>
        'Billing must be configured for this $name account.',
      FailureKind.quotaExhausted => '$name usage quota is exhausted.',
      FailureKind.rateLimited => '$name is temporarily rate limited.',
      FailureKind.overloaded => '$name is temporarily overloaded.',
      FailureKind.invalidRequest => '$name rejected the request.',
      FailureKind.unsupported => 'This operation is not supported by $name.',
      FailureKind.unavailable => '$name is currently unavailable.',
      FailureKind.notFound => 'The requested model or resource was not found.',
      FailureKind.conflict => 'The request conflicts with the current state.',
      FailureKind.payloadTooLarge => 'The request is too large for $name.',
      FailureKind.contentBlocked => 'The provider blocked this content.',
      FailureKind.safetyBlocked =>
        'The request was blocked by the provider’s safety system.',
      FailureKind.serverError => '$name encountered a server error.',
      FailureKind.dataCorrupted => 'Stored application data is damaged.',
      FailureKind.unknown => '$name could not complete the request.',
    };
  }

  static Map<String, dynamic>? _decodePayload(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is! String || data.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(data);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  static String? _providerCode(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final Object? error = payload['error'];
    if (error is Map) {
      final Object? code = error['code'] ?? error['type'] ?? error['tag'];
      if (code != null) return code.toString();
    }
    final Object? response = payload['response'];
    if (response is Map && response['error'] is Map) {
      final Map<dynamic, dynamic> nested = response['error'] as Map;
      final Object? code = nested['code'] ?? nested['type'] ?? nested['tag'];
      if (code != null) return code.toString();
    }
    final Object? code = payload['code'] ?? payload['type'] ?? payload['tag'];
    return code?.toString();
  }

  static String? _providerMessage(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final Object? error = payload['error'];
    if (error is Map && error['message'] != null) {
      return error['message'].toString();
    }
    if (error is String) return error;
    final Object? response = payload['response'];
    if (response is Map && response['error'] is Map) {
      final Object? message = (response['error'] as Map)['message'];
      if (message != null) return message.toString();
    }
    return payload['message']?.toString();
  }

  static String? _stringAt(Map<String, dynamic>? payload, List<String> path) {
    Object? value = payload;
    for (final String part in path) {
      if (value is! Map) return null;
      value = value[part];
    }
    return value?.toString();
  }

  static String? _header(Headers? headers, String name) => headers?.value(name);

  static DateTime? _retryAt(Headers? headers) {
    final String? retryAfter = _header(headers, 'retry-after');
    if (retryAfter != null) {
      final int? seconds = int.tryParse(retryAfter.trim());
      if (seconds != null) {
        return DateTime.now().add(Duration(seconds: math.max(0, seconds)));
      }
      final DateTime? date = DateTime.tryParse(retryAfter);
      if (date != null) return date;
      final DateTime? httpDate = _parseHttpDate(retryAfter);
      if (httpDate != null) return httpDate;
    }
    final String? reset =
        _header(headers, 'x-ratelimit-reset-requests') ??
        _header(headers, 'x-ratelimit-reset-tokens');
    final Duration? duration = _parseDuration(reset);
    if (duration != null) return DateTime.now().add(duration);

    final String? resetAt =
        _header(headers, 'anthropic-ratelimit-requests-reset') ??
        _header(headers, 'anthropic-ratelimit-tokens-reset');
    final DateTime? parsedResetAt = DateTime.tryParse(resetAt ?? '');
    if (parsedResetAt != null) return parsedResetAt;

    final int? resetAfterSeconds = int.tryParse(
      _header(headers, 'ratelimit-reset') ?? '',
    );
    if (resetAfterSeconds != null) {
      return DateTime.now().add(Duration(seconds: resetAfterSeconds));
    }

    final int? resetEpoch = int.tryParse(
      _header(headers, 'x-ratelimit-reset') ?? '',
    );
    return resetEpoch == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(resetEpoch * 1000, isUtc: true);
  }

  static DateTime? _codexResetAt(Headers? headers) {
    final String active =
        _header(headers, 'x-codex-active-limit')?.toLowerCase() ?? 'primary';
    final String prefix = active.contains('secondary')
        ? 'x-codex-secondary'
        : 'x-codex-primary';
    final String? epoch =
        _header(headers, '$prefix-reset-at') ??
        _header(headers, '$prefix-resets-at');
    final int? seconds = int.tryParse(epoch ?? '');
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
    final String? after = _header(headers, '$prefix-reset-after-seconds');
    final int? afterSeconds = int.tryParse(after ?? '');
    return afterSeconds == null
        ? null
        : DateTime.now().add(Duration(seconds: afterSeconds));
  }

  static Duration? _parseDuration(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final String input = value.trim().toLowerCase();
    final RegExp pattern = RegExp(r'(\d+(?:\.\d+)?)(ms|s|m|h)');
    double milliseconds = 0;
    for (final RegExpMatch match in pattern.allMatches(input)) {
      final double amount = double.parse(match.group(1)!);
      milliseconds += switch (match.group(2)) {
        'ms' => amount,
        's' => amount * 1000,
        'm' => amount * 60000,
        'h' => amount * 3600000,
        _ => 0,
      };
    }
    return milliseconds == 0
        ? null
        : Duration(milliseconds: milliseconds.round());
  }

  static DateTime? _parseHttpDate(String value) {
    try {
      return DateFormat(
        'EEE, dd MMM yyyy HH:mm:ss \'GMT\'',
        'en_US',
      ).parseUtc(value);
    } on FormatException {
      return null;
    }
  }

  static bool _containsAny(String value, List<String> needles) =>
      needles.any(value.contains);

  static String? _safeDetail(Object? value) {
    if (value == null) return null;
    final String redacted = redactSecrets(value.toString()).trim();
    if (redacted.isEmpty) return null;
    const int maxLength = 600;
    return redacted.length <= maxLength
        ? redacted
        : '${redacted.substring(0, maxLength)}…';
  }
}
