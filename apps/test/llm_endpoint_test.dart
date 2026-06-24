import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/services/llm/llm_endpoint.dart';

/// [LlmEndpoint] decides direct (native) vs proxied (web) transport.
void main() {
  const String upstream = 'https://api.openai.com/v1/chat/completions';

  test('native (no proxy) sends straight to the upstream URL', () {
    const LlmEndpoint endpoint = LlmEndpoint();
    final ResolvedRequest r = endpoint.resolve(upstream, <String, String>{
      'Authorization': 'Bearer sk-x',
    });
    expect(endpoint.usesProxy, isFalse);
    expect(r.url, upstream);
    expect(r.headers.containsKey(LlmEndpoint.upstreamHeader), isFalse);
    expect(r.headers['Authorization'], 'Bearer sk-x');
  });

  test('web (proxy) routes via the proxy with the upstream in a header', () {
    const LlmEndpoint endpoint = LlmEndpoint(proxyBase: '/proxy');
    final ResolvedRequest r = endpoint.resolve(upstream, <String, String>{
      'Authorization': 'Bearer sk-x',
    });
    expect(endpoint.usesProxy, isTrue);
    expect(r.url, '/proxy');
    expect(r.headers[LlmEndpoint.upstreamHeader], upstream);
    expect(r.headers['Authorization'], 'Bearer sk-x');
  });

  test('empty proxy base is treated as direct', () {
    expect(const LlmEndpoint(proxyBase: '').usesProxy, isFalse);
  });
}
