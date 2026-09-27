import 'dart:convert';
import 'dart:math';

import '../grab_models.dart';
import 'extractor.dart';

/// Reddit "installed app" client id (reddit.com/prefs/apps). When set, posts
/// are read through the official OAuth API, which works from networks where
/// Reddit challenges anonymous `.json` requests.
const String kRedditClientId = String.fromEnvironment('REDDIT_CLIENT_ID');

/// Reddit posts via the public `.json` view of a thread. Reddit-hosted video
/// is DASH/HLS with a separate audio track; we hand the HLS master to the
/// pipeline, which picks a quality and merges audio with FFmpeg.
class RedditExtractor extends MediaExtractor {
  const RedditExtractor();

  static final RegExp _comments = RegExp(r'/comments/([a-z0-9]+)');

  @override
  String get service => 'Reddit';

  @override
  bool canHandle(Uri uri) => hostIs(uri, const ['reddit.com', 'redd.it']);

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    var target = uri;
    final host = uri.host.toLowerCase();
    if (host == 'redd.it') {
      target = Uri.https('www.reddit.com', '/comments${uri.path}');
    } else if (!_comments.hasMatch(uri.path)) {
      // v.redd.it/<id> and /r/<sub>/s/<code> share links redirect to a post.
      target = await context.http.resolveRedirects(uri);
    }
    final id = _comments.firstMatch(target.path)?.group(1);
    if (id == null) {
      throw const GrabException('That Reddit link doesn\'t point to a post.');
    }
    final json = await _fetchThread(id, context);
    var post = jsonPath(json, [0, 'data', 'children', 0, 'data']);
    if (post is! Map) {
      throw const GrabException('Reddit didn\'t return that post.');
    }
    final crossposts = post['crosspost_parent_list'];
    if (crossposts is List &&
        crossposts.isNotEmpty &&
        crossposts.first is Map) {
      post = crossposts.first as Map;
    }
    final title = jsonString(post, ['title']) ?? 'Reddit post';
    final sub = jsonString(post, ['subreddit']) ?? 'reddit';
    final base = grabSafeFilename('reddit-$sub-$id');
    final items = <GrabItem>[];

    final video =
        jsonPath(post, ['secure_media', 'reddit_video']) ??
        jsonPath(post, ['media', 'reddit_video']) ??
        jsonPath(post, ['preview', 'reddit_video_preview']);
    final hls = Uri.tryParse(jsonString(video, ['hls_url']) ?? '');
    final fallback = Uri.tryParse(jsonString(video, ['fallback_url']) ?? '');
    if (video is Map && (hls != null || fallback != null)) {
      final isGif = video['is_gif'] == true;
      final seconds = jsonInt(video, ['duration']);
      final thumb = Uri.tryParse(
        jsonString(post, ['preview', 'images', 0, 'source', 'url']) ?? '',
      );
      items.add(
        GrabItem(
          kind: isGif ? GrabKind.gif : GrabKind.video,
          name: base,
          thumbnail: thumb,
          duration: seconds == null ? null : Duration(seconds: seconds),
          label: isGif ? 'GIF' : 'Video',
          inputs: [
            if (hls != null && hls.hasScheme)
              GrabStream(url: hls, track: GrabTrack.muxed, hls: true)
            else
              GrabStream(
                url: fallback!,
                track: GrabTrack.video,
                extension: 'mp4',
              ),
          ],
        ),
      );
    } else if (post['is_gallery'] == true) {
      final order = jsonPath(post, ['gallery_data', 'items']);
      final meta = post['media_metadata'];
      if (order is List && meta is Map) {
        for (final (index, entry) in order.indexed) {
          final mediaId = jsonString(entry, ['media_id']);
          final m = meta[mediaId];
          final gif = Uri.tryParse(
            jsonString(m, ['s', 'mp4']) ?? jsonString(m, ['s', 'gif']) ?? '',
          );
          final image = Uri.tryParse(jsonString(m, ['s', 'u']) ?? '');
          final url = (gif != null && gif.hasScheme) ? gif : image;
          if (url == null || !url.hasScheme) continue;
          final animated = url == gif;
          items.add(
            GrabItem(
              kind: animated ? GrabKind.gif : GrabKind.photo,
              name: '$base-${index + 1}',
              thumbnail: image,
              label: '${animated ? 'GIF' : 'Photo'} ${index + 1}',
              inputs: [
                GrabStream(
                  url: url,
                  track: animated ? GrabTrack.muxed : GrabTrack.image,
                  extension: extensionOf(url, fallback: 'jpg'),
                ),
              ],
            ),
          );
        }
      }
    } else {
      final dest = Uri.tryParse(
        jsonString(post, ['url_overridden_by_dest']) ??
            jsonString(post, ['url']) ??
            '',
      );
      final hint = jsonString(post, ['post_hint']);
      if (dest != null &&
          (hint == 'image' ||
              hostIs(dest, const ['i.redd.it', 'i.imgur.com']))) {
        final ext = extensionOf(dest, fallback: 'jpg');
        items.add(
          GrabItem(
            kind: ext == 'gif' ? GrabKind.gif : GrabKind.photo,
            name: base,
            thumbnail: dest,
            label: ext == 'gif' ? 'GIF' : 'Photo',
            inputs: [
              GrabStream(url: dest, track: GrabTrack.image, extension: ext),
            ],
          ),
        );
      }
    }
    if (items.isEmpty) {
      throw const GrabException(
        'That post has no Reddit-hosted media. Try the linked site instead.',
      );
    }
    if (context.options.mode == GrabMode.audio &&
        items.every((i) => i.kind != GrabKind.video)) {
      throw const GrabException('That post has no audio.');
    }
    return GrabMedia(
      service: service,
      title: title,
      author: 'r/$sub',
      items: items,
    );
  }

  static String? _token;
  static DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  static final String _deviceId = _randomDeviceId();

  Future<Object?> _fetchThread(String id, GrabContext context) async {
    if (kRedditClientId.isEmpty) {
      try {
        return await context.http.getJson(
          Uri.https('www.reddit.com', '/comments/$id.json', {'raw_json': '1'}),
        );
      } on GrabException catch (e) {
        // Anonymous JSON is answered with a bot challenge on some networks.
        throw GrabException(
          'Reddit blocked this request from your network. Try again on '
          'another connection.',
          detail: e.detail ?? e.message,
        );
      }
    }
    final token = await _appToken(context);
    return context.http.getJson(
      Uri.https('oauth.reddit.com', '/comments/$id', {'raw_json': '1'}),
      headers: {'Authorization': 'Bearer $token'},
    );
  }

  /// Application-only OAuth token (no user login) for installed apps.
  Future<String> _appToken(GrabContext context) async {
    final cached = _token;
    if (cached != null && DateTime.now().isBefore(_tokenExpiry)) {
      return cached;
    }
    final basic = base64Encode(utf8.encode('$kRedditClientId:'));
    final json = await context.http.postForm(
      Uri.https('www.reddit.com', '/api/v1/access_token'),
      {
        'grant_type': 'https://oauth.reddit.com/grants/installed_client',
        'device_id': _deviceId,
      },
      headers: {'Authorization': 'Basic $basic'},
    );
    final token = jsonString(json, ['access_token']);
    if (token == null) {
      throw const GrabException('Couldn\'t connect to Reddit right now.');
    }
    final seconds = jsonInt(json, ['expires_in']) ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: seconds - 60));
    return _token = token;
  }

  static String _randomDeviceId() {
    final random = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(24, (_) => chars[random.nextInt(chars.length)]).join();
  }
}
