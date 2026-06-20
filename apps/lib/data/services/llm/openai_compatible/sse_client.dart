import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// A minimal Server-Sent Events client built on top of [Dio]'s response
/// stream.
///
/// Dio doesn't speak SSE natively, but `ResponseType.stream` gives us a raw
/// byte stream we can decode and split on `\n\n` boundaries. This yields one
/// `SseEvent` per logical event, handling `data:` lines (including multi-line
/// `data:` payloads joined with `\n`) and ignoring `event:`/`id:`/`retry:`
/// lines (we don't need them for chat completions).
class SseClient {
  SseClient(this._dio);

  final Dio _dio;

  /// Opens [method] [url] and streams SSE events until the server closes the
  /// connection or the caller cancels via [cancelToken].
  Stream<SseEvent> stream({
    required String url,
    required String method,
    Map<String, dynamic>? headers,
    Object? body,
    CancelToken? cancelToken,
  }) async* {
    final Response<ResponseBody> response = await _dio.request<ResponseBody>(
      url,
      data: body,
      options: Options(
        method: method,
        headers: <String, dynamic>{'Accept': 'text/event-stream', ...?headers},
        responseType: ResponseType.stream,
      ),
      cancelToken: cancelToken,
    );

    if (response.statusCode != 200) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }

    final Stream<List<int>> byteStream = response.data!.stream;
    final StringBuffer lineBuffer = StringBuffer();
    final List<String> dataLines = <String>[];

    await for (final List<int> chunk in byteStream) {
      if (cancelToken?.isCancelled ?? false) break;

      // Decode bytes → text. UTF-8 decoder handles multi-byte chars split
      // across chunks.
      lineBuffer.write(utf8.decode(chunk, allowMalformed: true));
      final String buffered = lineBuffer.toString();
      lineBuffer.clear();

      // SSE events are separated by a blank line. Split on \n\n but keep the
      // remainder (incomplete trailing event) in the buffer for the next chunk.
      int lastBoundary = 0;
      int idx = buffered.indexOf('\n\n');
      while (idx != -1) {
        final String rawEvent = buffered.substring(lastBoundary, idx);
        final SseEvent? event = _parseEvent(rawEvent, dataLines);
        if (event != null) yield event;
        lastBoundary = idx + 2;
        idx = buffered.indexOf('\n\n', lastBoundary);
      }
      if (lastBoundary < buffered.length) {
        lineBuffer.write(buffered.substring(lastBoundary));
      }
    }

    // Flush any final event without a trailing blank line.
    if (lineBuffer.isNotEmpty) {
      final SseEvent? event = _parseEvent(lineBuffer.toString(), dataLines);
      if (event != null) yield event;
    }
  }

  SseEvent? _parseEvent(String rawEvent, List<String> dataLines) {
    dataLines.clear();
    for (final String line in rawEvent.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
      // `event:`, `id:`, `retry:` are ignored — chat completions don't use them.
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
