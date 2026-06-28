import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:web/web.dart' as web;

final Logger _log = Logger('sse');

/// Web SSE transport: browser Fetch API + `ReadableStream.getReader()`.
///
/// This is the only way to get true token-by-token streaming in a browser.
/// Dio's web adapter uses `XMLHttpRequest` with `responseType: arraybuffer`,
/// which buffers the entire response before firing.
Future<void> fetchStream({
  required Dio dio,
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

      final Uint8List bytes = (chunkValue as JSUint8Array).toDart;
      if (!sink.isClosed) sink.add(bytes);
    }
    _log.fine('fetch: stream complete');
  } finally {
    reader.releaseLock();
  }
}
