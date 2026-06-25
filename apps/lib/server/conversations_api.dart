import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../data/services/storage/conversation_store.dart';
import '../domain/models/conversation.dart';

final Logger _log = Logger('conversations_api');

/// Shelf handler exposing conversation persistence as same-origin JSON routes
/// for the web build. The native apps call [RustConversationStore] directly
/// via FRB FFI.
///
/// Routes:
///   GET    /api/conversations                  → JSON array of conversations
///   PUT    /api/conversations/`<id>`            → upsert (body: conversation JSON)
///   DELETE /api/conversations/`<id>`            → 204
Handler conversationsApiHandler(ConversationStore store) {
  return (Request request) async {
    final origin = request.headers['origin'];
    if (request.method == 'OPTIONS' && origin != null) {
      return Response.ok(null, headers: _corsHeaders(origin));
    }

    final path = request.url.path;
    final subPath = path.startsWith('api/') ? path.substring(4) : path;

    try {
      final Response response;
      if (subPath == 'conversations' && request.method == 'GET') {
        response = await _handleList(store);
      } else if (subPath.startsWith('conversations/') &&
          request.method == 'PUT') {
        response = await _handleUpsert(store, request, subPath);
      } else if (subPath.startsWith('conversations/') &&
          request.method == 'DELETE') {
        response = await _handleDelete(store, subPath);
      } else {
        response = Response.notFound('unknown conversations route: $path');
      }
      return _withCors(response, origin);
    } catch (e, st) {
      _log.severe('request failed: ${request.method} $path', e, st);
      return _withCors(
        Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: _jsonHeaders,
        ),
        origin,
      );
    }
  };
}

Future<Response> _handleList(ConversationStore store) async {
  final List<Conversation> convs = await store.load();
  return _jsonResponse(200, convs.map((c) => c.toJson()).toList());
}

Future<Response> _handleUpsert(
  ConversationStore store,
  Request request,
  String subPath,
) async {
  final id = subPath.substring('conversations/'.length);
  final body = await request.readAsString();
  final json = jsonDecode(body) as Map<String, dynamic>;
  final conv = Conversation.fromJson(json);
  if (conv.id != id) {
    return _badRequest('id mismatch: path=$id body=${conv.id}');
  }
  await store.upsert(conv);
  return Response(204);
}

Future<Response> _handleDelete(ConversationStore store, String subPath) async {
  final id = subPath.substring('conversations/'.length);
  await store.delete(id);
  return Response(204);
}

Map<String, String> _corsHeaders(String origin) => <String, String>{
  'access-control-allow-origin': origin,
  'access-control-allow-methods': 'GET, PUT, DELETE, OPTIONS',
  'access-control-allow-headers': 'content-type',
  'access-control-max-age': '86400',
  'vary': 'origin',
};

Response _withCors(Response response, String? origin) {
  if (origin == null) return response;
  return response.change(headers: _corsHeaders(origin));
}

Response _badRequest(String message) =>
    Response(400, body: jsonEncode({'error': message}));

Response _jsonResponse(int status, Object body) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

const Map<String, String> _jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};
