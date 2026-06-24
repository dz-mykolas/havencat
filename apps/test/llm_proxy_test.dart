import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';

import 'package:app/server/llm_proxy.dart';

/// Tests for the bundled Shelf reverse proxy that lets the web build reach
/// non-CORS LLM providers from the same origin.
void main() {
  Request proxyRequest(
    String method, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return Request(
      method,
      Uri.parse('http://localhost:8088/proxy'),
      headers: headers,
      body: body,
    );
  }

  test(
    'non-proxy paths return 404 (so a static handler can take over)',
    () async {
      final Handler handler = llmProxyHandler(
        client: MockClient((_) async => http.Response('', 200)),
      );
      final Response res = await handler(
        Request('GET', Uri.parse('http://localhost:8088/index.html')),
      );
      expect(res.statusCode, 404);
    },
  );

  test('OPTIONS preflight is answered with CORS headers', () async {
    final Handler handler = llmProxyHandler(
      client: MockClient((_) async => http.Response('', 200)),
    );
    final Response res = await handler(
      proxyRequest(
        'OPTIONS',
        headers: <String, String>{
          'origin': 'http://localhost:8080',
          'access-control-request-headers': 'authorization, x-upstream-url',
        },
      ),
    );
    expect(res.statusCode, 200);
    expect(res.headers['access-control-allow-origin'], 'http://localhost:8080');
    expect(
      res.headers['access-control-allow-headers'],
      contains('authorization'),
    );
  });

  test('missing upstream header → 400', () async {
    final Handler handler = llmProxyHandler(
      client: MockClient((_) async => http.Response('', 200)),
    );
    final Response res = await handler(
      proxyRequest('POST', headers: <String, String>{}, body: '{}'),
    );
    expect(res.statusCode, 400);
  });

  test('upstream host not on the allowlist → 403', () async {
    final Handler handler = llmProxyHandler(
      client: MockClient((_) async => http.Response('', 200)),
    );
    final Response res = await handler(
      proxyRequest(
        'POST',
        headers: <String, String>{
          upstreamHeader: 'https://evil.example.com/steal',
        },
        body: '{}',
      ),
    );
    expect(res.statusCode, 403);
  });

  test('forwards method/headers/body and streams the response back', () async {
    late http.BaseRequest captured;
    final Handler handler = llmProxyHandler(
      client: MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream body,
      ) async {
        captured = request;
        await body.bytesToString();
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            utf8.encode('data: hello\n\n'),
            utf8.encode('data: [DONE]\n\n'),
          ]),
          200,
          headers: <String, String>{'content-type': 'text/event-stream'},
        );
      }),
    );

    final Response res = await handler(
      proxyRequest(
        'POST',
        headers: <String, String>{
          upstreamHeader: 'https://api.openai.com/v1/chat/completions',
          'authorization': 'Bearer sk-test',
          'content-type': 'application/json',
          'origin': 'http://localhost:8080',
          'accept-encoding': 'gzip, deflate, br',
        },
        body: '{"model":"gpt-4o"}',
      ),
    );

    expect(res.statusCode, 200);
    expect(
      captured.url.toString(),
      'https://api.openai.com/v1/chat/completions',
    );
    expect(captured.headers['authorization'], 'Bearer sk-test');
    // Control + origin headers must not leak upstream.
    expect(captured.headers.containsKey('x-upstream-url'), isFalse);
    expect(captured.headers.containsKey('origin'), isFalse);
    // The browser's accept-encoding must NOT be forwarded, or Cloudflare may
    // reply with brotli that Dart's client can't decompress (gibberish body).
    expect(captured.headers.containsKey('accept-encoding'), isFalse);
    expect(res.headers['access-control-allow-origin'], 'http://localhost:8080');

    final String streamed = await res.readAsString();
    expect(streamed, contains('data: hello'));
    expect(streamed, contains('[DONE]'));
  });

  test('allowedHosts {*} permits any https upstream', () async {
    late http.BaseRequest captured;
    final Handler handler = llmProxyHandler(
      allowedHosts: <String>{'*'},
      client: MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream body,
      ) async {
        captured = request;
        return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
      }),
    );
    final Response res = await handler(
      proxyRequest(
        'POST',
        headers: <String, String>{
          upstreamHeader: 'https://anything.example.com/v1/x',
        },
        body: '{}',
      ),
    );
    expect(res.statusCode, 200);
    expect(captured.url.host, 'anything.example.com');
  });
}
