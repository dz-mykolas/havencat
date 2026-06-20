import '../../../domain/models/message.dart';

/// A single chunk emitted while streaming an assistant reply.
///
/// Sealed so the controller can exhaustively switch over event types as we
/// add tool calls, reasoning tokens, etc. later — without touching the
/// adapter interface itself.
sealed class LlmEvent {
  const LlmEvent();
}

/// A piece of assistant text. Concatenate [delta] onto the running message.
final class TokenEvent extends LlmEvent {
  const TokenEvent(this.delta);

  final String delta;
}

/// The assistant is "thinking" (reasoning model). Shown separately from the
/// final answer in the UI. Concatenate [delta] onto a reasoning buffer.
final class ReasoningEvent extends LlmEvent {
  const ReasoningEvent(this.delta);

  final String delta;
}

/// The model invoked a tool. Future: tool-call approval + result round-trip.
final class ToolCallEvent extends LlmEvent {
  const ToolCallEvent({
    required this.id,
    required this.name,
    required this.args,
  });

  final String id;
  final String name;
  final String args;
}

/// Stream completed normally. Carries the provider's stop reason if any.
final class DoneEvent extends LlmEvent {
  const DoneEvent({this.finishReason});

  final String? finishReason;
}

/// Stream failed. [error] is typed so the UI can distinguish auth/network/
/// rate-limit/quota failures.
final class ErrorEvent extends LlmEvent {
  const ErrorEvent(this.error);

  final LlmError error;
}

/// Typed error hierarchy for adapter failures.
sealed class LlmError {
  const LlmError(this.message);

  final String message;
}

final class NetworkError extends LlmError {
  const NetworkError(super.message);
}

final class AuthError extends LlmError {
  const AuthError(super.message);
}

final class RateLimitError extends LlmError {
  const RateLimitError(super.message);
}

final class QuotaError extends LlmError {
  const QuotaError(super.message);
}

final class InvalidRequestError extends LlmError {
  const InvalidRequestError(super.message);
}

final class UnknownError extends LlmError {
  const UnknownError(super.message);
}

/// What the adapter should generate, derived from a conversation + the user's
/// latest message. The repository builds this; the adapter consumes it.
class LlmRequest {
  const LlmRequest({
    required this.messages,
    required this.model,
    this.temperature,
    this.maxTokens,
    this.signal,
  });

  /// Full conversation history, oldest first, ending with the user's prompt.
  final List<ChatMessage> messages;

  /// Provider-specific model id, e.g. 'gpt-4o-mini' or 'qwen-max'.
  final String model;

  final double? temperature;
  final int? maxTokens;

  /// Cancellation signal. Adapters that support cancellation should abort the
  /// in-flight request when this fires.
  final Future<void> Function()? signal;
}
