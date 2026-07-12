import '../../../domain/errors/app_failure.dart';
import 'app_notice.dart';

class FailurePresenter {
  const FailurePresenter();

  AppNotice present(
    AppFailure failure, {
    Future<void> Function()? onRetry,
    Future<void> Function()? onOpenSettings,
  }) {
    final String provider = failure.source.providerId ?? 'Provider';
    final String title = failure.source.subsystem == AppSubsystem.storage
        ? 'Storage unavailable'
        : switch (failure.kind) {
            FailureKind.authentication => 'Reconnect $provider',
            FailureKind.permission => 'Access denied',
            FailureKind.billingRequired => 'Billing required',
            FailureKind.quotaExhausted => 'Usage limit reached',
            FailureKind.rateLimited => 'Temporarily rate limited',
            FailureKind.overloaded => 'Provider busy',
            FailureKind.offline => 'You’re offline',
            FailureKind.network => 'Connection failed',
            FailureKind.timeout => 'Request timed out',
            FailureKind.payloadTooLarge => 'Request too large',
            FailureKind.invalidRequest => 'Request rejected',
            FailureKind.cancelled => 'Request cancelled',
            _ => 'Couldn’t complete the request',
          };
    final String timing = _timingMessage(failure);
    final String message = timing.isEmpty
        ? failure.message
        : '${failure.message} $timing';
    final List<NoticeAction> actions = <NoticeAction>[
      if (onRetry != null && failure.isRetryable)
        NoticeAction(
          kind: NoticeActionKind.retry,
          label: 'Retry',
          onPressed: onRetry,
        ),
      if (onOpenSettings != null &&
          (failure.kind == FailureKind.authentication ||
              failure.kind == FailureKind.billingRequired ||
              failure.kind == FailureKind.unavailable))
        NoticeAction(
          kind: failure.kind == FailureKind.authentication
              ? NoticeActionKind.reconnect
              : NoticeActionKind.openSettings,
          label: failure.kind == FailureKind.authentication
              ? 'Reconnect'
              : 'Open settings',
          onPressed: onOpenSettings,
        ),
    ];
    return AppNotice(
      id: 'failure-${DateTime.now().microsecondsSinceEpoch}',
      severity: failure.isCancellation
          ? NoticeSeverity.info
          : failure.impact == FailureImpact.degraded ||
                failure.source.subsystem == AppSubsystem.storage ||
                failure.source.subsystem == AppSubsystem.modelCatalog
          ? NoticeSeverity.warning
          : NoticeSeverity.error,
      title: title,
      message: message,
      deduplicationKey:
          'failure:${failure.source.providerId}:${failure.kind.name}',
      actions: actions,
    );
  }

  static String _timingMessage(AppFailure failure) {
    final DateTime? target = failure.resetAt ?? failure.retryAt;
    if (target == null) return '';
    final Duration remaining = target.difference(DateTime.now());
    if (remaining <= Duration.zero) return 'You can retry now.';
    if (remaining.inHours >= 1) {
      final int minutes = remaining.inMinutes.remainder(60);
      return 'Available again in ${remaining.inHours}h ${minutes}m.';
    }
    if (remaining.inMinutes >= 1) {
      return 'Try again in ${remaining.inMinutes + 1} minutes.';
    }
    return 'Try again in ${remaining.inSeconds + 1} seconds.';
  }
}
