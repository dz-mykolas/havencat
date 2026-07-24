enum WebEndpointScope { loopback, privateNetwork, publicNetwork, invalid }

class WebRetrievalEndpointPolicy {
  const WebRetrievalEndpointPolicy._();

  static String defaultSchemeForAddress(String address) {
    return classifyAddress(address) == WebEndpointScope.loopback
        ? 'http'
        : 'https';
  }

  static WebEndpointScope classifyAddress(String address) {
    final Uri? uri = Uri.tryParse('http://${address.trim()}');
    if (uri == null || !uri.hasAuthority) return WebEndpointScope.invalid;
    return classifyHost(uri.host);
  }

  static WebEndpointScope classifyHost(String value) {
    final String host = value.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty) return WebEndpointScope.invalid;
    if (host == 'localhost' || host.endsWith('.localhost')) {
      return WebEndpointScope.loopback;
    }
    if (host.contains(':')) return _classifyIpv6(host);

    final List<int>? octets = _ipv4Octets(host);
    if (octets != null) {
      if (octets.every((int octet) => octet == 0)) {
        return WebEndpointScope.invalid;
      }
      if (octets[0] == 127) return WebEndpointScope.loopback;
      if (octets[0] == 10 ||
          (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) ||
          (octets[0] == 169 && octets[1] == 254) ||
          (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
          (octets[0] == 192 && octets[1] == 168)) {
        return WebEndpointScope.privateNetwork;
      }
      return WebEndpointScope.publicNetwork;
    }

    if (host.endsWith('.local') ||
        host.endsWith('.localdomain') ||
        host.endsWith('.lan') ||
        host.endsWith('.internal') ||
        host.endsWith('.home.arpa') ||
        !host.contains('.')) {
      return WebEndpointScope.privateNetwork;
    }
    return WebEndpointScope.publicNetwork;
  }

  static String? validateSearxng({
    required String? endpoint,
    required bool hasAccessToken,
  }) {
    final Uri? uri = Uri.tryParse(endpoint?.trim() ?? '');
    if (uri == null ||
        !uri.hasAuthority ||
        !(uri.isScheme('https') || uri.isScheme('http'))) {
      return 'SearXNG requires an HTTP or HTTPS instance URL.';
    }
    final WebEndpointScope scope = classifyHost(uri.host);
    if (scope == WebEndpointScope.invalid) {
      return 'Enter a valid SearXNG instance address.';
    }
    if (uri.isScheme('https')) return null;
    if (scope == WebEndpointScope.publicNetwork) {
      return 'Public SearXNG instances require HTTPS.';
    }
    if (hasAccessToken && scope != WebEndpointScope.loopback) {
      return 'Access tokens require HTTPS outside this device.';
    }
    return null;
  }

  static WebEndpointScope _classifyIpv6(String host) {
    if (host == '::') return WebEndpointScope.invalid;
    if (host == '::1') return WebEndpointScope.loopback;
    if (host.startsWith('fc') ||
        host.startsWith('fd') ||
        RegExp(r'^fe[89ab]').hasMatch(host)) {
      return WebEndpointScope.privateNetwork;
    }
    return WebEndpointScope.publicNetwork;
  }

  static List<int>? _ipv4Octets(String host) {
    final List<String> parts = host.split('.');
    if (parts.length != 4) return null;
    final List<int> octets = <int>[];
    for (final String part in parts) {
      final int? octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      octets.add(octet);
    }
    return octets;
  }
}
