import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'grab_models.dart';

/// Desktop browser UA: most sites serve their full page data to it.
const String kGrabUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

class GrabResponse {
  const GrabResponse({
    required this.status,
    required this.uri,
    required this.body,
    required this.contentType,
  });

  final int status;

  /// Final URL after redirects.
  final Uri uri;
  final String body;
  final String contentType;

  bool get ok => status >= 200 && status < 300;

  Object? json() {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const GrabException('The site sent an unreadable response.');
    }
  }
}

/// Small HTTP client for extractors: browser headers, manual redirects and a
/// per-grab cookie jar (TikTok, for example, only serves the video file to the
/// session that loaded the page).
class GrabHttp {
  GrabHttp() {
    _client
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 20)
      ..userAgent = kGrabUserAgent
      ..autoUncompress = true;
  }

  static const Duration _timeout = Duration(seconds: 25);
  static const int _maxRedirects = 8;

  final HttpClient _client = HttpClient();

  /// host → cookie name → value.
  final Map<String, Map<String, String>> _cookies = {};

  Future<GrabResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    final res = await open(uri, headers: headers);
    final contentType = res.response.headers.contentType?.mimeType ?? '';
    final bytes = <int>[];
    try {
      await for (final chunk in res.response.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) break;
      }
    } on TimeoutException {
      throw const GrabException('The site took too long to respond.');
    }
    return GrabResponse(
      status: res.response.statusCode,
      uri: res.uri,
      body: utf8.decode(bytes, allowMalformed: true),
      contentType: contentType,
    );
  }

  Future<Object?> getJson(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final res = await get(
      uri,
      headers: {'Accept': 'application/json', ...headers},
    );
    if (res.status == 404) {
      throw const GrabException('That post doesn\'t exist or was removed.');
    }
    if (res.status == 401 || res.status == 403) {
      throw const GrabException('That post is private or blocked here.');
    }
    if (res.status == 429) {
      throw const GrabException('The site is rate limiting. Try again soon.');
    }
    if (!res.ok) {
      throw GrabException(
        'The site returned an error (HTTP ${res.status}).',
        detail: res.body.length > 400 ? res.body.substring(0, 400) : res.body,
      );
    }
    return res.json();
  }

  /// Form-encoded POST returning decoded JSON (used for OAuth tokens).
  Future<Object?> postForm(
    Uri uri,
    Map<String, String> fields, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final req = await _client.postUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      headers.forEach(req.headers.set);
      req.write(Uri(queryParameters: fields).query);
      final res = await req.close().timeout(_timeout);
      final body = await utf8.decodeStream(res).timeout(_timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw GrabException(
          'Sign-in to the site failed (HTTP ${res.statusCode}).',
          detail: body,
        );
      }
      return jsonDecode(body);
    } on SocketException catch (e) {
      throw GrabException('Could not connect: ${e.message}');
    } on TimeoutException {
      throw const GrabException('The site took too long to respond.');
    } on FormatException {
      throw const GrabException('The site sent an unreadable response.');
    }
  }

  /// Follows redirects and returns the final URL (for share short links).
  Future<Uri> resolveRedirects(Uri uri) async {
    final res = await open(uri);
    await res.response.drain<void>().catchError((_) {});
    return res.uri;
  }

  /// Opens a streaming response after following redirects. Callers must
  /// consume or drain the body.
  Future<({HttpClientResponse response, Uri uri})> open(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    var current = uri;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final HttpClientResponse response;
      try {
        final req = await _client.getUrl(current).timeout(_timeout);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
        if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
          req.headers.set(HttpHeaders.acceptHeader, '*/*');
        }
        headers.forEach(req.headers.set);
        final cookie = cookieHeader(current);
        if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
        response = await req.close().timeout(_timeout);
      } on SocketException catch (e) {
        throw GrabException('Could not connect: ${e.message}');
      } on HandshakeException {
        throw const GrabException('Secure connection to the site failed.');
      } on TimeoutException {
        throw const GrabException('The site took too long to respond.');
      }
      _storeCookies(current, response);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().catchError((_) {});
        if (location == null) break;
        current = current.resolve(location);
        continue;
      }
      return (response: response, uri: current);
    }
    throw const GrabException('Too many redirects.');
  }

  /// `Cookie` header value for [uri], or null when the jar has none.
  String? cookieHeader(Uri uri) {
    final host = uri.host.toLowerCase();
    final pairs = <String, String>{};
    for (final entry in _cookies.entries) {
      if (host == entry.key || host.endsWith('.${entry.key}')) {
        pairs.addAll(entry.value);
      }
    }
    if (pairs.isEmpty) return null;
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void _storeCookies(Uri uri, HttpClientResponse response) {
    final List<Cookie> cookies;
    try {
      cookies = response.cookies;
    } catch (_) {
      // A malformed Set-Cookie header shouldn't fail the whole request.
      return;
    }
    for (final cookie in cookies) {
      var domain = (cookie.domain ?? uri.host).toLowerCase();
      if (domain.startsWith('.')) domain = domain.substring(1);
      _cookies.putIfAbsent(domain, () => {})[cookie.name] = cookie.value;
    }
  }

  void close() => _client.close(force: true);
}

/// Pulls the first `<meta property|name=KEY content=...>` value out of HTML.
String? htmlMeta(String html, String key) {
  final escaped = RegExp.escape(key);
  final patterns = [
    RegExp(
      '<meta[^>]+(?:property|name)=["\']$escaped["\'][^>]*content=["\']([^"\']+)["\']',
      caseSensitive: false,
    ),
    RegExp(
      '<meta[^>]+content=["\']([^"\']+)["\'][^>]*(?:property|name)=["\']$escaped["\']',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(html);
    if (match != null) return htmlUnescape(match.group(1)!);
  }
  return null;
}

String htmlUnescape(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');
