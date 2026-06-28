import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'sse_client_fetch_native.dart'
    if (dart.library.html) 'sse_client_fetch_web.dart'
    as fetch;

/// A minimal Server-Sent Events client.
///
/// On **web**, uses the browser `fetch` API with `ReadableStream.getReader()`
/// — this is the only way to get true token-by-token streaming in a browser.
/// Dio's web adapter uses `XMLHttpRequest` with `responseType: arraybuffer`,
/// which buffers the entire response before firing.
///
/// On **native** (Android/iOS/desktop), uses Dio with `ResponseType.stream`,
/// which streams chunks as they arrive via `dart:io.HttpClient`.
class SseClient {
  SseClient(this._dio);

  final Dio _dio;

  static final Logger _log = Logger('sse');

  /// Opens [method] [url] and streams SSE events until the server closes the
  /// connection or the caller cancels via [cancelToken].
  Stream<SseEvent> stream({
    required String url,
    required String method,
    Map<String, dynamic>? headers,
    Object? body,
    CancelToken? cancelToken,
  }) async* {
    _log.fine('stream: $method $url');

    final StreamController<List<int>> byteSink = StreamController<List<int>>();

    // Kick off the fetch in the background, feeding chunks into byteSink.
    final Future<void> fetcher = fetch
        .fetchStream(
          dio: _dio,
          url: url,
          method: method,
          headers: headers,
          body: body,
          cancelToken: cancelToken,
          sink: byteSink,
        )
        .catchError((Object e, StackTrace s) {
          if (!byteSink.isClosed) byteSink.addError(e, s);
        });

    final StringBuffer lineBuffer = StringBuffer();
    final List<String> dataLines = <String>[];

    try {
      await for (final List<int> chunk in byteSink.stream) {
        if (cancelToken?.isCancelled ?? false) break;

        lineBuffer.write(utf8.decode(chunk, allowMalformed: true));
        final String buffered = lineBuffer.toString();
        lineBuffer.clear();

        int lastBoundary = 0;
        int idx = buffered.indexOf('\n\n');
        while (idx != -1) {
          final String rawEvent = buffered.substring(lastBoundary, idx);
          final SseEvent? event = _parseEvent(rawEvent, dataLines);
          if (event != null) {
            _log.fine(
              'sse event: ${event.data.substring(0, event.data.length.clamp(0, 200))}',
            );
            yield event;
          }
          lastBoundary = idx + 2;
          idx = buffered.indexOf('\n\n', lastBoundary);
        }
        if (lastBoundary < buffered.length) {
          lineBuffer.write(buffered.substring(lastBoundary));
        }
      }

      _log.fine('stream: byte stream ended; flushing remaining buffer');
      if (lineBuffer.isNotEmpty) {
        final SseEvent? event = _parseEvent(lineBuffer.toString(), dataLines);
        if (event != null) {
          _log.fine(
            'sse event (flushed): ${event.data.substring(0, event.data.length.clamp(0, 200))}',
          );
          yield event;
        }
      }
    } finally {
      await fetcher;
      await byteSink.close();
    }
  }

  SseEvent? _parseEvent(String rawEvent, List<String> dataLines) {
    dataLines.clear();
    for (final String line in rawEvent.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isEmpty) return null;
    return SseEvent(dataLines.join('\n'));
  }
}

/// One parsed SSE event. [data] is the joined `data:` payload.
class SseEvent {
  const SseEvent(this.data);

  final String data;
}
