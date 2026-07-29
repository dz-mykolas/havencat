class PoeOAuthRedirectListener {
  const PoeOAuthRedirectListener({
    required this.redirectUri,
    required this.callbackUri,
    required this.close,
  });

  final Uri redirectUri;
  final Future<Uri> callbackUri;
  final Future<void> Function() close;
}
