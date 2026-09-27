import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'extractors/bluesky_extractor.dart';
import 'extractors/extractor.dart';
import 'extractors/generic_extractor.dart';
import 'extractors/reddit_extractor.dart';
import 'extractors/soundcloud_extractor.dart';
import 'extractors/tiktok_extractor.dart';
import 'extractors/twitter_extractor.dart';
import 'extractors/vimeo_extractor.dart';
import 'extractors/youtube_extractor.dart';
import 'ffmpeg_runner.dart';
import 'grab_http.dart';
import 'grab_models.dart';
import 'hls.dart';

/// A finished file waiting to be moved into the Drop folder / room.
class GrabResult {
  const GrabResult({
    required this.file,
    required this.filename,
    required this.mimeType,
  });

  final File file;
  final String filename;
  final String mimeType;
}

/// On-device media grabber: resolves a public link with a site extractor,
/// downloads the streams and finishes the file with the bundled FFmpeg
/// (merge video+audio, extract/convert audio, strip audio, remux HLS).
class MediaGrabService {
  MediaGrabService();

  final YoutubeExtractor _youtube = YoutubeExtractor();
  final SoundcloudExtractor _soundcloud = SoundcloudExtractor();

  late final List<MediaExtractor> _extractors = [
    _youtube,
    const TwitterExtractor(),
    const TiktokExtractor(),
    const RedditExtractor(),
    const BlueskyExtractor(),
    const VimeoExtractor(),
    _soundcloud,
    const GenericExtractor(),
  ];

  /// Sites with a dedicated extractor, for the UI.
  static const List<String> supportedServices = [
    'YouTube',
    'X',
    'TikTok',
    'Reddit',
    'Bluesky',
    'Vimeo',
    'SoundCloud',
    'Direct links',
  ];

  static const Duration _resolveTimeout = Duration(seconds: 60);

  /// A download that delivers no bytes for this long is treated as stalled.
  static const Duration _stallTimeout = Duration(seconds: 30);

  /// HTTP session of the last resolve; fetches reuse its cookies.
  GrabHttp? _http;

  /// Pulls the first http(s) URL out of pasted/shared text.
  static Uri? parseInput(String text) {
    final match = RegExp(
      r'https?://[^\s<>"]+',
      caseSensitive: false,
    ).firstMatch(text.trim());
    var raw = match?.group(0);
    if (raw == null) {
      final bare = text.trim();
      if (RegExp(
        r'^[a-z0-9.-]+\.[a-z]{2,}/\S*$',
        caseSensitive: false,
      ).hasMatch(bare)) {
        raw = 'https://$bare';
      }
    }
    if (raw == null) return null;
    raw = raw.replaceFirst(RegExp(r'[).,!?\]]+$'), '');
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }

  /// True when [text] is a link one of the site extractors recognizes, so
  /// a share-sheet link can be routed to the grabber.
  bool isKnownMediaLink(String text) {
    final trimmed = text.trim();
    // Only a lone link (no surrounding prose) is routed to Grab.
    if (!RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(trimmed)) {
      return false;
    }
    final uri = parseInput(trimmed);
    if (uri == null) return false;
    return _extractors
        .where((e) => e is! GenericExtractor)
        .any((e) => e.canHandle(uri) && e.isMediaLink(uri));
  }

  Future<GrabMedia> resolve(String input, GrabOptions options) async {
    final uri = parseInput(input);
    if (uri == null) {
      throw const GrabException('Paste a link that starts with https://');
    }
    _http?.close();
    final http = _http = GrabHttp();
    final context = GrabContext(http: http, options: options);
    final extractor = _extractors.firstWhere((e) => e.canHandle(uri));
    try {
      return await extractor.extract(uri, context).timeout(_resolveTimeout);
    } on TimeoutException {
      throw GrabException(
        '${extractor.service} took too long to respond. Try again.',
      );
    }
  }

  Future<GrabResult> fetch(
    GrabItem item,
    GrabOptions options, {
    void Function(GrabProgress progress)? onProgress,
    GrabCancelToken? cancel,
  }) async {
    final http = _http ??= GrabHttp();
    final work = await _workDir();
    try {
      return await _fetch(http, work, item, options, onProgress, cancel);
    } catch (_) {
      await _deleteQuietly(work);
      rethrow;
    }
  }

  Future<GrabResult> _fetch(
    GrabHttp http,
    Directory work,
    GrabItem item,
    GrabOptions options,
    void Function(GrabProgress progress)? onProgress,
    GrabCancelToken? cancel,
  ) async {
    final wantsAudio =
        options.mode == GrabMode.audio || item.kind == GrabKind.audio;
    final wantsMute = options.mode == GrabMode.mute && !wantsAudio;

    // 1. Expand HLS into concrete playlists; download everything else.
    final ffInputs = <_FfInput>[];
    final files = <GrabStream, File>{};
    final direct = item.inputs.where((s) => !s.hls).toList();
    final knownTotal = direct.every((s) => s.size != null)
        ? direct.fold<int>(0, (sum, s) => sum + s.size!)
        : null;
    var received = 0;
    for (final (index, input) in item.inputs.indexed) {
      cancel?.throwIfCancelled();
      if (input.hls) {
        final selection = await Hls.select(
          http,
          input.url,
          wantsAudio
              ? options.copyWith(mode: GrabMode.audio)
              : (wantsMute ? options.copyWith(mode: GrabMode.mute) : options),
          headers: input.headers,
        );
        for (final url in [selection.video, selection.audio]) {
          if (url != null) {
            ffInputs.add(_FfInput.remote(url, input.headers, input.extension));
          }
        }
        continue;
      }
      final target = File(
        '${work.path}${Platform.pathSeparator}in$index.${input.extension ?? 'bin'}',
      );
      await _download(http, input, target, cancel, (delta, total) {
        received += delta;
        final all = knownTotal ?? (direct.length == 1 ? total : null);
        onProgress?.call(
          GrabProgress(
            GrabStage.fetching,
            fraction: all == null || all <= 0
                ? null
                : (received / all).clamp(0.0, 1.0),
            bytes: received,
            total: all,
          ),
        );
      });
      files[input] = target;
      ffInputs.add(_FfInput.local(target, input.extension, input.track));
    }

    // 2. Decide whether FFmpeg is needed and what it should produce.
    var plan = _plan(item, ffInputs, options, wantsAudio, wantsMute);
    if (plan.args == null && wantsAudio && item.tags.isNotEmpty) {
      // Already the right format: a cheap stream copy just to add tags.
      plan = _Plan(plan.extension, ['-map', '0:a:0', '-vn', '-c:a', 'copy']);
    }
    final output = File(
      '${work.path}${Platform.pathSeparator}${item.name}.${plan.extension}',
    );
    if (plan.args == null) {
      await ffInputs.single.file!.rename(output.path);
    } else {
      onProgress?.call(const GrabProgress(GrabStage.processing));
      final args = <String>[
        for (final input in ffInputs) ...input.args(),
        ...plan.args!,
        for (final tag in item.tags.entries) ...[
          '-metadata',
          '${tag.key}=${tag.value}',
        ],
        '-y',
        output.path,
      ];
      await FfmpegRunner.run(
        args,
        duration: item.duration,
        cancel: cancel,
        onProgress: (f) =>
            onProgress?.call(GrabProgress(GrabStage.processing, fraction: f)),
      );
      for (final file in files.values) {
        await _deleteQuietly(file);
      }
    }
    if (!await output.exists() || await output.length() == 0) {
      throw const GrabException('The finished file was empty.');
    }
    return GrabResult(
      file: output,
      filename: '${item.name}.${plan.extension}',
      mimeType: mimeForExtension(plan.extension),
    );
  }

  _Plan _plan(
    GrabItem item,
    List<_FfInput> inputs,
    GrabOptions options,
    bool wantsAudio,
    bool wantsMute,
  ) {
    if (inputs.isEmpty) {
      throw const GrabException('Nothing to download for that item.');
    }
    final first = inputs.first;
    final single = inputs.length == 1 && first.file != null;

    if (item.kind == GrabKind.photo ||
        (item.kind == GrabKind.gif && first.track == GrabTrack.image)) {
      return _Plan(first.extension ?? 'jpg', null);
    }

    if (wantsAudio) {
      // Prefer a dedicated audio input when the item has one.
      final audioIndex = inputs.lastIndexWhere(
        (i) => i.track == GrabTrack.audio,
      );
      final index = audioIndex >= 0 ? audioIndex : inputs.length - 1;
      final source = inputs[index];
      final srcExt = source.extension ?? '';
      final map = ['-map', '$index:a:0', '-vn'];
      if (options.audioFormat == GrabAudioFormat.mp3) {
        if (single && srcExt == 'mp3') return const _Plan('mp3', null);
        return _Plan('mp3', [
          ...map,
          '-c:a',
          'libmp3lame',
          '-q:a',
          '2',
          '-id3v2_version',
          '3',
        ]);
      }
      final keepExt = switch (srcExt) {
        'weba' || 'webm' || 'opus' || 'ogg' => 'opus',
        'mp3' => 'mp3',
        _ => 'm4a',
      };
      if (single && srcExt == keepExt) return _Plan(keepExt, null);
      return _Plan(keepExt, [...map, '-c:a', 'copy']);
    }

    final video = inputs.firstWhere(
      (i) => i.track != GrabTrack.audio,
      orElse: () => first,
    );
    final webm = inputs.every(
      (i) => i.extension == 'webm' || i.extension == 'weba',
    );
    final ext = webm ? 'webm' : 'mp4';
    final faststart = webm ? const <String>[] : ['-movflags', '+faststart'];
    final videoIndex = inputs.indexOf(video);

    if (wantsMute) {
      if (single && video.track == GrabTrack.video) {
        return _Plan(video.extension ?? ext, null);
      }
      return _Plan(ext, [
        '-map',
        '$videoIndex:v:0',
        '-an',
        '-c:v',
        'copy',
        ...faststart,
      ]);
    }

    if (single && first.track != GrabTrack.audio) {
      return _Plan(first.extension ?? ext, null);
    }
    if (inputs.length == 1) {
      // HLS with muxed audio: remux as-is (best video + best audio).
      return _Plan(ext, ['-c', 'copy', ...faststart]);
    }
    final audioIndex = inputs.indexWhere((i) => !identical(i, video));
    return _Plan(ext, [
      '-map',
      '$videoIndex:v:0',
      '-map',
      '$audioIndex:a:0?',
      '-c',
      'copy',
      '-shortest',
      ...faststart,
    ]);
  }

  Future<void> _download(
    GrabHttp http,
    GrabStream stream,
    File target,
    GrabCancelToken? cancel,
    void Function(int delta, int? total) onBytes,
  ) async {
    final Stream<List<int>> bytes;
    int? total = stream.size;
    if (stream.opener != null) {
      bytes = stream.opener!();
    } else {
      final opened = await http.open(stream.url, headers: stream.headers);
      final status = opened.response.statusCode;
      if (status < 200 || status >= 300) {
        await opened.response.drain<void>().catchError((_) {});
        throw GrabException(switch (status) {
          401 || 403 => 'The site refused the download ($status).',
          404 || 410 => 'The media link expired. Try grabbing again.',
          429 => 'The site is rate limiting. Try again soon.',
          _ => 'Download failed (HTTP $status).',
        });
      }
      final length = opened.response.contentLength;
      if (length > 0) total = length;
      bytes = opened.response;
    }
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in bytes.timeout(_stallTimeout)) {
        if (cancel?.isCancelled ?? false) throw const GrabCancelled();
        sink.add(chunk);
        received += chunk.length;
        onBytes(chunk.length, total);
        // Some sources keep the stream open after the last byte; don't wait
        // for a close event that may never come.
        if (stream.size != null && received >= stream.size!) break;
      }
      await sink.flush();
      if (total != null && received < total) {
        throw const GrabException('The download ended early. Try again.');
      }
    } on TimeoutException {
      throw const GrabException('The download stalled. Try again.');
    } on SocketException catch (e) {
      throw GrabException('Download interrupted: ${e.message}');
    } on HttpException catch (e) {
      throw GrabException('Download interrupted: ${e.message}');
    } finally {
      await sink.close();
    }
  }

  Future<Directory> _workDir() async {
    final temp = await getTemporaryDirectory();
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}erebrus-grab'
      '${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}',
    );
    return dir.create(recursive: true);
  }

  /// Removes the temp folder of a result once it has been saved elsewhere.
  Future<void> discard(GrabResult result) => _deleteQuietly(result.file.parent);

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (_) {}
  }

  void dispose() {
    _http?.close();
    _http = null;
    _youtube.close();
  }
}

class _Plan {
  const _Plan(this.extension, this.args);

  final String extension;

  /// FFmpeg output arguments; null means the single input is already final.
  final List<String>? args;
}

class _FfInput {
  _FfInput.local(this.file, this.extension, this.track)
    : url = null,
      headers = const {};

  _FfInput.remote(this.url, this.headers, this.extension)
    : file = null,
      track = GrabTrack.muxed;

  final File? file;
  final Uri? url;
  final Map<String, String> headers;
  final String? extension;
  final GrabTrack track;

  List<String> args() {
    if (file != null) return ['-i', file!.path];
    final headerBlock = headers.entries
        .map((e) => '${e.key}: ${e.value}\r\n')
        .join();
    return [
      '-user_agent',
      kGrabUserAgent,
      if (headerBlock.isNotEmpty) ...['-headers', headerBlock],
      // Fail instead of hanging when a segment request stalls (µs).
      '-rw_timeout',
      '30000000',
      // Network protocols only: a hostile playlist must never be able to
      // reference file:// paths and splice local files into the output.
      '-protocol_whitelist',
      'http,https,tcp,tls,crypto',
      '-i',
      url.toString(),
    ];
  }
}

String mimeForExtension(String ext) => switch (ext.toLowerCase()) {
  'mp4' || 'm4v' => 'video/mp4',
  'webm' => 'video/webm',
  'mov' => 'video/quicktime',
  'mkv' => 'video/x-matroska',
  'mp3' => 'audio/mpeg',
  'm4a' => 'audio/mp4',
  'opus' || 'ogg' => 'audio/ogg',
  'wav' => 'audio/wav',
  'flac' => 'audio/flac',
  'jpg' || 'jpeg' => 'image/jpeg',
  'png' => 'image/png',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'avif' => 'image/avif',
  _ => 'application/octet-stream',
};
