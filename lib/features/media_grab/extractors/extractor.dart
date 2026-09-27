import '../grab_http.dart';
import '../grab_models.dart';

/// Everything an extractor may use while resolving a link.
class GrabContext {
  GrabContext({required this.http, required this.options});

  final GrabHttp http;
  final GrabOptions options;
}

/// Turns a public post/page URL into downloadable [GrabItem]s.
abstract class MediaExtractor {
  const MediaExtractor();

  /// Display name, e.g. `YouTube`.
  String get service;

  bool canHandle(Uri uri);

  /// True when [uri] points at downloadable media (not just the site), so a
  /// shared link can be routed to Grab.
  bool isMediaLink(Uri uri) => canHandle(uri);

  Future<GrabMedia> extract(Uri uri, GrabContext context);
}

/// `example.com`, `www.example.com` and `m.example.com` all match `example.com`.
bool hostIs(Uri uri, List<String> domains) {
  final host = uri.host.toLowerCase();
  return domains.any((d) => host == d || host.endsWith('.$d'));
}

/// Sub-map/list navigation for loosely typed JSON.
Object? jsonPath(Object? root, List<Object> path) {
  var node = root;
  for (final key in path) {
    if (key is String && node is Map) {
      node = node[key];
    } else if (key is int && node is List && key >= 0 && key < node.length) {
      node = node[key];
    } else {
      return null;
    }
  }
  return node;
}

String? jsonString(Object? root, List<Object> path) {
  final value = jsonPath(root, path);
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int? jsonInt(Object? root, List<Object> path) {
  final value = jsonPath(root, path);
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String extensionOf(Uri uri, {String fallback = 'mp4'}) {
  final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = last.lastIndexOf('.');
  if (dot < 0 || dot == last.length - 1) return fallback;
  final ext = last.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext) ? ext : fallback;
}
