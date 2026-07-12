enum FailureKind {
  cancelled,
  offline,
  network,
  timeout,
  authentication,
  permission,
  regionRestricted,
  billingRequired,
  quotaExhausted,
  rateLimited,
  overloaded,
  invalidRequest,
  unsupported,
  unavailable,
  notFound,
  conflict,
  payloadTooLarge,
  contentBlocked,
  safetyBlocked,
  serverError,
  dataCorrupted,
  unknown,
}

enum AppSubsystem {
  llm,
  webSearch,
  webFetch,
  voiceInput,
  voiceOutput,
  authentication,
  storage,
  modelCatalog,
  networking,
  application,
}

enum FailureImpact { operationFailed, degraded }

class FailureSource {
  const FailureSource({
    required this.subsystem,
    required this.operation,
    this.providerId,
    this.accountId,
    this.modelId,
    this.resource,
  });

  static const FailureSource llm = FailureSource(
    subsystem: AppSubsystem.llm,
    operation: 'generate',
  );

  final AppSubsystem subsystem;
  final String operation;
  final String? providerId;
  final String? accountId;
  final String? modelId;
  final String? resource;
}

class AppFailure implements Exception {
  const AppFailure({
    required this.kind,
    required this.source,
    required this.message,
    this.providerCode,
    this.httpStatus,
    this.requestId,
    this.retryAt,
    this.resetAt,
    this.isRetryable = false,
    this.safeDetail,
    this.impact = FailureImpact.operationFailed,
  });

  final FailureKind kind;
  final FailureSource source;
  final String message;
  final String? providerCode;
  final int? httpStatus;
  final String? requestId;
  final DateTime? retryAt;
  final DateTime? resetAt;
  final bool isRetryable;
  final String? safeDetail;
  final FailureImpact impact;

  bool get isCancellation => kind == FailureKind.cancelled;

  @override
  String toString() => message;
}

class NetworkError extends AppFailure {
  const NetworkError(String message, {super.source = FailureSource.llm})
    : super(kind: FailureKind.network, message: message, isRetryable: true);
}

class AuthError extends AppFailure {
  const AuthError(String message, {super.source = FailureSource.llm})
    : super(kind: FailureKind.authentication, message: message);
}

class RateLimitError extends AppFailure {
  const RateLimitError(
    String message, {
    super.source = FailureSource.llm,
    super.retryAt,
  }) : super(
         kind: FailureKind.rateLimited,
         message: message,
         isRetryable: true,
       );
}

class QuotaError extends AppFailure {
  const QuotaError(
    String message, {
    super.source = FailureSource.llm,
    super.resetAt,
  }) : super(kind: FailureKind.quotaExhausted, message: message);
}

class InvalidRequestError extends AppFailure {
  const InvalidRequestError(String message, {super.source = FailureSource.llm})
    : super(kind: FailureKind.invalidRequest, message: message);
}

class UnknownError extends AppFailure {
  const UnknownError(String message, {super.source = FailureSource.llm})
    : super(kind: FailureKind.unknown, message: message);
}
