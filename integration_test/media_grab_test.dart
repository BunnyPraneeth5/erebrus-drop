// On-device check of the Grab pipeline with the bundled FFmpeg. Hits the
// network, so it is not part of `flutter test`; run it on a device/simulator:
//   flutter test integration_test/media_grab_test.dart -d <device>
import 'dart:io';

import 'package:erebrus_drop/features/media_grab/grab_models.dart';
import 'package:erebrus_drop/features/media_grab/media_grab_service.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// `type:codec[@WxH]` per stream, plus `dur:<seconds>`.
Future<List<String>> _streams(File file) async {
  final session = await FFprobeKit.getMediaInformation(file.path);
  final info = session.getMediaInformation();
  final seconds = double.tryParse(info?.getDuration() ?? '')?.round();
  return [
    for (final s in info?.getStreams() ?? const [])
      '${s.getType()}:${s.getCodec()}'
          '${s.getWidth() == null ? '' : '@${s.getWidth()}x${s.getHeight()}'}',
    'dur:$seconds',
  ];
}

/// Fully decodes [file] (or its first [seconds]) and returns FFmpeg's error
/// output — empty means every frame decoded cleanly.
Future<String> _decodeErrors(File file, {int? seconds}) async {
  final session = await FFmpegKit.executeWithArguments([
    '-v',
    'error',
    if (seconds != null) ...['-t', '$seconds'],
    '-i',
    file.path,
    '-f',
    'null',
    '-',
  ]);
  final code = await session.getReturnCode();
  final logs = (await session.getAllLogsAsString() ?? '').trim();
  return ReturnCode.isSuccess(code) ? logs : 'exit ${code?.getValue()}: $logs';
}

Future<Map<String, String>> _info(File file) async {
  final session = await FFprobeKit.getMediaInformation(file.path);
  final info = session.getMediaInformation();
  // Ogg/Opus keeps tags on the audio stream rather than the container.
  final tags = <String, String>{
    for (final stream in info?.getStreams() ?? const [])
      for (final e in (stream.getTags() ?? const {}).entries)
        e.key.toLowerCase(): '${e.value}',
    for (final e in (info?.getTags() ?? const {}).entries)
      e.key.toLowerCase(): '${e.value}',
  };
  return {...tags, 'bitrate': info?.getBitrate() ?? ''};
}

/// Set `--dart-define=GRAB_HEAVY=false` to skip the 1440p/4K downloads
/// (~500 MB) for a quick smoke run.
const bool _heavy = bool.fromEnvironment('GRAB_HEAVY', defaultValue: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final service = MediaGrabService();
  tearDownAll(service.dispose);

  Future<(GrabResult, List<String>)> grab(
    String url,
    GrabOptions options,
  ) async {
    final GrabResult result;
    try {
      final media = await service.resolve(url, options);
      result = await service.fetch(media.items.first, options);
    } on GrabException catch (e) {
      // ignore: avoid_print
      print('GRAB-FAIL ${e.message}\n${e.detail}');
      rethrow;
    }
    final streams = await _streams(result.file);
    // ignore: avoid_print
    print('GRAB ${result.filename} ${await result.file.length()}B $streams');
    return (result, streams);
  }

  testWidgets('YouTube video+audio merge', (_) async {
    final (r, s) = await grab(
      'https://www.youtube.com/watch?v=jNQXAC9IVRw',
      const GrabOptions(),
    );
    expect(r.filename, endsWith('.mp4'));
    expect(s, containsAll(['video:h264@320x240', 'audio:aac']));
    await service.discard(r);
  });

  group('YouTube', () {
    const rick = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

    testWidgets('1080p H.264 + AAC merge', (_) async {
      final (r, s) = await grab(rick, const GrabOptions());
      expect(r.filename, endsWith('.mp4'));
      expect(s, containsAll(['video:h264@1920x1080', 'audio:aac']));
      expect(s.last, anyOf('dur:212', 'dur:213', 'dur:214'));
      await service.discard(r);
    });

    testWidgets('1440p VP9 + Opus merge into WebM', skip: !_heavy, (_) async {
      final (r, s) = await grab(
        rick,
        const GrabOptions(quality: GrabQuality.p1440),
      );
      expect(r.filename, endsWith('.webm'));
      expect(s, containsAll(['video:vp9@2560x1440', 'audio:opus']));
      await service.discard(r);
    });

    testWidgets('vertical Short is capped on its short side', (_) async {
      final (r, s) = await grab(
        'https://youtube.com/shorts/z6vcb6sBFl8?feature=share',
        const GrabOptions(quality: GrabQuality.p720),
      );
      expect(s, contains('video:h264@720x1280'));
      expect(s, contains('audio:aac'));
      await service.discard(r);
    });

    testWidgets('720p muted', (_) async {
      final (r, s) = await grab(
        'https://youtu.be/dQw4w9WgXcQ?si=test',
        const GrabOptions(mode: GrabMode.mute, quality: GrabQuality.p720),
      );
      expect(s, contains('video:h264@1280x720'));
      expect(s.where((e) => e.startsWith('audio:')), isEmpty);
      await service.discard(r);
    });

    testWidgets('audio as MP3', (_) async {
      final (r, s) = await grab(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
        const GrabOptions(mode: GrabMode.audio),
      );
      expect(r.filename, endsWith('.mp3'));
      expect(s.first, 'audio:mp3');
      expect(s.last, anyOf('dur:212', 'dur:213', 'dur:214'));
      await service.discard(r);
    });

    testWidgets('audio in original format (no re-encode)', (_) async {
      final (r, s) = await grab(
        rick,
        const GrabOptions(
          mode: GrabMode.audio,
          audioFormat: GrabAudioFormat.best,
        ),
      );
      expect(r.filename, endsWith('.opus'));
      expect(s.first, 'audio:opus');
      await service.discard(r);
    });

    testWidgets('cancel stops the download and cleans up', (_) async {
      final media = await service.resolve(rick, const GrabOptions());
      final cancel = GrabCancelToken();
      var cancelled = false;
      final future = service.fetch(
        media.items.first,
        const GrabOptions(),
        cancel: cancel,
        onProgress: (p) {
          if (!cancelled && (p.bytes ?? 0) > 2 * 1024 * 1024) {
            cancelled = true;
            cancel.cancel();
          }
        },
      );
      await expectLater(future, throwsA(isA<GrabCancelled>()));
      final temp = Directory(
        '${(await getTemporaryDirectory()).path}/erebrus-grab',
      );
      final leftovers = temp.existsSync()
          ? temp.listSync(recursive: true).whereType<File>().toList()
          : const <File>[];
      expect(leftovers, isEmpty);
    });
  });

  group('Audio', () {
    const rick = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

    Future<void> checkAudio(
      GrabResult r,
      List<String> s, {
      required String ext,
      required String codec,
      int? seconds,
      String? title,
      String? artist,
    }) async {
      final info = await _info(r.file);
      // ignore: avoid_print
      print('AUDIO ${r.filename} $info');
      expect(r.filename, endsWith('.$ext'));
      expect(s.first, 'audio:$codec');
      expect(s.where((e) => e.startsWith('video:')), isEmpty);
      if (seconds != null) {
        final dur = int.parse(s.last.substring(4));
        expect((dur - seconds).abs(), lessThanOrEqualTo(1));
      }
      if (title != null) expect(info['title'], contains(title));
      if (artist != null) expect(info['artist'], artist);
      expect(await _decodeErrors(r.file), isEmpty);
      await service.discard(r);
    }

    testWidgets('YouTube → MP3 (tagged, ~190 kbps VBR)', (_) async {
      final (r, s) = await grab(rick, const GrabOptions(mode: GrabMode.audio));
      final kbps = int.parse((await _info(r.file))['bitrate']!) ~/ 1000;
      expect(kbps, inInclusiveRange(128, 260));
      await checkAudio(
        r,
        s,
        ext: 'mp3',
        codec: 'mp3',
        seconds: 213,
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
      );
    });

    testWidgets('YouTube → original (Opus, tagged)', (_) async {
      final (r, s) = await grab(
        rick,
        const GrabOptions(
          mode: GrabMode.audio,
          audioFormat: GrabAudioFormat.best,
        ),
      );
      await checkAudio(
        r,
        s,
        ext: 'opus',
        codec: 'opus',
        seconds: 213,
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
      );
    });

    testWidgets('YouTube Short → MP3', (_) async {
      final (r, s) = await grab(
        'https://www.youtube.com/shorts/E2-iojBeNIM',
        const GrabOptions(mode: GrabMode.audio),
      );
      await checkAudio(r, s, ext: 'mp3', codec: 'mp3', seconds: 56);
    });

    testWidgets('SoundCloud → MP3 (tagged)', (_) async {
      final (r, s) = await grab(
        'https://soundcloud.com/forss/flickermood',
        const GrabOptions(mode: GrabMode.audio),
      );
      await checkAudio(
        r,
        s,
        ext: 'mp3',
        codec: 'mp3',
        seconds: 214,
        title: 'Flickermood',
        artist: 'Forss',
      );
    });

    testWidgets('audio pulled out of an X video → MP3', (_) async {
      final (r, s) = await grab(
        'https://x.com/NASA/status/2039534080585314704',
        const GrabOptions(mode: GrabMode.audio),
      );
      await checkAudio(r, s, ext: 'mp3', codec: 'mp3', seconds: 38);
    });

    testWidgets('HLS audio rendition → original AAC (.m4a)', (_) async {
      final (r, s) = await grab(
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
        'img_bipbop_adv_example_fmp4/master.m3u8',
        const GrabOptions(
          mode: GrabMode.audio,
          audioFormat: GrabAudioFormat.best,
        ),
      );
      await checkAudio(r, s, ext: 'm4a', codec: 'aac', seconds: 600);
    });

    testWidgets('direct MP3 link kept as-is', (_) async {
      final (r, s) = await grab(
        'https://www.w3schools.com/html/horse.mp3',
        const GrabOptions(
          mode: GrabMode.audio,
          audioFormat: GrabAudioFormat.best,
        ),
      );
      await checkAudio(r, s, ext: 'mp3', codec: 'mp3', seconds: 3);
    });
  });

  group('4K', () {
    const rick = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

    testWidgets('2160p download merges and decodes', skip: !_heavy, (_) async {
      final watch = Stopwatch()..start();
      final (r, s) = await grab(
        rick,
        const GrabOptions(quality: GrabQuality.p2160),
      );
      // ignore: avoid_print
      print('4K took ${watch.elapsed.inSeconds}s');
      expect(
        s.contains('video:vp9@3840x2160') && r.filename.endsWith('.webm'),
        isTrue,
        reason: '$s',
      );
      expect(s.any((e) => e.startsWith('audio:')), isTrue);
      expect(s.last, anyOf('dur:212', 'dur:213', 'dur:214'));
      expect(await _decodeErrors(r.file, seconds: 5), isEmpty);
      expect((await _info(r.file))['title'], contains('Never Gonna'));
      await service.discard(r);
    });

    testWidgets('1080p and below stay MP4 (H.264)', (_) async {
      for (final q in [GrabQuality.p1080, GrabQuality.p720, GrabQuality.p360]) {
        final media = await service.resolve(rick, GrabOptions(quality: q));
        final video = media.items.single.inputs.first;
        expect(video.extension, 'mp4', reason: q.label);
      }
    });

    testWidgets('Best picks the top resolution (2160p here)', (_) async {
      final media = await service.resolve(
        rick,
        const GrabOptions(quality: GrabQuality.max),
      );
      expect(media.items.single.label, '2160p');
      final capped = await service.resolve(
        rick,
        const GrabOptions(quality: GrabQuality.p1440),
      );
      expect(capped.items.single.label, '1440p');
    });
  });

  testWidgets('YouTube audio to MP3', (_) async {
    final (r, s) = await grab(
      'https://www.youtube.com/watch?v=jNQXAC9IVRw',
      const GrabOptions(mode: GrabMode.audio),
    );
    expect(r.filename, endsWith('.mp3'));
    expect(s.first, 'audio:mp3');
    await service.discard(r);
  });

  testWidgets('X video muted', (_) async {
    final (r, s) = await grab(
      'https://x.com/NASA/status/2039534080585314704',
      const GrabOptions(mode: GrabMode.mute, quality: GrabQuality.p480),
    );
    expect(s.where((e) => e.startsWith('audio:')), isEmpty);
    await service.discard(r);
  });

  testWidgets('HLS with separate audio rendition', (_) async {
    final (r, s) = await grab(
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
      'img_bipbop_adv_example_fmp4/master.m3u8',
      const GrabOptions(quality: GrabQuality.p480),
    );
    expect(r.filename, endsWith('.mp4'));
    expect(s.any((e) => e.startsWith('video:')), isTrue);
    expect(s.any((e) => e.startsWith('audio:')), isTrue);
    await service.discard(r);
  });

  testWidgets('DRM-protected HLS is refused with a clear message', (_) async {
    final media = await service.resolve(
      'https://vimeo.com/76979871',
      const GrabOptions(),
    );
    await expectLater(
      service.fetch(media.items.first, const GrabOptions()),
      throwsA(
        isA<GrabException>().having(
          (e) => e.message,
          'message',
          contains('DRM'),
        ),
      ),
    );
  });

  testWidgets('SoundCloud original format', (_) async {
    final (r, s) = await grab(
      'https://soundcloud.com/forss/flickermood',
      const GrabOptions(
        mode: GrabMode.audio,
        audioFormat: GrabAudioFormat.best,
      ),
    );
    expect(s.first, startsWith('audio:'));
    await service.discard(r);
  });
}
