import '../grab_models.dart';
import 'extractor.dart';

/// Vimeo via the embed player's config JSON. Progressive MP4 is used when the
/// video still offers it; otherwise the HLS master (separate audio group).
class VimeoExtractor extends MediaExtractor {
  const VimeoExtractor();

  @override
  String get service => 'Vimeo';

  @override
  bool canHandle(Uri uri) =>
      hostIs(uri, const ['vimeo.com']) && _parse(uri) != null;

  /// Returns `(id, unlistedHash)`.
  static (String, String?)? _parse(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final hash = uri.queryParameters['h'];
    for (var i = 0; i < segments.length; i++) {
      if (RegExp(r'^\d{5,}$').hasMatch(segments[i])) {
        final next = i + 1 < segments.length ? segments[i + 1] : null;
        final unlisted =
            next != null && RegExp(r'^[0-9a-f]{6,}$').hasMatch(next)
            ? next
            : hash;
        return (segments[i], unlisted);
      }
    }
    return null;
  }

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    final (id, hash) = _parse(uri)!;
    final headers = {'Referer': 'https://vimeo.com/'};
    final json = await context.http.getJson(
      Uri.https('player.vimeo.com', '/video/$id/config', {'h': ?hash}),
      headers: headers,
    );
    final title = jsonString(json, ['video', 'title']) ?? 'Vimeo video';
    final owner = jsonString(json, ['video', 'owner', 'name']);
    final seconds = jsonInt(json, ['video', 'duration']);
    final thumb = Uri.tryParse(
      jsonString(json, ['video', 'thumbs', 'base']) ??
          jsonString(json, ['video', 'thumbs', '640']) ??
          '',
    );
    final base = grabSafeFilename(title);
    final duration = seconds == null ? null : Duration(seconds: seconds);

    final progressive = jsonPath(json, ['request', 'files', 'progressive']);
    if (progressive is List &&
        progressive.isNotEmpty &&
        context.options.mode == GrabMode.auto) {
      final max = context.options.maxHeight;
      final entries = [
        for (final p in progressive)
          if (jsonString(p, ['url']) != null)
            (
              url: Uri.parse(jsonString(p, ['url'])!),
              height: grabShortSide(
                jsonInt(p, ['width']),
                jsonInt(p, ['height']),
              ),
            ),
      ];
      final fitting = entries
          .where((e) => max == null || e.height == null || e.height! <= max)
          .toList();
      final pool = fitting.isNotEmpty ? fitting : entries;
      pool.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
      if (pool.isNotEmpty) {
        return GrabMedia(
          service: service,
          title: title,
          author: owner,
          thumbnail: thumb,
          items: [
            GrabItem(
              kind: GrabKind.video,
              name: base,
              duration: duration,
              thumbnail: thumb,
              label: pool.first.height == null
                  ? 'Video'
                  : '${pool.first.height}p',
              inputs: [
                GrabStream(
                  url: pool.first.url,
                  track: GrabTrack.muxed,
                  extension: 'mp4',
                ),
              ],
            ),
          ],
        );
      }
    }

    final hls = jsonPath(json, ['request', 'files', 'hls']);
    final cdns = jsonPath(hls, ['cdns']);
    String? master;
    if (cdns is Map && cdns.isNotEmpty) {
      final preferred =
          cdns[jsonString(hls, ['default_cdn'])] ?? cdns.values.first;
      master =
          jsonString(preferred, ['avc_url']) ?? jsonString(preferred, ['url']);
    }
    if (master == null) {
      throw const GrabException(
        'That Vimeo video isn\'t downloadable (it may be private or '
        'embed-only).',
      );
    }
    return GrabMedia(
      service: service,
      title: title,
      author: owner,
      thumbnail: thumb,
      items: [
        GrabItem(
          kind: context.options.mode == GrabMode.audio
              ? GrabKind.audio
              : GrabKind.video,
          name: base,
          duration: duration,
          thumbnail: thumb,
          label: 'Video',
          inputs: [
            GrabStream(
              url: Uri.parse(master),
              track: GrabTrack.muxed,
              hls: true,
              headers: headers,
            ),
          ],
        ),
      ],
    );
  }
}
