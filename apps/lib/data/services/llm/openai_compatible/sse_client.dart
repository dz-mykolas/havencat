import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:web/web.dart' as web;

/// A minimal Server-Sent Events client.
///
/// On **web**, uses the browser `fetch` API with `ReadableStream.getReader()`
/// — this is the only way to get true token-by-token streaming in a browser.
/// Dio's web adapter uses `XMLHttpRequest` with `responseType: arraybuffer`,
/// which buffers the entire response before firing.
class SseClient {
  SseClient(Dio dio);

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
    final Future<void> fetcher =
        _fetchWeb(
          url: url,
          method: method,
          headers: headers,
          body: body,
          cancelToken: cancelToken,
          sink: byteSink,
        ).catchError((Object e, StackTrace s) {
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

  /// Web implementation using the Fetch API + ReadableStream.
  Future<void> _fetchWeb({
    required String url,
    required String method,
    required Map<String, dynamic>? headers,
    required Object? body,
    required CancelToken? cancelToken,
    required StreamController<List<int>> sink,
  }) async {
    final web.Headers fetchHeaders = web.Headers();
    fetchHeaders.append('Accept', 'text/event-stream');
    headers?.forEach((String key, dynamic value) {
      fetchHeaders.append(key, value.toString());
    });

    final web.RequestInit init = web.RequestInit(method: method);
    init.headers = fetchHeaders;
    if (body != null) {
      init.body = (body as String).toJS;
    }

    _log.fine('fetch: $method $url');
    final web.Response response = await web.window.fetch(url.toJS, init).toDart;

    if (response.status != 200) {
      final JSString text = await response.text().toDart;
      final String bodyStr = text.toDart;
      _log.warning('fetch: non-200 status=${response.status} url=$url');
      throw DioException(
        requestOptions: RequestOptions(path: url, method: method),
        response: Response(
          requestOptions: RequestOptions(path: url, method: method),
          statusCode: response.status,
          data: bodyStr,
        ),
        type: DioExceptionType.badResponse,
      );
    }

    _log.fine('fetch: connected, reading SSE stream');
    final web.ReadableStream? bodyStream = response.body;
    if (bodyStream == null) {
      throw StateError('Response body is null — cannot stream.');
    }

    final web.ReadableStreamDefaultReader reader =
        bodyStream.getReader() as web.ReadableStreamDefaultReader;

    try {
      while (true) {
        final web.ReadableStreamReadResult result = await reader.read().toDart;
        if (result.done) break;

        final JSAny? chunkValue = result.value;
        if (chunkValue == null) continue;

        // The chunk is a Uint8Array in JS — convert to Dart Uint8List.
        final Uint8List bytes = (chunkValue as JSUint8Array).toDart;
        if (!sink.isClosed) sink.add(bytes);
      }
      _log.fine('fetch: stream complete');
    } finally {
      reader.releaseLock();
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
