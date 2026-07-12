import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/errors/provider_failure_mapper.dart';
import 'package:app/data/services/errors/retry_coordinator.dart';
import 'package:app/domain/errors/app_failure.dart';
import 'package:app/ui/core/notices/app_notice.dart';
import 'package:app/ui/core/notices/failure_presenter.dart';
import 'package:app/ui/core/notices/notice_center.dart';
import 'package:app/ui/core/notices/notice_host.dart';
import 'package:app/providers.dart';

void main() {
  const ProviderFailureMapper mapper = ProviderFailureMapper();
  const FailureSource source = FailureSource(
    subsystem: AppSubsystem.llm,
    operation: 'generate',
    providerId: 'OpenAI',
    accountId: 'account-1',
    modelId: 'gpt-test',
  );

  group('ProviderFailureMapper', () {
    test('distinguishes OpenAI exhausted quota from temporary 429', () {
      final AppFailure failure = mapper.fromPayload(
        <String, dynamic>{
          'error': <String, dynamic>{
            'type': 'insufficient_quota',
            'message': 'You exceeded your current quota.',
          },
        },
        source: source,
        flavor: ProviderErrorFlavor.openAi,
        status: 429,
      );

      expect(failure.kind, FailureKind.quotaExhausted);
      expect(failure.isRetryable, isFalse);
      expect(failure.providerCode, 'insufficient_quota');
    });

    test('keeps an ambiguous 429 as a temporary rate limit', () {
      final AppFailure failure = mapper.fromPayload(
        <String, dynamic>{'error': 'Too many requests'},
        source: source,
        status: 429,
        headers: Headers.fromMap(<String, List<String>>{
          'retry-after': <String>['30'],
          'x-request-id': <String>['req_test'],
        }),
      );

      expect(failure.kind, FailureKind.rateLimited);
      expect(failure.isRetryable, isTrue);
      expect(failure.retryAt, isNotNull);
      expect(failure.requestId, 'req_test');
    });

    test('parses an HTTP-date Retry-After header', () {
      final DateTime retryAt = DateTime.now().toUtc().add(
        const Duration(minutes: 2),
      );
      final AppFailure failure = mapper.fromPayload(
        null,
        source: source,
        status: 429,
        headers: Headers.fromMap(<String, List<String>>{
          'retry-after': <String>[
            '${_weekday(retryAt.weekday)}, '
                '${retryAt.day.toString().padLeft(2, '0')} '
                '${_month(retryAt.month)} ${retryAt.year} '
                '${retryAt.hour.toString().padLeft(2, '0')}:'
                '${retryAt.minute.toString().padLeft(2, '0')}:'
                '${retryAt.second.toString().padLeft(2, '0')} GMT',
          ],
        }),
      );

      expect(failure.retryAt, isNotNull);
      expect(failure.retryAt!.difference(retryAt).inSeconds.abs(), lessThan(2));
    });

    test('maps 403 to permission rather than authentication', () {
      final AppFailure failure = mapper.fromPayload(
        null,
        source: source,
        status: 403,
      );

      expect(failure.kind, FailureKind.permission);
    });

    test('maps Codex usage_limit_reached to quota exhaustion', () {
      final AppFailure failure = mapper.fromPayload(
        <String, dynamic>{
          'response': <String, dynamic>{
            'error': <String, dynamic>{
              'type': 'usage_limit_reached',
              'message': 'Usage limit reached.',
            },
          },
        },
        source: source,
        flavor: ProviderErrorFlavor.codex,
        status: 429,
      );

      expect(failure.kind, FailureKind.quotaExhausted);
      expect(failure.providerCode, 'usage_limit_reached');
    });

    test('redacts secrets from diagnostic details', () {
      final AppFailure failure = mapper.fromPayload(
        <String, dynamic>{
          'error': <String, dynamic>{
            'type': 'invalid_request_error',
            'message': 'Rejected Bearer abcdefghijklmnopqrstuvwxyz123456',
          },
        },
        source: source,
        status: 400,
      );

      expect(failure.safeDetail, contains('[REDACTED:bearer_token]'));
      expect(failure.safeDetail, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    });

    test('normalizes unexpected exceptions at service boundaries', () {
      final AppFailure failure = mapper.fromException(
        StateError('failed with sk-abcdefghijklmnopqrstuvwxyz123456'),
        source: source,
      );

      expect(failure.kind, FailureKind.unknown);
      expect(failure.safeDetail, contains('[REDACTED:openai_key]'));
    });
  });

  group('NoticeCenter', () {
    test('deduplicates notices with the same key', () {
      final NoticeCenter center = NoticeCenter();
      center.publish(
        const AppNotice(
          id: 'one',
          severity: NoticeSeverity.warning,
          title: 'First',
          message: 'First message',
          deduplicationKey: 'provider:rate-limit',
        ),
      );
      center.publish(
        const AppNotice(
          id: 'two',
          severity: NoticeSeverity.warning,
          title: 'Updated',
          message: 'Updated message',
          deduplicationKey: 'provider:rate-limit',
        ),
      );

      expect(center.notices, hasLength(1));
      expect(center.current?.id, 'two');
    });

    test('presents retry only for retryable failures', () {
      final AppNotice retryable = const FailurePresenter().present(
        const AppFailure(
          kind: FailureKind.network,
          source: source,
          message: 'Network failed.',
          isRetryable: true,
        ),
        onRetry: () async {},
      );
      final AppNotice terminal = const FailurePresenter().present(
        const AppFailure(
          kind: FailureKind.authentication,
          source: source,
          message: 'Sign in again.',
        ),
        onRetry: () async {},
      );

      expect(retryable.actions.single.kind, NoticeActionKind.retry);
      expect(terminal.actions, isEmpty);
    });

    test('presents storage failures as warnings', () {
      final AppNotice notice = const FailurePresenter().present(
        const AppFailure(
          kind: FailureKind.unknown,
          source: FailureSource(
            subsystem: AppSubsystem.storage,
            operation: 'save_conversation',
          ),
          message: 'This conversation could not be saved.',
        ),
      );

      expect(notice.severity, NoticeSeverity.warning);
      expect(notice.title, 'Storage unavailable');
    });

    test('offers settings when no provider is configured', () {
      final AppNotice notice = const FailurePresenter().present(
        const AppFailure(
          kind: FailureKind.unavailable,
          source: source,
          message: 'No provider is configured.',
        ),
        onOpenSettings: () async {},
      );

      expect(notice.actions.single.kind, NoticeActionKind.openSettings);
    });

    test('routes notices by placement', () {
      final NoticeCenter center = NoticeCenter();
      center.publish(
        const AppNotice(
          id: 'inline',
          severity: NoticeSeverity.warning,
          title: 'Search warning',
          message: 'One source failed.',
          placement: NoticePlacement.inline,
        ),
      );
      center.publish(
        const AppNotice(
          id: 'snackbar',
          severity: NoticeSeverity.info,
          title: 'Connected',
          message: 'Ready.',
        ),
      );

      expect(center.currentFor(NoticePlacement.inline)?.id, 'inline');
      expect(center.currentFor(NoticePlacement.snackbar)?.id, 'snackbar');
    });
  });

  group('RetryCoordinator', () {
    test('does not retry after streamed output', () {
      final RetryDecision decision = RetryCoordinator().decide(
        failure: const AppFailure(
          kind: FailureKind.network,
          source: source,
          message: 'Disconnected.',
          isRetryable: true,
        ),
        attempt: 0,
        receivedOutput: true,
        operationIsIdempotent: false,
      );

      expect(decision.shouldRetry, isFalse);
    });

    test('honors a provider retry time', () {
      final RetryDecision decision = RetryCoordinator().decide(
        failure: AppFailure(
          kind: FailureKind.rateLimited,
          source: source,
          message: 'Rate limited.',
          retryAt: DateTime.now().add(const Duration(seconds: 10)),
          isRetryable: true,
        ),
        attempt: 0,
        receivedOutput: false,
        operationIsIdempotent: true,
      );

      expect(decision.shouldRetry, isTrue);
      expect(decision.delay, isNotNull);
      expect(decision.delay!.inSeconds, inInclusiveRange(8, 10));
    });
  });

  testWidgets('NoticeHost renders a published snackbar notice', (
    WidgetTester tester,
  ) async {
    final NoticeCenter center = NoticeCenter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[noticeCenterProvider.overrideWith((_) => center)],
        child: const MaterialApp(
          home: NoticeHost(child: Scaffold(body: SizedBox())),
        ),
      ),
    );

    center.publish(
      const AppNotice(
        id: 'visible',
        severity: NoticeSeverity.error,
        title: 'Request failed',
        message: 'Try again later.',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Request failed'), findsOneWidget);
    expect(find.text('Try again later.'), findsOneWidget);
  });
}

String _weekday(int weekday) => const <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
][weekday - 1];

String _month(int month) => const <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];
