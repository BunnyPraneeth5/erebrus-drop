import '../grab_models.dart';
import 'extractor.dart';

/// Bluesky posts via the public AppView XRPC API (no auth needed for public
/// posts). Video embeds are HLS; images are direct CDN files.
class BlueskyExtractor extends MediaExtractor {
  const BlueskyExtractor();

  static final RegExp _post = RegExp(r'^/profile/([^/]+)/post/([a-z0-9]+)');

  @override
  String get service => 'Bluesky';

  @override
  bool canHandle(Uri uri) =>
      hostIs(uri, const ['bsky.app']) && _post.hasMatch(uri.path);

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    final match = _post.firstMatch(uri.path)!;
    final actor = match.group(1)!;
    final rkey = match.group(2)!;
    final json = await context.http.getJson(
      Uri.https('public.api.bsky.app', '/xrpc/app.bsky.feed.getPostThread', {
        'uri': 'at://$actor/app.bsky.feed.post/$rkey',
        'depth': '0',
        'parentHeight': '0',
      }),
    );
    final post = jsonPath(json, ['thread', 'post']);
    if (post is! Map) {
      throw const GrabException('That post is unavailable.');
    }
    final handle = jsonString(post, ['author', 'handle']) ?? actor;
    final base = grabSafeFilename('bsky-$handle-$rkey');
    var embed = post['embed'];
    if (jsonString(embed, [r'$type']) ==
        'app.bsky.embed.recordWithMedia#view') {
      embed = jsonPath(embed, ['media']);
    }
    final type = jsonString(embed, [r'$type']);
    final items = <GrabItem>[];
    if (type == 'app.bsky.embed.video#view') {
      final playlist = Uri.tryParse(jsonString(embed, ['playlist']) ?? '');
      if (playlist != null) {
        items.add(
          GrabItem(
            kind: GrabKind.video,
            name: base,
            thumbnail: Uri.tryParse(jsonString(embed, ['thumbnail']) ?? ''),
            label: 'Video',
            inputs: [
              GrabStream(url: playlist, track: GrabTrack.muxed, hls: true),
            ],
          ),
        );
      }
    } else if (type == 'app.bsky.embed.images#view' &&
        context.options.mode != GrabMode.audio) {
      final images = jsonPath(embed, ['images']);
      if (images is List) {
        for (final (index, image) in images.indexed) {
          final full = Uri.tryParse(jsonString(image, ['fullsize']) ?? '');
          if (full == null) continue;
          items.add(
            GrabItem(
              kind: GrabKind.photo,
              name: images.length > 1 ? '$base-${index + 1}' : base,
              thumbnail: Uri.tryParse(jsonString(image, ['thumb']) ?? ''),
              label: 'Photo ${index + 1}',
              inputs: [
                GrabStream(
                  url: full,
                  track: GrabTrack.image,
                  // CDN URLs end in `@jpeg`, not a file extension.
                  extension: full.path.endsWith('@png') ? 'png' : 'jpg',
                ),
              ],
            ),
          );
        }
      }
    } else if (type == 'app.bsky.embed.external#view') {
      final external = Uri.tryParse(
        jsonString(embed, ['external', 'uri']) ?? '',
      );
      if (external != null && hostIs(external, const ['media.tenor.com'])) {
        items.add(
          GrabItem(
            kind: GrabKind.gif,
            name: base,
            thumbnail: external,
            label: 'GIF',
            inputs: [
              GrabStream(
                url: external,
                track: GrabTrack.image,
                extension: 'gif',
              ),
            ],
          ),
        );
      }
    }
    if (items.isEmpty) {
      throw const GrabException('That post has no photos or videos.');
    }
    final text = jsonString(post, ['record', 'text']);
    return GrabMedia(
      service: service,
      title: text == null || text.isEmpty
          ? 'Post by @$handle'
          : (text.length > 80 ? '${text.substring(0, 80)}…' : text),
      author: '@$handle',
      items: items,
    );
  }
}
