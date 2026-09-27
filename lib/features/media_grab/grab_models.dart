import 'dart:async';

/// What the user wants out of a link.
enum GrabMode {
  /// Video with audio (or the photo/gif as-is).
  auto('Video'),

  /// Audio track only.
  audio('Audio'),

  /// Video without its audio track.
  mute('Muted');

  const GrabMode(this.label);

  final String label;
}

enum GrabAudioFormat {
  /// Re-encode to MP3 (widest compatibility).
  mp3('MP3'),

  /// Keep the source codec (AAC → .m4a, Opus → .opus) without re-encoding.
  best('Original');

  const GrabAudioFormat(this.label);

  final String label;
}

/// Preferred maximum video quality, measured on the short side (so a
/// 1080×1920 vertical clip counts as 1080p).
enum GrabQuality {
  max('Best', null),
  p2160('4K', 2160),
  p1440('1440p', 1440),
  p1080('1080p', 1080),
  p720('720p', 720),
  p480('480p', 480),
  p360('360p', 360);

  const GrabQuality(this.label, this.maxHeight);

  final String label;
  final int? maxHeight;

  /// Above 1080p YouTube only has VP9/AV1, which Grab saves as WebM.
  bool get savesAsWebm => maxHeight == null || maxHeight! > 1080;

  /// Chip text: `4K · WebM` for the qualities that can't be MP4.
  String get chipLabel =>
      maxHeight != null && maxHeight! > 1080 ? '$label · WebM' : label;
}

class GrabOptions {
  const GrabOptions({
    this.mode = GrabMode.auto,
    this.quality = GrabQuality.p1080,
    this.audioFormat = GrabAudioFormat.mp3,
  });

  final GrabMode mode;
  final GrabQuality quality;
  final GrabAudioFormat audioFormat;

  int? get maxHeight => quality.maxHeight;

  GrabOptions copyWith({
    GrabMode? mode,
    GrabQuality? quality,
    GrabAudioFormat? audioFormat,
  }) => GrabOptions(
    mode: mode ?? this.mode,
    quality: quality ?? this.quality,
    audioFormat: audioFormat ?? this.audioFormat,
  );
}

enum GrabKind { video, audio, photo, gif }

enum GrabTrack {
  /// Video and audio in one file.
  muxed,

  /// Video only (needs an audio track merged in).
  video,

  /// Audio only.
  audio,

  /// A still image or animated image file.
  image,
}

/// One input the pipeline has to fetch.
class GrabStream {
  const GrabStream({
    required this.url,
    required this.track,
    this.extension,
    this.headers = const {},
    this.hls = false,
    this.size,
    this.opener,
  });

  final Uri url;
  final GrabTrack track;

  /// File extension without the dot (`mp4`, `webm`, `m4a`, `jpg`…), when known.
  final String? extension;
  final Map<String, String> headers;

  /// When true, [url] is an HLS media playlist that FFmpeg reads directly.
  final bool hls;

  /// Total bytes, when the source reports it up front.
  final int? size;

  /// Custom byte source (YouTube needs chunked range requests).
  final Stream<List<int>> Function()? opener;
}

/// One downloadable file (a picker entry in multi-media posts).
class GrabItem {
  const GrabItem({
    required this.kind,
    required this.name,
    required this.inputs,
    this.thumbnail,
    this.duration,
    this.label,
    this.tags = const {},
  });

  final GrabKind kind;

  /// Base filename without extension.
  final String name;

  /// One input, or a `[video, audio]` pair that gets merged.
  final List<GrabStream> inputs;
  final Uri? thumbnail;
  final Duration? duration;

  /// Short UI hint, such as `1080p` or `Photo 2`.
  final String? label;

  /// Container metadata (`title`, `artist`…) written when FFmpeg runs, so
  /// audio files show up properly in music apps.
  final Map<String, String> tags;
}

class GrabMedia {
  const GrabMedia({
    required this.service,
    required this.title,
    required this.items,
    this.author,
    this.thumbnail,
  });

  final String service;
  final String title;
  final String? author;
  final Uri? thumbnail;
  final List<GrabItem> items;
}

enum GrabStage { fetching, processing, saving }

class GrabProgress {
  const GrabProgress(this.stage, {this.fraction, this.bytes, this.total});

  final GrabStage stage;

  /// 0..1 when known; null means indeterminate.
  final double? fraction;
  final int? bytes;
  final int? total;
}

class GrabException implements Exception {
  const GrabException(this.message, {this.detail});

  final String message;

  /// Diagnostic tail (HTTP body, FFmpeg log) — never shown verbatim in UI.
  final String? detail;

  @override
  String toString() => message;
}

class GrabCancelled implements Exception {
  const GrabCancelled();

  @override
  String toString() => 'Cancelled';
}

class GrabCancelToken {
  bool _cancelled = false;
  final List<FutureOr<void> Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      unawaited(Future.sync(listener).catchError((_) {}));
    }
  }

  /// Registers [listener]; returns a callback that unregisters it.
  void Function() onCancel(FutureOr<void> Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const GrabCancelled();
  }
}

/// Removes characters that are illegal in filenames on any platform and
/// keeps names to a sane length.
String grabSafeFilename(String name, {int maxLength = 120}) {
  var safe = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[.\s-]+|[.\s]+$'), '')
      .trim();
  if (safe.isEmpty) safe = 'download';
  if (safe.length > maxLength) safe = safe.substring(0, maxLength).trim();
  return safe;
}

/// Short-side pixel height used for quality comparisons.
int? grabShortSide(int? width, int? height) {
  if (width == null || width <= 0) return height;
  if (height == null || height <= 0) return width;
  return width < height ? width : height;
}
