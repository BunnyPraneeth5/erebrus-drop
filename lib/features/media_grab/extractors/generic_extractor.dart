import '../grab_http.dart';
import '../grab_models.dart';
import 'extractor.dart';

/// Fallback for any other link: direct media files, HLS playlists, and web
/// pages that advertise their media through OpenGraph/Twitter card tags or
/// a plain `<video>`/`<audio>` element.
class GenericExtractor extends MediaExtractor {
  const GenericExtractor();

  static const _video = {'mp4', 'm4v', 'mov', 'webm', 'mkv'};
  static const _audio = {'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac'};
  static const _image = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif'};

  @override
  String get service => 'Web';

  @override
  bool canHandle(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    final direct = _fromExtension(uri);
    if (direct != null) return _single(uri, direct);

    final res = await context.http.get(uri, maxBytes: 2 * 1024 * 1024);
    if (!res.ok) {
      throw GrabException('The page returned an error (HTTP ${res.status}).');
    }
    final type = res.contentType.toLowerCase();
    final byType = _fromContentType(type, res.uri);
    if (byType != null) return _single(res.uri, byType);
    if (!type.contains('html')) {
      throw const GrabException('No media found at that link.');
    }

    final html = res.body;
    final candidates = <String?>[
      if (context.options.mode != GrabMode.audio) ...[
        htmlMeta(html, 'og:video:secure_url'),
        htmlMeta(html, 'og:video:url'),
        htmlMeta(html, 'og:video'),
        htmlMeta(html, 'twitter:player:stream'),
      ],
      htmlMeta(html, 'og:audio:secure_url'),
      htmlMeta(html, 'og:audio'),
      _firstTagSource(html),
    ];
    for (final candidate in candidates) {
      if (candidate == null || candidate.isEmpty) continue;
      final media = res.uri.resolve(candidate);
      final kind =
          _fromExtension(media) ??
          (media.path.contains('.m3u8') ? GrabKind.video : null);
      if (kind == null) continue;
      return _single(media, kind, title: _title(html), page: res.uri);
    }
    final image = htmlMeta(html, 'og:image');
    if (image != null && context.options.mode == GrabMode.auto) {
      final media = res.uri.resolve(image);
      return _single(media, GrabKind.photo, title: _title(html), page: res.uri);
    }
    throw const GrabException(
      'No downloadable media found on that page. The site may need a login '
      'or isn\'t supported yet.',
    );
  }

  GrabKind? _fromExtension(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m3u8')) return GrabKind.video;
    final ext = extensionOf(uri, fallback: '');
    if (_video.contains(ext)) return GrabKind.video;
    if (_audio.contains(ext)) return GrabKind.audio;
    if (ext == 'gif') return GrabKind.gif;
    if (_image.contains(ext)) return GrabKind.photo;
    return null;
  }

  GrabKind? _fromContentType(String type, Uri uri) {
    if (type.contains('mpegurl')) return GrabKind.video;
    if (type.startsWith('video/')) return GrabKind.video;
    if (type.startsWith('audio/')) return GrabKind.audio;
    if (type == 'image/gif') return GrabKind.gif;
    if (type.startsWith('image/')) return GrabKind.photo;
    return null;
  }

  String? _firstTagSource(String html) {
    final match = RegExp(
      r"""<(?:video|audio|source)[^>]+src=["']([^"']+)["']""",
      caseSensitive: false,
    ).firstMatch(html);
    return match == null ? null : htmlUnescape(match.group(1)!);
  }

  String? _title(String html) =>
      htmlMeta(html, 'og:title') ??
      RegExp(
        r'<title[^>]*>([^<]+)</title>',
        caseSensitive: false,
      ).firstMatch(html)?.group(1)?.trim();

  GrabMedia _single(Uri media, GrabKind kind, {String? title, Uri? page}) {
    final hls = media.path.toLowerCase().contains('.m3u8');
    final fallbackExt = switch (kind) {
      GrabKind.audio => 'mp3',
      GrabKind.photo => 'jpg',
      GrabKind.gif => 'gif',
      GrabKind.video => 'mp4',
    };
    final ext = hls ? 'mp4' : extensionOf(media, fallback: fallbackExt);
    final last = media.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    final name = title ?? (last == null ? media.host : _stripExt(last));
    return GrabMedia(
      service: page?.host ?? media.host,
      title: title ?? name,
      items: [
        GrabItem(
          kind: kind,
          name: grabSafeFilename(name),
          thumbnail: kind == GrabKind.photo ? media : null,
          label: ext.toUpperCase(),
          inputs: [
            GrabStream(
              url: media,
              hls: hls,
              extension: ext,
              headers: page == null ? const {} : {'Referer': page.toString()},
              track: switch (kind) {
                GrabKind.audio => GrabTrack.audio,
                GrabKind.photo || GrabKind.gif => GrabTrack.image,
                GrabKind.video => GrabTrack.muxed,
              },
            ),
          ],
        ),
      ],
    );
  }

  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
