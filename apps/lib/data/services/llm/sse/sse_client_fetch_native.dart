import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

final Logger _log = Logger('sse');

/// Native (non-web) SSE transport: Dio with `ResponseType.stream`.
///
/// On native platforms Dio uses `dart:io.HttpClient`, which streams chunks as
/// they arrive — no browser fetch API needed.
Future<void> fetchStream({
  required Dio dio,
  required String url,
  required String method,
  required Map<String, dynamic>? headers,
  required Object? body,
  required CancelToken? cancelToken,
  required StreamController<List<int>> sink,
}) async {
  _log.fine('dio stream: $method $url');

  final Response<ResponseBody> response = await dio.request<ResponseBody>(
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
    final ResponseBody? rb = response.data;
    String bodyStr = '';
    if (rb != null) {
      final List<int> bytes = await rb.stream.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      bodyStr = utf8.decode(bytes, allowMalformed: true);
    }
    _log.warning('dio stream: non-200 status=${response.statusCode} url=$url');
    throw DioException(
      requestOptions: response.requestOptions,
      response: Response(
        requestOptions: response.requestOptions,
        statusCode: response.statusCode,
        data: bodyStr,
      ),
      type: DioExceptionType.badResponse,
    );
  }

  _log.fine('dio stream: connected, reading SSE stream');
  final ResponseBody? rb = response.data;
  if (rb == null) {
    throw StateError('Response body is null — cannot stream.');
  }

  try {
    await for (final List<int> chunk in rb.stream) {
      if (sink.isClosed) break;
      sink.add(chunk);
    }
    _log.fine('dio stream: stream complete');
  } finally {
    // Drain any remaining bytes so the underlying socket is released.
    await rb.stream.drain<void>();
  }
}
