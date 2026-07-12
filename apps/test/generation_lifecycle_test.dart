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
import 'package:app/data/services/llm/adapter_registry.dart';
import 'package:app/data/services/llm/llm_adapter.dart';
import 'package:app/data/services/llm/llm_event.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/models/conversation.dart';
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
}
