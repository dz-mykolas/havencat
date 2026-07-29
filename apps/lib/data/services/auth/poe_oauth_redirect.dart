import 'poe_oauth_redirect_stub.dart'
    if (dart.library.io) 'poe_oauth_redirect_io.dart'
    as platform;
import 'poe_oauth_redirect_types.dart';

export 'poe_oauth_redirect_types.dart';

Future<PoeOAuthRedirectListener?> startPoeOAuthRedirectListener() =>
    platform.startPoeOAuthRedirectListener();
