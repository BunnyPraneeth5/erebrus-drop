import 'dart:io';

import 'package:erebrus_drop/features/gateway/drop_gateway_client.dart';
import 'package:erebrus_drop/features/gateway/gateway_http.dart';
import 'package:erebrus_drop/features/gateway/gateway_models.dart';
import 'package:flutter_test/flutter_test.dart';

DropGatewayFile _file({String visibility = 'public', String scope = 'public', String? cid}) =>
    DropGatewayFile.fromJson({
      'file_id': 'f1',
      'filename': 'a.txt',
      'size_bytes': 4,
      'visibility': visibility,
      'scope': scope,
      'cid': ?cid,
    });

void main() {
  test('downloads use the gateway /content route, never the removed /download route', () {
    final client = DropGatewayClient(gatewayUrl: 'https://dev.gateway.erebrus.io');
    final urls = client.resolveDownloadCandidates(_file(visibility: 'private', scope: 'private'))
        .map((u) => u.path)
        .toList();
    expect(urls, contains('/api/v2/drop/files/f1/content'));
    expect(urls.where((p) => p.endsWith('/download')), isEmpty);
  });

  test('only the owner files route needs the bearer token', () {
    final client = DropGatewayClient(gatewayUrl: 'https://dev.gateway.erebrus.io');
    expect(client.needsAuthForDownload(Uri.parse('https://dev.gateway.erebrus.io/api/v2/drop/files/f1/content')), isTrue);
    expect(client.needsAuthForDownload(Uri.parse('https://ipfs.erebrus.io/ipfs/bafy')), isFalse);
  });

  test('each upload gets a unique idempotency key', () {
    final keys = List.generate(50, (_) => DropGatewayClient.randomIdempotencyKey()).toSet();
    expect(keys.length, 50);
    expect(keys.first.length, greaterThanOrEqualTo(16));
  });

  test('hashes files by streaming', () async {
    final dir = await Directory.systemTemp.createTemp('drop-hash');
    final f = File('${dir.path}/x.bin')..writeAsStringSync('test');
    expect(
      await sha256OfFile(f),
      '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
    );
    await dir.delete(recursive: true);
  });

  test('explains quota and file-size errors from the gateway', () {
    expect(
      friendlyDropUploadError(GatewayException('storage quota exceeded', statusCode: 409, errorCode: 'DROP_QUOTA_EXCEEDED')),
      contains('storage is full'),
    );
    expect(
      friendlyDropUploadError(GatewayException('too big', statusCode: 413, errorCode: 'DROP_FILE_TOO_LARGE')),
      contains('per-file limit'),
    );
    expect(friendlyDropUploadError(Exception('boom')), contains('Upload failed'));
  });
}
