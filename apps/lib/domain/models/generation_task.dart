import 'dart:convert';

import 'message.dart';
import 'llm_model.dart';
import 'provider_account.dart';

enum GenerationTaskState {
  queued,
  claimed,
  dispatching,
  streaming,
  cancelRequested,
  completed,
  cancelled,
  failed,
  interruptedPartial,
  outcomeUnknown,
}

enum GenerationTaskPhase {
  waiting,
  preparing,
  connecting,
  streaming,
  executingTool,
  finalizing,
}

enum GenerationCommandKind { cancel, steer }

enum GenerationCommandState { pending, applied, rejected }

class GenerationRequestSnapshot {
  const GenerationRequestSnapshot({
    required this.account,
    required this.model,
    required this.messages,
    required this.toolsEnabled,
    required this.contextWindow,
    required this.modelCapabilities,
    this.extraPrompt,
  });

  final ProviderAccount account;
  final String model;
  final List<ChatMessage> messages;
  final bool toolsEnabled;
  final int contextWindow;
  final ModelCapabilities? modelCapabilities;
  final String? extraPrompt;

  Map<String, Object?> toJson() => <String, Object?>{
    'account': account.toJson(),
    'model': model,
    'messages': messages
        .map((ChatMessage message) => message.toJson())
        .toList(growable: false),
    'toolsEnabled': toolsEnabled,
    'contextWindow': contextWindow,
    if (modelCapabilities != null)
      'modelCapabilities': modelCapabilities!.toJson(),
    if (extraPrompt != null) 'extraPrompt': extraPrompt,
  };

  String encode() => jsonEncode(toJson());

  factory GenerationRequestSnapshot.fromJson(Map<String, Object?> json) {
    return GenerationRequestSnapshot(
      account: ProviderAccount.fromJson(
        Map<String, Object?>.from(json['account']! as Map),
      ),
      model: json['model']! as String,
      messages: (json['messages']! as List)
          .map(
            (Object? value) =>
                ChatMessage.fromJson(Map<String, dynamic>.from(value! as Map)),
          )
          .toList(growable: false),
      toolsEnabled: json['toolsEnabled'] as bool? ?? false,
      contextWindow: json['contextWindow']! as int,
      modelCapabilities: json['modelCapabilities'] is Map
          ? ModelCapabilities.fromJson(
              Map<String, Object?>.from(json['modelCapabilities']! as Map),
            )
          : null,
      extraPrompt: json['extraPrompt'] as String?,
    );
  }

  factory GenerationRequestSnapshot.decode(String value) {
    return GenerationRequestSnapshot.fromJson(
      Map<String, Object?>.from(jsonDecode(value) as Map),
    );
  }
}

class GenerationTask {
  const GenerationTask({
    required this.id,
    required this.conversationId,
    required this.inputMessageId,
    required this.outputMessageId,
    required this.enqueueSequence,
    required this.snapshot,
    required this.state,
    required this.phase,
    required this.createdAt,
    required this.updatedAt,
    this.runId,
    this.error,
  });

  final String id;
  final String conversationId;
  final String inputMessageId;
  final String outputMessageId;
  final int enqueueSequence;
  final GenerationRequestSnapshot snapshot;
  final GenerationTaskState state;
  final GenerationTaskPhase phase;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? runId;
  final String? error;

  bool get isTerminal => switch (state) {
    GenerationTaskState.completed ||
    GenerationTaskState.cancelled ||
    GenerationTaskState.failed ||
    GenerationTaskState.interruptedPartial ||
    GenerationTaskState.outcomeUnknown => true,
    _ => false,
  };

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'inputMessageId': inputMessageId,
    'outputMessageId': outputMessageId,
    'enqueueSequence': enqueueSequence,
    'snapshot': snapshot.toJson(),
    'phase': phase.name,
  };

  static GenerationTask fromPersistenceJson({
    required String id,
    required String conversationId,
    required String state,
    required String requestJson,
    required DateTime createdAt,
    required DateTime updatedAt,
    String? runId,
    String? error,
  }) {
    final Map<String, Object?> json = Map<String, Object?>.from(
      jsonDecode(requestJson) as Map,
    );
    return GenerationTask(
      id: id,
      conversationId: conversationId,
      inputMessageId: json['inputMessageId']! as String,
      outputMessageId: json['outputMessageId']! as String,
      enqueueSequence: json['enqueueSequence']! as int,
      snapshot: GenerationRequestSnapshot.fromJson(
        Map<String, Object?>.from(json['snapshot']! as Map),
      ),
      state: _taskState(state),
      phase: _taskPhase(json['phase'] as String?),
      createdAt: createdAt,
      updatedAt: updatedAt,
      runId: runId,
      error: error,
    );
  }

  static GenerationTaskState _taskState(String value) {
    return switch (value) {
      'leased' => GenerationTaskState.claimed,
      'running' => GenerationTaskState.streaming,
      'succeeded' => GenerationTaskState.completed,
      'cancelled' => GenerationTaskState.cancelled,
      'failed' => GenerationTaskState.failed,
      'interrupted' => GenerationTaskState.interruptedPartial,
      'outcome_unknown' => GenerationTaskState.outcomeUnknown,
      _ => GenerationTaskState.values.firstWhere(
        (GenerationTaskState state) => state.name == value,
      ),
    };
  }

  static GenerationTaskPhase _taskPhase(String? value) {
    if (value == null) {
      throw const FormatException('Generation task phase is missing.');
    }
    return GenerationTaskPhase.values.firstWhere(
      (GenerationTaskPhase phase) => phase.name == value,
    );
  }

  GenerationTask copyWith({
    int? enqueueSequence,
    GenerationRequestSnapshot? snapshot,
    GenerationTaskState? state,
    GenerationTaskPhase? phase,
    DateTime? updatedAt,
    String? runId,
    String? error,
  }) {
    return GenerationTask(
      id: id,
      conversationId: conversationId,
      inputMessageId: inputMessageId,
      outputMessageId: outputMessageId,
      enqueueSequence: enqueueSequence ?? this.enqueueSequence,
      snapshot: snapshot ?? this.snapshot,
      state: state ?? this.state,
      phase: phase ?? this.phase,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      runId: runId ?? this.runId,
      error: error ?? this.error,
    );
  }
}

class GenerationCommand {
  const GenerationCommand({
    required this.id,
    required this.taskId,
    required this.sequence,
    required this.kind,
    required this.state,
    required this.createdAt,
    this.payload,
  });

  final String id;
  final String taskId;
  final int sequence;
  final GenerationCommandKind kind;
  final GenerationCommandState state;
  final DateTime createdAt;
  final String? payload;
}
