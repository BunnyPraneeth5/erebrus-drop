import '../grab_models.dart';
import 'extractor.dart';

/// SoundCloud tracks through the same api-v2 the website uses. The public
/// `client_id` is read from the site's JS bundle and cached for the session.
class SoundcloudExtractor extends MediaExtractor {
  SoundcloudExtractor();

  String? _clientId;

  @override
  String get service => 'SoundCloud';

  @override
  bool canHandle(Uri uri) => hostIs(uri, const ['soundcloud.com']);

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    var target = uri;
    if (uri.host.toLowerCase().startsWith('on.')) {
      target = await context.http.resolveRedirects(uri);
    }
    final canonical = Uri.https('soundcloud.com', target.path);
    if (canonical.pathSegments.where((s) => s.isNotEmpty).length < 2) {
      throw const GrabException('Paste a link to a single SoundCloud track.');
    }
    if (canonical.pathSegments.contains('sets')) {
      throw const GrabException(
        'Playlists aren\'t supported yet. Paste a single track link.',
      );
    }
    final clientId = await _getClientId(context);
    final track = await context.http.getJson(
      Uri.https('api-v2.soundcloud.com', '/resolve', {
        'url': canonical.toString(),
        'client_id': clientId,
      }),
    );
    if (jsonString(track, ['kind']) != 'track') {
      throw const GrabException('That link isn\'t a SoundCloud track.');
    }
    if (jsonString(track, ['policy']) == 'BLOCK') {
      throw const GrabException('That track is blocked in this region.');
    }
    final transcodings = jsonPath(track, ['media', 'transcodings']);
    if (transcodings is! List || transcodings.isEmpty) {
      throw const GrabException('That track has no playable audio.');
    }
    Map? pick(bool Function(String protocol, String mime) test) {
      for (final t in transcodings) {
        if (t is! Map || t['snipped'] == true) continue;
        final protocol = jsonString(t, ['format', 'protocol']) ?? '';
        final mime = jsonString(t, ['format', 'mime_type']) ?? '';
        if (test(protocol, mime)) return t;
      }
      return null;
    }

    final chosen =
        pick((p, m) => p == 'progressive' && m.contains('mpeg')) ??
        pick((p, m) => p == 'hls' && m.contains('mp4')) ??
        pick((p, m) => p == 'hls' && m.contains('mpeg')) ??
        pick((p, m) => p == 'hls');
    if (chosen == null) {
      throw const GrabException(
        'Only a 30-second preview of that track is public.',
      );
    }
    final auth = jsonString(track, ['track_authorization']);
    final stream = await context.http.getJson(
      Uri.parse(jsonString(chosen, ['url'])!).replace(
        queryParameters: {'client_id': clientId, 'track_authorization': ?auth},
      ),
    );
    final url = Uri.tryParse(jsonString(stream, ['url']) ?? '');
    if (url == null) {
      throw const GrabException('SoundCloud didn\'t return a stream.');
    }
    final protocol = jsonString(chosen, ['format', 'protocol']);
    final mime = jsonString(chosen, ['format', 'mime_type']) ?? '';
    final title = jsonString(track, ['title']) ?? 'SoundCloud track';
    final artist =
        jsonString(track, ['publisher_metadata', 'artist']) ??
        jsonString(track, ['user', 'username']);
    final ms = jsonInt(track, ['duration']);
    final art = Uri.tryParse(
      (jsonString(track, ['artwork_url']) ?? '').replaceAll(
        '-large.',
        '-t500x500.',
      ),
    );
    return GrabMedia(
      service: service,
      title: title,
      author: artist,
      thumbnail: art,
      items: [
        GrabItem(
          kind: GrabKind.audio,
          name: grabSafeFilename(artist == null ? title : '$artist - $title'),
          thumbnail: art,
          duration: ms == null ? null : Duration(milliseconds: ms),
          label: mime.contains('mpeg') ? 'MP3' : 'Audio',
          tags: {'title': title, 'artist': ?artist},
          inputs: [
            GrabStream(
              url: url,
              track: GrabTrack.audio,
              hls: protocol == 'hls',
              extension: mime.contains('mpeg')
                  ? 'mp3'
                  : mime.contains('ogg')
                  ? 'opus'
                  : 'm4a',
            ),
          ],
        ),
      ],
    );
  }

  Future<String> _getClientId(GrabContext context) async {
    final cached = _clientId;
    if (cached != null) return cached;
    final page = await context.http.get(Uri.https('soundcloud.com', '/'));
    final scripts = RegExp(
      r'<script[^>]+src="(https://a-v2\.sndcdn\.com/assets/[^"]+\.js)"',
    ).allMatches(page.body).map((m) => m.group(1)!).toList();
    // The id lives in one of the last bundles; walk them newest-first.
    for (final src in scripts.reversed) {
      final js = await context.http.get(Uri.parse(src));
      final match = RegExp(
        r'client_id\s*[:=]\s*"([A-Za-z0-9]{32})"',
      ).firstMatch(js.body);
      if (match != null) return _clientId = match.group(1)!;
    }
    throw const GrabException('Couldn\'t connect to SoundCloud right now.');
  }
}
