import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the app process alive while the Dart isolate executes generation.
abstract class GenerationHost {
  Future<void> ensureRunning();

  Future<void> stop();
}

class InlineGenerationHost implements GenerationHost {
  @override
  Future<void> ensureRunning() async {}

  @override
  Future<void> stop() async {}
}

class AndroidGenerationHost implements GenerationHost {
  AndroidGenerationHost({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.example.havencat/generation_host');

  final MethodChannel _channel;

  @override
  Future<void> ensureRunning() async {
    final bool? started = await _channel.invokeMethod<bool>('ensureRunning');
    if (started != true) {
      throw StateError('Android generation host did not start.');
    }
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }
}

GenerationHost createGenerationHost() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidGenerationHost();
  }
  return InlineGenerationHost();
}
