import 'dart:convert';

import '../grab_models.dart';
import 'extractor.dart';

/// TikTok videos and photo slideshows. The web page embeds the post as JSON
/// (`__UNIVERSAL_DATA_FOR_REHYDRATION__`); the CDN only serves files to the
/// cookie session that loaded that page, so downloads reuse our cookie jar.
class TiktokExtractor extends MediaExtractor {
  const TiktokExtractor();

  static final RegExp _id = RegExp(r'/(?:video|photo|v)/(\d+)');

  @override
  String get service => 'TikTok';

  @override
  bool canHandle(Uri uri) => hostIs(uri, const ['tiktok.com']);

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    var target = uri;
    if (!_id.hasMatch(target.path)) {
      // vm./vt. share links redirect to the canonical post URL.
      target = await context.http.resolveRedirects(uri);
    }
    final id = _id.firstMatch(target.path)?.group(1);
    if (id == null) {
      throw const GrabException('That TikTok link doesn\'t point to a post.');
    }
    final page = await context.http.get(
      Uri.https('www.tiktok.com', '/@i/video/$id'),
      headers: const {'Accept': 'text/html'},
    );
    if (page.uri.path.contains('/about')) {
      // TikTok sends blocked regions to its "about" page instead of the post.
      throw const GrabException('TikTok isn\'t available in your region.');
    }
    final match = RegExp(
      r'<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>',
      dotAll: true,
    ).firstMatch(page.body);
    if (match == null) {
      throw const GrabException(
        'TikTok didn\'t return the post. It may be private or region-locked.',
      );
    }
    final Object? data;
    try {
      data = jsonDecode(match.group(1)!);
    } on FormatException {
      throw const GrabException('TikTok sent an unreadable page.');
    }
    final detail = jsonPath(data, ['__DEFAULT_SCOPE__', 'webapp.video-detail']);
    final item = jsonPath(detail, ['itemInfo', 'itemStruct']);
    if (item is! Map) {
      final status = jsonInt(detail, ['statusCode']);
      throw GrabException(
        status == 10204 || status == 10216
            ? 'That TikTok is private or was removed.'
            : 'TikTok didn\'t return the post.',
      );
    }

    final author = jsonString(item, ['author', 'uniqueId']);
    final base = grabSafeFilename('tiktok-${author ?? 'user'}-$id');
    final headers = {'Referer': 'https://www.tiktok.com/'};
    final desc = jsonString(item, ['desc']);
    final title = desc == null || desc.isEmpty
        ? 'TikTok by @${author ?? 'user'}'
        : (desc.length > 80 ? '${desc.substring(0, 80)}…' : desc);
    final items = <GrabItem>[];

    final images = jsonPath(item, ['imagePost', 'images']);
    final musicUrl = Uri.tryParse(jsonString(item, ['music', 'playUrl']) ?? '');
    if (images is List && images.isNotEmpty) {
      if (context.options.mode != GrabMode.audio) {
        for (final (index, image) in images.indexed) {
          final url = Uri.tryParse(
            jsonString(image, ['imageURL', 'urlList', 0]) ?? '',
          );
          if (url == null) continue;
          items.add(
            GrabItem(
              kind: GrabKind.photo,
              name: '$base-${index + 1}',
              thumbnail: url,
              label: 'Photo ${index + 1}',
              inputs: [
                GrabStream(
                  url: url,
                  track: GrabTrack.image,
                  extension: _imageExt(url),
                  headers: headers,
                ),
              ],
            ),
          );
        }
      }
      if (musicUrl != null && musicUrl.hasScheme) {
        items.add(
          GrabItem(
            kind: GrabKind.audio,
            name: '$base-audio',
            label: 'Sound',
            inputs: [
              GrabStream(
                url: musicUrl,
                track: GrabTrack.audio,
                extension: 'mp3',
                headers: headers,
              ),
            ],
          ),
        );
      }
    } else {
      final video = _pickVideo(item, context.options.maxHeight);
      if (video == null) {
        throw const GrabException('No downloadable video in that TikTok.');
      }
      final cover = Uri.tryParse(jsonString(item, ['video', 'cover']) ?? '');
      final seconds = jsonInt(item, ['video', 'duration']);
      items.add(
        GrabItem(
          kind: GrabKind.video,
          name: base,
          thumbnail: cover,
          duration: seconds == null ? null : Duration(seconds: seconds),
          label: video.height == null ? 'Video' : '${video.height}p',
          inputs: [
            GrabStream(
              url: video.url,
              track: GrabTrack.muxed,
              extension: 'mp4',
              headers: headers,
            ),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      throw const GrabException('Nothing downloadable in that TikTok.');
    }
    return GrabMedia(
      service: service,
      title: title,
      author: author == null ? null : '@$author',
      items: items,
    );
  }

  ({Uri url, int? height})? _pickVideo(Map item, int? maxHeight) {
    final options = <({Uri url, int? height, int bitrate, bool h264})>[];
    final bitrates = jsonPath(item, ['video', 'bitrateInfo']);
    if (bitrates is List) {
      for (final b in bitrates) {
        final url = Uri.tryParse(
          jsonString(b, ['PlayAddr', 'UrlList', 0]) ?? '',
        );
        if (url == null || !url.hasScheme) continue;
        options.add((
          url: url,
          height: grabShortSide(
            jsonInt(b, ['PlayAddr', 'Width']),
            jsonInt(b, ['PlayAddr', 'Height']),
          ),
          bitrate: jsonInt(b, ['Bitrate']) ?? 0,
          h264: (jsonString(b, ['CodecType']) ?? 'h264').contains('264'),
        ));
      }
    }
    if (options.isNotEmpty) {
      final fitting = options
          .where(
            (o) =>
                maxHeight == null || o.height == null || o.height! <= maxHeight,
          )
          .toList();
      final pool = fitting.isNotEmpty ? fitting : options;
      // H.265 plays poorly on older devices; prefer H.264.
      final h264 = pool.where((o) => o.h264).toList();
      final best = (h264.isNotEmpty ? h264 : pool)
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      return (url: best.first.url, height: best.first.height);
    }
    final play = Uri.tryParse(jsonString(item, ['video', 'playAddr']) ?? '');
    if (play == null || !play.hasScheme) return null;
    return (
      url: play,
      height: grabShortSide(
        jsonInt(item, ['video', 'width']),
        jsonInt(item, ['video', 'height']),
      ),
    );
  }

  static String _imageExt(Uri url) {
    final path = url.path.toLowerCase();
    if (path.contains('.webp') || path.contains('webp')) return 'webp';
    if (path.contains('.png')) return 'png';
    return 'jpg';
  }
}
