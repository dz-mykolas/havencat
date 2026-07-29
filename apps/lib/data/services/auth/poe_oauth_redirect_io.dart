import 'dart:async';
import 'dart:io';

import 'poe_oauth_redirect_types.dart';

Future<PoeOAuthRedirectListener?> startPoeOAuthRedirectListener() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final Completer<Uri> callback = Completer<Uri>();
  bool closed = false;

  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!callback.isCompleted) {
      callback.completeError(StateError('Poe sign-in was cancelled.'));
    }
    await server.close(force: true);
  }

  unawaited(
    server.forEach((HttpRequest request) async {
      if (request.uri.path != '/oauth/poe/callback') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta name="viewport" '
          'content="width=device-width"><title>HavenCat</title>'
          '<p style="font:16px system-ui;padding:24px">'
          'Poe is connected. You can return to HavenCat.</p>',
        );
      await request.response.close();
      if (!callback.isCompleted) {
        callback.complete(
          Uri(
            scheme: 'http',
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            path: request.uri.path,
            query: request.uri.query,
          ),
        );
      }
      await close();
    }),
  );

  return PoeOAuthRedirectListener(
    redirectUri: Uri(
      scheme: 'http',
      host: 'localhost',
      port: server.port,
      path: '/oauth/poe/callback',
    ),
    callbackUri: callback.future,
    close: close,
  );
}
