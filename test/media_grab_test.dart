import 'package:erebrus_drop/features/media_grab/extractors/bluesky_extractor.dart';
import 'package:erebrus_drop/features/media_grab/extractors/reddit_extractor.dart';
import 'package:erebrus_drop/features/media_grab/extractors/tiktok_extractor.dart';
import 'package:erebrus_drop/features/media_grab/extractors/twitter_extractor.dart';
import 'package:erebrus_drop/features/media_grab/extractors/vimeo_extractor.dart';
import 'package:erebrus_drop/features/media_grab/extractors/youtube_extractor.dart';
import 'package:erebrus_drop/features/media_grab/grab_http.dart';
import 'package:erebrus_drop/features/media_grab/grab_models.dart';
import 'package:erebrus_drop/features/media_grab/hls.dart';
import 'package:erebrus_drop/features/media_grab/media_grab_panel.dart';
import 'package:erebrus_drop/features/media_grab/media_grab_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('link parsing', () {
    test('pulls the URL out of shared text', () {
      expect(
        MediaGrabService.parseInput(
          'Watch this! https://youtu.be/dQw4w9WgXcQ?si=abc).',
        ).toString(),
        'https://youtu.be/dQw4w9WgXcQ?si=abc',
      );
    });

    test('accepts a bare domain link', () {
      expect(
        MediaGrabService.parseInput('x.com/NASA/status/1').toString(),
        'https://x.com/NASA/status/1',
      );
    });

    test('rejects plain text', () {
      expect(MediaGrabService.parseInput('hello there'), isNull);
    });

    test('recognizes only bare links to known sites', () {
      final service = MediaGrabService();
      expect(service.isKnownMediaLink('https://youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(
        service.isKnownMediaLink(
          'https://x.com/NASA/status/2039534080585314704',
        ),
        isTrue,
      );
      expect(service.isKnownMediaLink('https://example.com/page'), isFalse);
      expect(service.isKnownMediaLink('HTTPS://youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(
        service.isKnownMediaLink('  https://youtu.be/dQw4w9WgXcQ\n'),
        isTrue,
      );
      expect(
        service.isKnownMediaLink('look https://youtu.be/dQw4w9WgXcQ'),
        isFalse,
      );
    });
  });

  group('extractor routing', () {
    test('matches site URL shapes', () {
      expect(
        YoutubeExtractor().isMediaLink(
          Uri.parse('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        ),
        isTrue,
      );
      // The site itself is claimed (for a clear error) but isn't media.
      expect(
        YoutubeExtractor().canHandle(Uri.parse('https://www.youtube.com/')),
        isTrue,
      );
      expect(
        YoutubeExtractor().isMediaLink(
          Uri.parse('https://www.youtube.com/@NASA'),
        ),
        isFalse,
      );
      expect(
        const TwitterExtractor().canHandle(
          Uri.parse('https://twitter.com/i/web/status/123'),
        ),
        isTrue,
      );
      expect(
        const TiktokExtractor().canHandle(
          Uri.parse('https://vm.tiktok.com/ZMabc/'),
        ),
        isTrue,
      );
      expect(
        const RedditExtractor().canHandle(Uri.parse('https://redd.it/abc12')),
        isTrue,
      );
      expect(
        const BlueskyExtractor().canHandle(
          Uri.parse('https://bsky.app/profile/a.bsky.social/post/3kxyz'),
        ),
        isTrue,
      );
      expect(
        const VimeoExtractor().canHandle(
          Uri.parse('https://vimeo.com/channels/staffpicks/76979871'),
        ),
        isTrue,
      );
    });
  });

  test('YouTube video ids from every link shape', () {
    const id = 'dQw4w9WgXcQ';
    for (final url in [
      'https://www.youtube.com/watch?v=$id',
      'https://youtube.com/watch?feature=share&v=$id&t=42s',
      'https://m.youtube.com/watch?v=$id',
      'https://music.youtube.com/watch?v=$id&list=RDAMVM$id',
      'https://youtu.be/$id?si=abc',
      'https://www.youtube.com/shorts/$id',
      'https://youtube.com/shorts/$id?feature=share',
      'https://www.youtube.com/embed/$id?start=10',
      'https://www.youtube-nocookie.com/embed/$id',
      'https://www.youtube.com/live/$id',
    ]) {
      expect(YoutubeExtractor.videoIdFrom(Uri.parse(url)), id, reason: url);
    }
    for (final url in [
      'https://www.youtube.com/@NASA',
      'https://www.youtube.com/playlist?list=PL123',
      'https://www.youtube.com/watch?v=short',
      'https://example.com/watch?v=$id',
    ]) {
      expect(YoutubeExtractor.videoIdFrom(Uri.parse(url)), isNull, reason: url);
    }
  });

  group('YouTube quality → container', () {
    // Typical YouTube ladder for a 4K upload.
    const ladder = [
      (height: 2160, codec: 'av01.0.12M.08', bitrate: 18000000),
      (height: 2160, codec: 'vp09.00.51.08', bitrate: 17000000),
      (height: 1440, codec: 'vp09.00.50.08', bitrate: 9000000),
      (height: 1080, codec: 'vp09.00.41.08', bitrate: 4000000),
      (height: 1080, codec: 'avc1.640028', bitrate: 3000000),
      (height: 720, codec: 'avc1.4d401f', bitrate: 1500000),
    ];
    String pick(List<({int height, String codec, int bitrate})> l, int? max) {
      final s = l[YoutubeExtractor.pickVideoIndex(l, max)!];
      return '${s.height} ${s.codec.substring(0, 4)}';
    }

    test('1080p and below always pick H.264 (MP4)', () {
      expect(pick(ladder, 1080), '1080 avc1');
      expect(pick(ladder, 720), '720 avc1');
    });

    test('H.264 wins even when only VP9 exists at the cap', () {
      final noAvc1080 = ladder
          .where((s) => !(s.height == 1080 && s.codec.startsWith('avc1')))
          .toList();
      expect(pick(noAvc1080, 1080), '720 avc1');
    });

    test('above 1080p prefers VP9 (WebM) over AV1', () {
      expect(pick(ladder, 2160), '2160 vp09');
      expect(pick(ladder, null), '2160 vp09');
      expect(pick(ladder, 1440), '1440 vp09');
    });

    test('falls back to the smallest stream when nothing fits', () {
      expect(pick(ladder, 144), '720 avc1');
    });

    test('chip labels flag WebM qualities', () {
      expect(GrabQuality.p2160.chipLabel, '4K · WebM');
      expect(GrabQuality.p1440.chipLabel, '1440p · WebM');
      expect(GrabQuality.p1080.chipLabel, '1080p');
      expect(GrabQuality.max.chipLabel, 'Best');
      expect(GrabQuality.max.savesAsWebm, isTrue);
      expect(GrabQuality.p1080.savesAsWebm, isFalse);
      expect(const GrabOptions().quality, GrabQuality.p1080);
    });
  });

  testWidgets('Grab panel shows WebM chips and note only above 1080p', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaGrabPanel(
              service: MediaGrabService(),
              onSave: (_) async => null,
              ensureDestination: () async => false,
              destinationLabel: 'your Drop folder',
            ),
          ),
        ),
      ),
    );
    expect(find.text('4K · WebM'), findsOneWidget);
    expect(find.text('1440p · WebM'), findsOneWidget);
    expect(find.textContaining('saved as WebM'), findsNothing);

    await tester.tap(find.text('Best'));
    await tester.pump();
    expect(find.textContaining('saved as WebM'), findsOneWidget);

    await tester.ensureVisible(find.text('720p'));
    await tester.tap(find.text('720p'));
    await tester.pump();
    expect(find.textContaining('saved as WebM'), findsNothing);
  });

  group('X syndication token', () {
    // Expected values produced by
    // ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
    test('matches JavaScript Number.toString(36)', () {
      expect(TwitterExtractor.syndicationToken('20'), '6dq1a2xwd93');
      expect(
        TwitterExtractor.syndicationToken('1843301566236319854'),
        '4guwhug879b',
      );
      expect(
        TwitterExtractor.syndicationToken('1577730467436138524'),
        '3tol417ti8o',
      );
    });

    test('integer and fraction digits', () {
      expect(TwitterExtractor.jsDoubleToRadix(255, 16), 'ff');
      expect(TwitterExtractor.jsDoubleToRadix(0.5, 2), '0.1');
      expect(TwitterExtractor.jsDoubleToRadix(35.5, 36), 'z.i');
    });
  });

  group('HLS', () {
    const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
v360.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud"
v720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="hvc1.1.6.L93,mp4a.40.2",AUDIO="aud"
v720-hevc.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
v1080.m3u8
''';
    final base = Uri.parse('https://cdn.example.com/v/master.m3u8');

    test('parses variants and audio renditions', () {
      final parsed = Hls.parseMaster(master, base)!;
      expect(parsed.variants, hasLength(4));
      expect(
        parsed.audio.single.uri.toString(),
        'https://cdn.example.com/v/audio/en.m3u8',
      );
    });

    test('respects the quality cap and prefers H.264', () {
      final parsed = Hls.parseMaster(master, base)!;
      final pick = Hls.pick(
        parsed,
        const GrabOptions(quality: GrabQuality.p720),
      );
      expect(pick.video.toString(), endsWith('/v720.m3u8'));
      expect(pick.audio.toString(), endsWith('/audio/en.m3u8'));
      expect(pick.height, 720);
    });

    test('best quality takes the top variant', () {
      final parsed = Hls.parseMaster(master, base)!;
      final pick = Hls.pick(
        parsed,
        const GrabOptions(quality: GrabQuality.max),
      );
      expect(pick.video.toString(), endsWith('/v1080.m3u8'));
    });

    test('audio mode uses only the audio rendition', () {
      final parsed = Hls.parseMaster(master, base)!;
      final pick = Hls.pick(parsed, const GrabOptions(mode: GrabMode.audio));
      expect(pick.video, isNull);
      expect(pick.audio.toString(), endsWith('/audio/en.m3u8'));
    });

    test('muted mode drops the audio rendition', () {
      final parsed = Hls.parseMaster(master, base)!;
      final pick = Hls.pick(parsed, const GrabOptions(mode: GrabMode.mute));
      expect(pick.audio, isNull);
    });

    test('prefers AAC audio over AC-3 at the same quality', () {
      final pick = Hls.pickVariant([
        HlsVariant(
          uri: Uri.parse('https://a/ac3.m3u8'),
          bandwidth: 2000,
          height: 720,
          codecs: 'avc1.64001f,ac-3',
        ),
        HlsVariant(
          uri: Uri.parse('https://a/aac.m3u8'),
          bandwidth: 1900,
          height: 720,
          codecs: 'avc1.64001f,mp4a.40.2',
        ),
      ], 720);
      expect(pick.uri.path, '/aac.m3u8');
    });

    test('vertical video is capped on its short side', () {
      final variant = Hls.pickVariant([
        HlsVariant(uri: base, bandwidth: 1, width: 1080, height: 1920),
      ], 1080);
      expect(variant.shortSide, 1080);
    });

    test('detects DRM playlists but allows clear-key AES-128', () {
      expect(
        Hls.isDrmProtected(
          '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://x",'
          'KEYFORMAT="com.apple.streamingkeydelivery"\n',
          base,
        ),
        isTrue,
      );
      expect(
        Hls.isDrmProtected(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://k/key"\n',
          base,
        ),
        isFalse,
      );
      expect(
        Hls.isDrmProtected('', Uri.parse('https://cdn/v2/drm/cbcs/a.m3u8')),
        isTrue,
      );
    });

    test('media playlists are not masters', () {
      expect(Hls.parseMaster('#EXTM3U\n#EXTINF:4,\nseg0.ts\n', base), isNull);
    });
  });

  test('filenames are made safe', () {
    expect(grabSafeFilename('a/b:c*?"<>|d'), 'a-b-c------d');
    expect(grabSafeFilename('  ...  '), 'download');
    expect(grabSafeFilename('x' * 300).length, 120);
  });

  test('html meta lookup handles either attribute order', () {
    const html =
        '<meta content="https://a.com/v.mp4" property="og:video">'
        '<meta name="og:title" content="Tom &amp; Jerry">';
    expect(htmlMeta(html, 'og:video'), 'https://a.com/v.mp4');
    expect(htmlMeta(html, 'og:title'), 'Tom & Jerry');
  });
}
