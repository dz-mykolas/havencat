import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/repositories/conversation_repository.dart';
import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/credential_resolver.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/background/generation_background_service.dart';
import 'package:app/data/services/generation/generation_host.dart';
import 'package:app/data/services/generation/in_memory_generation_task_store.dart';
import 'package:app/data/services/llm/adapter_registry.dart';
import 'package:app/data/services/llm/llm_adapter.dart';
import 'package:app/data/services/llm/llm_event.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/conversation.dart';
import 'package:app/domain/models/generation_task.dart';
import 'package:app/domain/models/llm_model.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/domain/models/provider_account.dart';

class _ControlledAdapter implements LlmAdapter {
  final StreamController<LlmEvent> events = StreamController<LlmEvent>();
  final Completer<void> started = Completer<void>();

  @override
  AdapterKind get kind => AdapterKind.mock;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) {
    started.complete();
    return events.stream;
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) async => const <LlmModel>[];
}

class _QueuedAdapter implements LlmAdapter {
  final List<StreamController<LlmEvent>> runs = <StreamController<LlmEvent>>[];
  final StreamController<int> started = StreamController<int>.broadcast();

  @override
  AdapterKind get kind => AdapterKind.mock;

  @override
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  }) {
    final StreamController<LlmEvent> run = StreamController<LlmEvent>();
    runs.add(run);
    started.add(runs.length);
    return run.stream;
  }

  @override
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  }) async => const <LlmModel>[];
}

class _BackgroundController implements GenerationBackgroundController {
  int begins = 0;
  int completes = 0;
  int interrupts = 0;
  int cancels = 0;

  @override
  Future<void> Function()? onBackgroundTimeExpired;
  @override
  void Function(String conversationId)? onConversationSelected;

  @override
  Future<void> begin({
    required String conversationId,
    required String conversationTitle,
  }) async {
    begins++;
  }

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> complete() async => completes++;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> interrupt() async => interrupts++;

  @override
  void setAppVisible(bool visible) {}

  @override
  String? takeSelectedConversation() => null;
}

class _SeededStore implements ConversationStore {
  _SeededStore(this.conversations);

  final List<Conversation> conversations;
  Conversation? saved;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<Conversation>> load() async => conversations;

  @override
  Future<void> upsert(Conversation conversation) async {
    saved = Conversation.fromJson(conversation.toJson());
  }
}

void main() {
  late ProviderAccountRepository providers;
  late CredentialResolver credentials;

  setUp(() async {
    final SecretStore secrets = SecretStore();
    providers = ProviderAccountRepository(
      accountStore: AccountStore(),
      secretStore: secrets,
    );
    await providers.setModel(providers.accounts.first.id, 'mock-model');
    credentials = CredentialResolver(
      secretStore: secrets,
      chatGptTokens: ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: ChatGptOAuthFlow(dio: Dio()),
      ),
    );
  });

  test(
    'cancellation keeps partial output and closes background work',
    () async {
      final _ControlledAdapter adapter = _ControlledAdapter();
      final _BackgroundController background = _BackgroundController();
      final ConversationRepository repository = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
        credentialResolver: credentials,
        backgroundController: background,
      );

      final Future<void> sending = repository.sendMessage('hello');
      await adapter.started.future;
      adapter.events.add(const TokenEvent('A useful partial answer'));
      await Future<void>.delayed(Duration.zero);
      await repository.cancelGeneration();
      await sending;

      final ChatMessage reply = repository.active.messages.last;
      expect(reply.text, 'A useful partial answer');
      expect(reply.generationStatus, MessageGenerationStatus.cancelled);
      expect(background.begins, 1);
      expect(background.cancels, 1);
      repository.dispose();
      await adapter.events.close();
    },
  );

  test('background expiration marks a partial response interrupted', () async {
    final _ControlledAdapter adapter = _ControlledAdapter();
    final _BackgroundController background = _BackgroundController();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
      backgroundController: background,
    );

    final Future<void> sending = repository.sendMessage('hello');
    await adapter.started.future;
    adapter.events.add(const TokenEvent('Saved before suspension'));
    await Future<void>.delayed(Duration.zero);
    await background.onBackgroundTimeExpired?.call();
    await sending;

    final ChatMessage reply = repository.active.messages.last;
    expect(reply.text, 'Saved before suspension');
    expect(reply.generationStatus, MessageGenerationStatus.interrupted);
    expect(background.interrupts, 1);
    repository.dispose();
    await adapter.events.close();
  });

  test('stream failure preserves partial output', () async {
    final _ControlledAdapter adapter = _ControlledAdapter();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
    );

    final Future<void> sending = repository.sendMessage('hello');
    await adapter.started.future;
    adapter.events.add(const TokenEvent('discarded partial'));
    adapter.events.add(
      const ErrorEvent(
        AppFailure(
          kind: FailureKind.network,
          source: FailureSource(
            subsystem: AppSubsystem.llm,
            operation: 'generate',
          ),
          message: 'The response stream disconnected.',
        ),
      ),
    );
    await sending;

    final ChatMessage reply = repository.active.messages.last;
    expect(reply.text, 'discarded partial');
    expect(reply.generationStatus, MessageGenerationStatus.interrupted);
    repository.dispose();
    await adapter.events.close();
  });

  test('startup recovers an unfinished message as interrupted', () async {
    final Conversation conversation = Conversation(
      id: 'conversation',
      messages: <ChatMessage>[
        ChatMessage(id: 'user', role: MessageRole.user, text: 'hello'),
        ChatMessage(
          id: 'assistant',
          role: MessageRole.assistant,
          text: 'partial',
          generationStatus: MessageGenerationStatus.streaming,
        ),
      ],
    )..currentLeafId = 'assistant';
    final _SeededStore store = _SeededStore(<Conversation>[conversation]);
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry(),
      credentialResolver: credentials,
      conversationStore: store,
    );

    await repository.ready;

    expect(
      repository.conversations.single.messages.last.generationStatus,
      MessageGenerationStatus.interrupted,
    );
    expect(
      store.saved?.messages.last.generationStatus,
      MessageGenerationStatus.interrupted,
    );
    repository.dispose();
  });

  test('messages sent during generation run in FIFO order', () async {
    final _QueuedAdapter adapter = _QueuedAdapter();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
    );

    final Future<void> first = repository.sendMessage('first');
    await adapter.started.stream.firstWhere((int run) => run == 1);
    await repository.sendMessage('second');
    expect(repository.generationTasks.last.state, GenerationTaskState.queued);

    adapter.runs.first
      ..add(const TokenEvent('one'))
      ..add(const DoneEvent());
    await adapter.started.stream.firstWhere((int run) => run == 2);
    adapter.runs.last
      ..add(const TokenEvent('two'))
      ..add(const DoneEvent());
    await first;

    expect(
      repository.active.messages
          .where((ChatMessage message) => message.isAssistant)
          .map((ChatMessage message) => message.text),
      <String>['one', 'two'],
    );
    repository.dispose();
    for (final StreamController<LlmEvent> run in adapter.runs) {
      await run.close();
    }
    await adapter.started.close();
  });

  test('steering freezes partial output and starts a successor task', () async {
    final _QueuedAdapter adapter = _QueuedAdapter();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
    );

    final Future<void> sending = repository.sendMessage('first');
    await adapter.started.stream.firstWhere((int run) => run == 1);
    adapter.runs.first.add(const TokenEvent('partial'));
    await Future<void>.delayed(Duration.zero);
    await repository.steerGeneration('change direction');
    await adapter.started.stream.firstWhere((int run) => run == 2);
    adapter.runs.last
      ..add(const TokenEvent('redirected'))
      ..add(const DoneEvent());
    await sending;

    expect(
      repository.active.messages
          .where((ChatMessage message) => message.isUser)
          .map((ChatMessage message) => message.text),
      contains('change direction'),
    );
    expect(
      repository.active.messages
          .where((ChatMessage message) => message.isAssistant)
          .map((ChatMessage message) => message.text),
      <String>['partial', 'redirected'],
    );
    repository.dispose();
    for (final StreamController<LlmEvent> run in adapter.runs) {
      await run.close();
    }
    await adapter.started.close();
  });

  test('provider calls move prepared → sending → acknowledged', () async {
    final _ControlledAdapter adapter = _ControlledAdapter();
    final InMemoryGenerationTaskStore taskStore = InMemoryGenerationTaskStore();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
      generationTaskStore: taskStore,
    );

    final Future<void> sending = repository.sendMessage('hello');
    await adapter.started.future;
    adapter.events
      ..add(const TokenEvent('hi'))
      ..add(const DoneEvent());
    await sending;

    expect(taskStore.providerCallStatuses.values, contains('acknowledged'));
    repository.dispose();
    await adapter.events.close();
  });

  test('platform host wraps inline queue execution', () async {
    final _ControlledAdapter adapter = _ControlledAdapter();
    final InMemoryGenerationTaskStore taskStore = InMemoryGenerationTaskStore();
    final _TrackingHost host = _TrackingHost();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
      generationTaskStore: taskStore,
      generationHost: host,
    );

    final Future<void> sending = repository.sendMessage('hello');
    await adapter.started.future;
    expect(host.ensureCalls, 1);
    expect(host.stopCalls, 0);
    adapter.events
      ..add(const TokenEvent('done'))
      ..add(const DoneEvent());
    await sending;

    expect(host.stopCalls, 1);
    expect(
      repository.generationTasks.single.state,
      GenerationTaskState.completed,
    );
    repository.dispose();
    await adapter.events.close();
  });

  test('cancel applies while the platform host is starting', () async {
    final _ControlledAdapter adapter = _ControlledAdapter();
    final _BlockingHost host = _BlockingHost();
    final ConversationRepository repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
      credentialResolver: credentials,
      generationHost: host,
    );

    final Future<void> sending = repository.sendMessage('hello');
    await host.started.future;
    final Future<void> cancelling = repository.cancelGeneration();
    host.release.complete();
    await Future.wait(<Future<void>>[sending, cancelling]);

    expect(
      repository.generationTasks.single.state,
      GenerationTaskState.cancelled,
    );
    expect(host.stopCalls, 1);
    expect(adapter.started.isCompleted, isFalse);
    repository.dispose();
    unawaited(adapter.events.close());
  });

  test(
    'platform host startup failure fails the task before dispatch',
    () async {
      final _ControlledAdapter adapter = _ControlledAdapter();
      final ConversationRepository repository = ConversationRepository(
        providerRepository: providers,
        adapterRegistry: AdapterRegistry()..register(AdapterKind.mock, adapter),
        credentialResolver: credentials,
        generationHost: _FailingHost(),
      );

      await repository.sendMessage('hello');

      expect(
        repository.generationTasks.single.state,
        GenerationTaskState.failed,
      );
      expect(
        repository.active.messages.last.generationStatus,
        MessageGenerationStatus.failed,
      );
      expect(adapter.started.isCompleted, isFalse);
      repository.dispose();
      unawaited(adapter.events.close());
    },
  );
}

class _TrackingHost implements GenerationHost {
  int ensureCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> ensureRunning() async {
    ensureCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _BlockingHost extends _TrackingHost {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> ensureRunning() async {
    await super.ensureRunning();
    started.complete();
    await release.future;
  }
}

class _FailingHost implements GenerationHost {
  @override
  Future<void> ensureRunning() => throw StateError('host unavailable');

  @override
  Future<void> stop() async {}
}
