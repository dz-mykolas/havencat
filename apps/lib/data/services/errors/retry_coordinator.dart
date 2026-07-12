import 'dart:math';

import '../../../domain/errors/app_failure.dart';

class RetryDecision {
  const RetryDecision._({required this.shouldRetry, this.delay});

  const RetryDecision.no() : this._(shouldRetry: false);

  const RetryDecision.after(Duration delay)
    : this._(shouldRetry: true, delay: delay);

  final bool shouldRetry;
  final Duration? delay;
}

class RetryCoordinator {
  RetryCoordinator({Random? random}) : _random = random ?? Random();

  final Random _random;

  RetryDecision decide({
    required AppFailure failure,
    required int attempt,
    required bool receivedOutput,
    required bool operationIsIdempotent,
    int maxAttempts = 2,
  }) {
    if (!failure.isRetryable || receivedOutput || attempt >= maxAttempts) {
      return const RetryDecision.no();
    }
    if (!operationIsIdempotent && attempt > 0) {
      return const RetryDecision.no();
    }

    final DateTime? providerTime = failure.retryAt;
    if (providerTime != null) {
      final Duration delay = providerTime.difference(DateTime.now());
      return RetryDecision.after(delay.isNegative ? Duration.zero : delay);
    }

    final int capMilliseconds = min(30000, 1000 * (1 << attempt));
    return RetryDecision.after(
      Duration(milliseconds: _random.nextInt(capMilliseconds + 1)),
    );
  }
}
