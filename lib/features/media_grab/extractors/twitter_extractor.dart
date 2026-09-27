import 'dart:math' as math;
import 'dart:typed_data';

import '../grab_models.dart';
import 'extractor.dart';

/// X / Twitter posts through the public embed ("syndication") endpoint that
/// powers embedded tweets. Videos come as ready MP4 variants, so no merging.
class TwitterExtractor extends MediaExtractor {
  const TwitterExtractor();

  static final RegExp _status = RegExp(
    r'/(?:[^/]+|i(?:/web)?)/status(?:es)?/(\d+)(?:/(photo|video)/(\d))?',
  );

  @override
  String get service => 'X';

  @override
  bool canHandle(Uri uri) =>
      hostIs(uri, const [
        'twitter.com',
        'x.com',
        'fxtwitter.com',
        'vxtwitter.com',
        'fixupx.com',
        'fixvx.com',
      ]) &&
      _status.hasMatch(uri.path);

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    final match = _status.firstMatch(uri.path)!;
    final id = match.group(1)!;
    final only = int.tryParse(match.group(3) ?? '');
    final json = await context.http.getJson(
      Uri.https('cdn.syndication.twimg.com', '/tweet-result', {
        'id': id,
        'lang': 'en',
        'token': syndicationToken(id),
      }),
    );
    if (json is! Map || json.isEmpty) {
      throw const GrabException('That post is private or was removed.');
    }
    if (json['__typename'] == 'TweetTombstone') {
      throw const GrabException('That post is unavailable.');
    }
    var media = json['mediaDetails'];
    // A post quoting a video: fall back to the quoted post's media.
    if ((media is! List || media.isEmpty) && json['quoted_tweet'] is Map) {
      media = (json['quoted_tweet'] as Map)['mediaDetails'];
    }
    if (media is! List || media.isEmpty) {
      throw const GrabException('That post has no photos or videos.');
    }
    final author = jsonString(json, ['user', 'screen_name']);
    final base = grabSafeFilename('x-${author ?? 'post'}-$id');
    final items = <GrabItem>[];
    for (final (index, entry) in media.indexed) {
      if (only != null && index + 1 != only) continue;
      final item = _item(entry, base, index, media.length > 1, context);
      if (item != null) items.add(item);
    }
    if (items.isEmpty) {
      throw const GrabException('Nothing downloadable in that post.');
    }
    final text = jsonString(json, ['text']) ?? 'Post by @${author ?? 'user'}';
    return GrabMedia(
      service: service,
      title: text.length > 80 ? '${text.substring(0, 80)}…' : text,
      author: author == null ? null : '@$author',
      items: items,
    );
  }

  GrabItem? _item(
    Object? entry,
    String base,
    int index,
    bool numbered,
    GrabContext context,
  ) {
    final type = jsonString(entry, ['type']);
    final name = numbered ? '$base-${index + 1}' : base;
    final thumb = Uri.tryParse(jsonString(entry, ['media_url_https']) ?? '');
    if (type == 'photo') {
      if (thumb == null || context.options.mode == GrabMode.audio) return null;
      return GrabItem(
        kind: GrabKind.photo,
        name: name,
        thumbnail: thumb,
        label: 'Photo ${index + 1}',
        inputs: [
          GrabStream(
            url: thumb.replace(queryParameters: {'name': 'orig'}),
            track: GrabTrack.image,
            extension: extensionOf(thumb, fallback: 'jpg'),
          ),
        ],
      );
    }
    final variants = jsonPath(entry, ['video_info', 'variants']);
    if (variants is! List) return null;
    final mp4s = <({Uri url, int bitrate, int? height})>[];
    for (final v in variants) {
      if (jsonString(v, ['content_type']) != 'video/mp4') continue;
      final url = Uri.tryParse(jsonString(v, ['url']) ?? '');
      if (url == null) continue;
      final size = RegExp(r'/(\d+)x(\d+)/').firstMatch(url.path);
      mp4s.add((
        url: url,
        bitrate: jsonInt(v, ['bitrate']) ?? 0,
        height: size == null
            ? null
            : grabShortSide(
                int.parse(size.group(1)!),
                int.parse(size.group(2)!),
              ),
      ));
    }
    if (mp4s.isEmpty) return null;
    final max = context.options.maxHeight;
    final fitting = mp4s
        .where((v) => max == null || v.height == null || v.height! <= max)
        .toList();
    final pool = fitting.isNotEmpty ? fitting : mp4s;
    pool.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final best = pool.first;
    final gif = type == 'animated_gif';
    final durationMs = jsonInt(entry, ['video_info', 'duration_millis']);
    return GrabItem(
      kind: gif ? GrabKind.gif : GrabKind.video,
      name: name,
      thumbnail: thumb,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      label: gif ? 'GIF' : (best.height == null ? 'Video' : '${best.height}p'),
      inputs: [
        GrabStream(url: best.url, track: GrabTrack.muxed, extension: 'mp4'),
      ],
    );
  }

  /// Token the embed endpoint expects: `(id / 1e15 * π)` written in base 36
  /// the way JavaScript's `Number.prototype.toString(36)` does, with every
  /// `0` and `.` removed.
  static String syndicationToken(String id) {
    final value = (double.parse(id) / 1e15) * math.pi;
    return jsDoubleToRadix(value, 36).replaceAll(RegExp(r'(0+|\.)'), '');
  }

  /// Port of the ECMAScript `Number::toString(radix)` digit generation for
  /// positive finite doubles: emit fraction digits until the remaining
  /// fraction is within half an ULP, rounding the last digit.
  static String jsDoubleToRadix(double value, int radix) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    var integer = value.floorToDouble();
    var fraction = value - integer;
    var delta = 0.5 * (_nextUp(value) - value);
    final minDelta = _nextUp(0.0);
    if (delta < minDelta) delta = minDelta;
    final digits = <int>[];
    if (fraction >= delta) {
      do {
        fraction *= radix;
        delta *= radix;
        final digit = fraction.floor();
        digits.add(digit);
        fraction -= digit;
        if (fraction > 0.5 || (fraction == 0.5 && digit.isOdd)) {
          if (fraction + delta > 1) {
            // Round up, carrying into earlier digits (and the integer).
            while (true) {
              if (digits.isEmpty) {
                integer += 1;
                break;
              }
              final last = digits.removeLast() + 1;
              if (last < radix) {
                digits.add(last);
                break;
              }
            }
            break;
          }
        }
      } while (fraction >= delta);
    }
    var intPart = BigInt.from(integer);
    final big = BigInt.from(radix);
    final intDigits = StringBuffer();
    if (intPart == BigInt.zero) {
      intDigits.write('0');
    } else {
      final rev = <String>[];
      while (intPart > BigInt.zero) {
        rev.add(chars[(intPart % big).toInt()]);
        intPart = intPart ~/ big;
      }
      intDigits.writeAll(rev.reversed);
    }
    if (digits.isEmpty) return intDigits.toString();
    return '$intDigits.${digits.map((d) => chars[d]).join()}';
  }

  static double _nextUp(double value) {
    final data = ByteData(8)..setFloat64(0, value);
    final bits = data.getInt64(0);
    data.setInt64(0, value >= 0 ? bits + 1 : bits - 1);
    return data.getFloat64(0);
  }
}
