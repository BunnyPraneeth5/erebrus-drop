import 'grab_http.dart';
import 'grab_models.dart';

class HlsVariant {
  const HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.width,
    this.height,
    this.codecs,
    this.audioGroup,
  });

  final Uri uri;
  final int bandwidth;
  final int? width;
  final int? height;
  final String? codecs;
  final String? audioGroup;

  int? get shortSide => grabShortSide(width, height);

  bool get isAvc => codecs == null || codecs!.contains('avc1');

  /// AAC (or unlisted) audio: AC-3/E-AC-3 tracks don't play on many devices.
  bool get isAac =>
      codecs == null ||
      codecs!.contains('mp4a') ||
      !RegExp(r'ac-3|ec-3|opus|flac').hasMatch(codecs!);
}

class HlsRendition {
  const HlsRendition({
    required this.uri,
    required this.groupId,
    this.isDefault = false,
    this.language,
  });

  final Uri uri;
  final String groupId;
  final bool isDefault;
  final String? language;
}

class HlsMaster {
  const HlsMaster({required this.variants, required this.audio});

  final List<HlsVariant> variants;
  final List<HlsRendition> audio;
}

/// The playlists FFmpeg should read for one output.
class HlsSelection {
  const HlsSelection({this.video, this.audio, this.height});

  /// Video (or combined A/V) media playlist; null for audio-only output.
  final Uri? video;

  /// Separate audio rendition, when the stream uses one.
  final Uri? audio;
  final int? height;
}

/// Minimal HLS master playlist reader (RFC 8216 §4.3.4): just enough to pick
/// a quality level and its matching audio rendition.
abstract final class Hls {
  static final RegExp _attr = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

  static Map<String, String> _attributes(String line) {
    final colon = line.indexOf(':');
    final out = <String, String>{};
    if (colon < 0) return out;
    for (final m in _attr.allMatches(line.substring(colon + 1))) {
      var value = m.group(2)!;
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      out[m.group(1)!] = value;
    }
    return out;
  }

  /// Parses [text]; returns null when it is a media (not master) playlist.
  static HlsMaster? parseMaster(String text, Uri base) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty || !lines.first.startsWith('#EXTM3U')) {
      throw const GrabException('The stream playlist is invalid.');
    }
    final variants = <HlsVariant>[];
    final audio = <HlsRendition>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final a = _attributes(line);
        String? next;
        for (var j = i + 1; j < lines.length; j++) {
          if (!lines[j].startsWith('#')) {
            next = lines[j];
            i = j;
            break;
          }
        }
        if (next == null) continue;
        int? w;
        int? h;
        final res = a['RESOLUTION']?.split('x');
        if (res != null && res.length == 2) {
          w = int.tryParse(res[0]);
          h = int.tryParse(res[1]);
        }
        variants.add(
          HlsVariant(
            uri: base.resolve(next),
            bandwidth:
                int.tryParse(a['AVERAGE-BANDWIDTH'] ?? a['BANDWIDTH'] ?? '') ??
                0,
            width: w,
            height: h,
            codecs: a['CODECS'],
            audioGroup: a['AUDIO'],
          ),
        );
      } else if (line.startsWith('#EXT-X-MEDIA')) {
        final a = _attributes(line);
        final uri = a['URI'];
        if (a['TYPE'] != 'AUDIO' || uri == null || uri.isEmpty) continue;
        audio.add(
          HlsRendition(
            uri: base.resolve(uri),
            groupId: a['GROUP-ID'] ?? '',
            isDefault: a['DEFAULT'] == 'YES',
            language: a['LANGUAGE'],
          ),
        );
      }
    }
    if (variants.isEmpty) return null;
    return HlsMaster(variants: variants, audio: audio);
  }

  static const _drmMessage =
      'This video is DRM-protected and can\'t be downloaded.';

  /// True for playlists whose segments need a DRM licence (FairPlay,
  /// Widevine, PlayReady — `SAMPLE-AES*`). Plain `AES-128` HLS is standard
  /// encryption with a public key URL and is fine.
  static bool isDrmProtected(String playlist, Uri uri) {
    if (uri.path.contains('/drm/')) return true;
    return RegExp(
      r'#EXT-X-(?:SESSION-)?KEY:[^\n]*METHOD=SAMPLE-AES',
    ).hasMatch(playlist);
  }

  /// Picks playlists for [options]; [playlist] may be master or media.
  /// Throws a [GrabException] for DRM-protected streams.
  static Future<HlsSelection> select(
    GrabHttp http,
    Uri playlist,
    GrabOptions options, {
    Map<String, String> headers = const {},
  }) async {
    final res = await http.get(playlist, headers: headers);
    if (!res.ok) {
      throw GrabException('The stream is unavailable (HTTP ${res.status}).');
    }
    if (isDrmProtected(res.body, res.uri)) {
      throw const GrabException(_drmMessage);
    }
    final master = parseMaster(res.body, res.uri);
    if (master == null) {
      return HlsSelection(video: res.uri);
    }
    final selection = pick(master, options);
    // Key tags usually live in the media playlists, so check the one FFmpeg
    // will read first.
    final first = selection.video ?? selection.audio;
    if (first != null) {
      final media = await http.get(first, headers: headers);
      if (isDrmProtected(media.body, media.uri)) {
        throw const GrabException(_drmMessage);
      }
    }
    return selection;
  }

  static HlsSelection pick(HlsMaster master, GrabOptions options) {
    HlsRendition? audioFor(String? group) {
      final inGroup = group == null
          ? master.audio
          : master.audio.where((r) => r.groupId == group).toList();
      if (inGroup.isEmpty) return null;
      return inGroup.firstWhere(
        (r) => r.isDefault,
        orElse: () => inGroup.first,
      );
    }

    if (options.mode == GrabMode.audio) {
      // Prefer the audio group that AAC variants use (AC-3 plays poorly).
      final aacGroup = master.variants
          .where(
            (v) => v.audioGroup != null && (v.codecs ?? '').contains('mp4a'),
          )
          .map((v) => v.audioGroup)
          .firstOrNull;
      final rendition = audioFor(aacGroup) ?? audioFor(null);
      if (rendition != null) return HlsSelection(audio: rendition.uri);
      // Muxed variants: the smallest one carries the same audio.
      final smallest = [...master.variants]
        ..sort((a, b) => a.bandwidth.compareTo(b.bandwidth));
      return HlsSelection(video: smallest.first.uri);
    }

    final variant = pickVariant(master.variants, options.maxHeight);
    final audio = options.mode == GrabMode.mute
        ? null
        : audioFor(variant.audioGroup);
    return HlsSelection(
      video: variant.uri,
      audio: audio?.uri,
      height: variant.shortSide,
    );
  }

  /// Highest-bandwidth variant within [maxHeight], preferring H.264 so the
  /// output plays everywhere; falls back to the smallest variant.
  static HlsVariant pickVariant(List<HlsVariant> variants, int? maxHeight) {
    bool fits(HlsVariant v) =>
        maxHeight == null || v.shortSide == null || v.shortSide! <= maxHeight;
    int byQuality(HlsVariant a, HlsVariant b) {
      final h = (b.shortSide ?? 0).compareTo(a.shortSide ?? 0);
      return h != 0 ? h : b.bandwidth.compareTo(a.bandwidth);
    }

    final fitting = variants.where(fits).toList()..sort(byQuality);
    final compatible = fitting.where((v) => v.isAvc && v.isAac).toList();
    if (compatible.isNotEmpty) return compatible.first;
    final avc = fitting.where((v) => v.isAvc).toList();
    if (avc.isNotEmpty) return avc.first;
    if (fitting.isNotEmpty) return fitting.first;
    final all = [...variants]
      ..sort((a, b) => (a.shortSide ?? 0).compareTo(b.shortSide ?? 0));
    return all.first;
  }
}
