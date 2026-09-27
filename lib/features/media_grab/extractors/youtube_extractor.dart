import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../grab_models.dart';
import 'extractor.dart';

/// YouTube via `youtube_explode_dart` (BSD-3): it keeps up with the player's
/// signature/n-parameter changes so we don't have to. High qualities are
/// video-only DASH streams; the pipeline merges them with an audio stream.
class YoutubeExtractor extends MediaExtractor {
  YoutubeExtractor();

  YoutubeExplode? _yt;

  YoutubeExplode get _client => _yt ??= YoutubeExplode();

  @override
  String get service => 'YouTube';

  static const _hosts = ['youtube.com', 'youtu.be', 'youtube-nocookie.com'];
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// Claims every YouTube URL so channel/playlist pages get a clear message
  /// instead of falling through to the generic page scraper.
  @override
  bool canHandle(Uri uri) => hostIs(uri, _hosts);

  @override
  bool isMediaLink(Uri uri) => videoIdFrom(uri) != null;

  /// Video id from watch, youtu.be, Shorts, embed, live and /v/ links.
  static String? videoIdFrom(Uri uri) {
    if (!hostIs(uri, _hosts)) return null;
    String? candidate;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri.host.toLowerCase().endsWith('youtu.be')) {
      candidate = segments.firstOrNull;
    } else if (uri.queryParameters['v'] != null) {
      candidate = uri.queryParameters['v'];
    } else if (segments.length >= 2 &&
        const ['shorts', 'embed', 'live', 'v', 'e'].contains(segments[0])) {
      candidate = segments[1];
    }
    if (candidate == null || !_idPattern.hasMatch(candidate)) return null;
    return candidate;
  }

  @override
  Future<GrabMedia> extract(Uri uri, GrabContext context) async {
    final rawId = videoIdFrom(uri);
    if (rawId == null) {
      throw GrabException(
        uri.queryParameters.containsKey('list')
            ? 'Playlists aren\'t supported yet. Paste a single video link.'
            : 'Paste a link to a single YouTube video.',
      );
    }
    final id = VideoId(rawId);
    final (video, manifest) = await _load(id);
    final options = context.options;
    final item = switch (options.mode) {
      GrabMode.audio => _audioItem(video, manifest),
      _ => _videoItem(video, manifest, options),
    };
    return GrabMedia(
      service: service,
      title: video.title,
      author: video.author,
      thumbnail: Uri.tryParse(video.thumbnails.highResUrl),
      items: [item],
    );
  }

  Future<(Video, StreamManifest)> _load(VideoId id) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final video = await _client.videos.get(id);
        // Check before asking for streams: live manifests fail confusingly.
        // 24/7 streams aren't always flagged live but report absurd
        // durations; upcoming premieres report zero.
        final duration = video.duration;
        if (video.isLive ||
            duration == Duration.zero ||
            (duration != null && duration.inHours > 24)) {
          throw const GrabException(
            'Live streams and upcoming premieres can\'t be downloaded.',
          );
        }
        return (video, await _manifest(id));
      } on VideoRequiresPurchaseException {
        throw const GrabException('That video requires a purchase.');
      } on VideoUnavailableException {
        throw const GrabException(
          'That video is unavailable, private or age-restricted.',
        );
      } on YoutubeExplodeException catch (e) {
        // YouTube briefly refuses sessions after heavy use; a fresh session
        // after a short pause usually goes through.
        if (attempt < 2) {
          close();
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        throw GrabException(
          e is RequestLimitExceededException
              ? 'YouTube is rate limiting. Try again soon.'
              : 'YouTube refused this video. Try again later.',
          detail: e.toString(),
        );
      }
    }
  }

  /// The default client is sometimes refused; the VR and TV clients are
  /// the usual fallbacks that still serve full-quality DASH streams.
  Future<StreamManifest> _manifest(VideoId id) async {
    try {
      return await _client.videos.streamsClient.getManifest(id);
    } on VideoUnavailableException {
      rethrow;
    } on YoutubeExplodeException {
      return _client.videos.streamsClient.getManifest(
        id,
        ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.tv],
      );
    }
  }

  GrabItem _audioItem(Video video, StreamManifest manifest) {
    final audio = _bestAudio(manifest, preferMp4: false);
    if (audio == null) {
      throw const GrabException('No audio stream found for that video.');
    }
    return GrabItem(
      kind: GrabKind.audio,
      name: _name(video),
      tags: _tags(video),
      duration: video.duration,
      thumbnail: Uri.tryParse(video.thumbnails.highResUrl),
      label: '${audio.bitrate.kiloBitsPerSecond.round()} kbps',
      inputs: [_stream(audio, GrabTrack.audio)],
    );
  }

  GrabItem _videoItem(
    Video video,
    StreamManifest manifest,
    GrabOptions options,
  ) {
    final chosen = pickVideo(manifest.videoOnly.toList(), options.maxHeight);
    final thumb = Uri.tryParse(video.thumbnails.highResUrl);
    if (chosen == null) {
      // Very old uploads can be muxed-only.
      final muxed = [...manifest.muxed]
        ..sort((a, b) => b.videoResolution.compareTo(a.videoResolution));
      if (muxed.isEmpty) {
        throw const GrabException('No downloadable stream for that video.');
      }
      return GrabItem(
        kind: GrabKind.video,
        name: _name(video),
        tags: _tags(video),
        duration: video.duration,
        thumbnail: thumb,
        label: muxed.first.qualityLabel,
        inputs: [_stream(muxed.first, GrabTrack.muxed)],
      );
    }
    final inputs = [_stream(chosen, GrabTrack.video)];
    if (options.mode != GrabMode.mute) {
      final audio = _bestAudio(
        manifest,
        preferMp4: chosen.container == StreamContainer.mp4,
      );
      if (audio != null) inputs.add(_stream(audio, GrabTrack.audio));
    }
    return GrabItem(
      kind: GrabKind.video,
      name: _name(video),
      tags: _tags(video),
      duration: video.duration,
      thumbnail: thumb,
      label: chosen.qualityLabel,
      inputs: inputs,
    );
  }

  /// Highest resolution that still gets H.264 (MP4) everywhere. Above it
  /// YouTube only offers VP9/AV1, which we deliver as VP9 in WebM.
  static const int mp4MaxHeight = 1080;

  static VideoOnlyStreamInfo? pickVideo(
    List<VideoOnlyStreamInfo> streams,
    int? maxHeight,
  ) {
    final index = pickVideoIndex([
      for (final s in streams)
        (
          height:
              grabShortSide(
                s.videoResolution.width,
                s.videoResolution.height,
              ) ??
              0,
          codec: s.videoCodec,
          bitrate: s.bitrate.bitsPerSecond,
        ),
    ], maxHeight);
    return index == null ? null : streams[index];
  }

  /// Selection rule, on plain data so it can be unit tested:
  /// * cap at [maxHeight] or below → the best **H.264** stream under the cap,
  ///   even if a VP9/AV1 stream is sharper, so the result is always MP4;
  /// * above [mp4MaxHeight] (or no cap) → the tallest stream, preferring
  ///   H.264, then VP9 (WebM), then AV1, so high qualities are consistently
  ///   WebM;
  /// * nothing under the cap → the smallest stream available.
  static int? pickVideoIndex(
    List<({int height, String codec, int bitrate})> streams,
    int? maxHeight,
  ) {
    if (streams.isEmpty) return null;
    bool isAvc(String codec) => codec.startsWith('avc1');
    int rank(String codec) => isAvc(codec)
        ? 0
        : (codec.startsWith('vp09') || codec.startsWith('vp9'))
        ? 1
        : 2;
    final indexed = streams.indexed.toList();
    final fitting = indexed
        .where((e) => maxHeight == null || e.$2.height <= maxHeight)
        .toList();
    if (fitting.isEmpty) {
      indexed.sort((a, b) => a.$2.height.compareTo(b.$2.height));
      return indexed.first.$1;
    }
    int byHeightThenBitrate(
      (int, ({int height, String codec, int bitrate})) a,
      (int, ({int height, String codec, int bitrate})) b,
    ) {
      final h = b.$2.height.compareTo(a.$2.height);
      return h != 0 ? h : b.$2.bitrate.compareTo(a.$2.bitrate);
    }

    if (maxHeight != null && maxHeight <= mp4MaxHeight) {
      final avc = fitting.where((e) => isAvc(e.$2.codec)).toList()
        ..sort(byHeightThenBitrate);
      if (avc.isNotEmpty) return avc.first.$1;
    }
    final top = fitting.map((e) => e.$2.height).reduce((a, b) => a > b ? a : b);
    final atTop = fitting.where((e) => e.$2.height == top).toList()
      ..sort((a, b) {
        final r = rank(a.$2.codec).compareTo(rank(b.$2.codec));
        return r != 0 ? r : b.$2.bitrate.compareTo(a.$2.bitrate);
      });
    return atTop.first.$1;
  }

  static AudioOnlyStreamInfo? _bestAudio(
    StreamManifest manifest, {
    required bool preferMp4,
  }) {
    // Skip auto-dubbed tracks; keep the original language.
    final original = manifest.audioOnly
        .where((s) => s.audioTrack == null || s.audioTrack!.audioIsDefault)
        .toList();
    final pool = original.isNotEmpty ? original : manifest.audioOnly.toList();
    if (pool.isEmpty) return null;
    final sameContainer = pool
        .where(
          (s) =>
              (s.container == StreamContainer.mp4) == preferMp4 ||
              !pool.any(
                (o) => (o.container == StreamContainer.mp4) == preferMp4,
              ),
        )
        .toList();
    sameContainer.sort(
      (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond),
    );
    return sameContainer.first;
  }

  GrabStream _stream(StreamInfo info, GrabTrack track) {
    final ext = switch (info.container) {
      StreamContainer.webM => track == GrabTrack.audio ? 'weba' : 'webm',
      _ => track == GrabTrack.audio ? 'm4a' : 'mp4',
    };
    return GrabStream(
      url: info.url,
      track: track,
      extension: ext,
      size: info.size.totalBytes,
      opener: () => _client.videos.streamsClient.get(info),
    );
  }

  static String _name(Video video) => grabSafeFilename(video.title);

  static Map<String, String> _tags(Video video) => {
    'title': video.title,
    if (video.author.isNotEmpty) 'artist': video.author,
  };

  void close() {
    _yt?.close();
    _yt = null;
  }
}
