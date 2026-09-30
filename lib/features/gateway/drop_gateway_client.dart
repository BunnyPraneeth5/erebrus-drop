import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import 'gateway_config.dart';
import 'gateway_http.dart';
import 'gateway_models.dart';

/// SHA-256 of a file computed by streaming (constant memory).
Future<String> sha256OfFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Clear copy for gateway Drop upload errors. The gateway enforces quota and
/// per-file limits; this only explains its answer.
String friendlyDropUploadError(Object error) {
  if (error is GatewayException) {
    switch (error.errorCode) {
      case 'DROP_QUOTA_EXCEEDED':
        return 'Your Drop storage is full. Delete files or upgrade at erebrus.io/pricing for more space.';
      case 'DROP_FILE_TOO_LARGE':
        return 'This file is larger than your plan\'s per-file limit.';
      case 'DROP_NODE_CAPACITY':
        return 'This node is full. Pick another node.';
      case 'DROP_NODE_UNAVAILABLE':
        return 'This node isn\'t accepting uploads right now. Pick another node or try again.';
    }
    if (error.statusCode == 413) return 'This file is larger than your plan\'s per-file limit.';
    return 'Upload failed: ${error.message}';
  }
  return 'Upload failed: $error';
}

/// Client for the Erebrus gateway Drop endpoints.
class DropGatewayClient {
  DropGatewayClient({String? gatewayUrl, this.bearerToken, this.onUnauthorized})
    : _base = GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl()),
      _ipfsGatewayBase = GatewayHttp.normalizeBase(resolveIpfsGatewayUrl());

  final Uri _base;
  Uri _ipfsGatewayBase;
  String? bearerToken;
  Future<void> Function(String token)? onUnauthorized;

  set token(String? value) => bearerToken = value;

  /// Sets the public IPFS gateway base URL (e.g. `https://ipfs.erebrus.io`).
  set ipfsGatewayUrl(String? value) {
    _ipfsGatewayBase = GatewayHttp.normalizeBase(
      value != null && value.trim().isNotEmpty
          ? value.trim()
          : resolveIpfsGatewayUrl(),
    );
  }

  String get ipfsGatewayUrl => _ipfsGatewayBase.toString();

  /// `GET /api/v2/drop/nodes` — public or private-org Drop-capable nodes.
  Future<List<DropNode>> fetchDropNodes({
    String scope = 'public',
    String? orgId,
  }) async {
    final query = <String, String>{'scope': scope};
    if (orgId != null && orgId.isNotEmpty && scope == 'private') {
      query['org_id'] = orgId;
    }
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/drop/nodes', query: query),
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    final nodes = (map['nodes'] as List?) ?? [];
    return nodes
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropNode.fromJson(Map<String, dynamic>.from(e)))
        .where((n) => n.nodeId.isNotEmpty)
        .toList();
  }

  /// `POST /api/v2/drop/uploads` — reserve an upload slot on a node.
  Future<DropUploadReservation> reserveUpload({
    required String nodeId,
    required int sizeBytes,
    required String filename,
    required String contentType,
    required String visibility,
    String scope = 'public',
    String? orgId,
    String? sha256,
    bool encrypted = false,
    Map<String, dynamic>? encryptionMetadata,
    String? idempotencyKey,
  }) async {
    final body = <String, dynamic>{
      'node_id': nodeId,
      'scope': scope,
      'visibility': visibility,
      'filename': filename,
      'content_type': contentType,
      'size_bytes': sizeBytes,
      'encrypted': encrypted,
      'idempotency_key': idempotencyKey ?? _randomIdempotencyKey(),
      if (orgId != null && orgId.isNotEmpty && scope == 'private')
        'org_id': orgId,
      if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
      if (encryptionMetadata != null && encryptionMetadata.isNotEmpty)
        'encryption_metadata': encryptionMetadata,
    };
    final map = await GatewayHttp.postJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/drop/uploads'),
      body,
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    return DropUploadReservation.fromJson(map);
  }

  /// `PUT /api/v2/drop/uploads/{upload_id}/content` — stream [file] bytes.
  /// Returns the committed file record.
  Future<DropGatewayFile> uploadContent(
    DropUploadReservation reservation,
    File file, {
    String? contentType,
  }) async {
    final uri = GatewayHttp.apiUri(
      _base,
      path: '/api/v2/drop/uploads/${reservation.uploadId}/content',
    );
    final map = await GatewayHttp.putBytes(
      uri,
      file.openRead().cast<List<int>>(),
      contentLength: await file.length(),
      contentType: contentType ?? 'application/octet-stream',
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    return DropGatewayFile.fromJson(map);
  }

  /// Convenience: reserve + upload a local file to a node.
  /// Returns the committed file (with `cid`).
  Future<DropGatewayFile> uploadFile({
    required String nodeId,
    required File file,
    required String filename,
    required String visibility,
    String scope = 'public',
    String? orgId,
    String? contentType,
  }) async {
    // Hash while streaming so large files (up to the 1 GB plan limit) are
    // never held in memory.
    final sha = await sha256OfFile(file);
    final reservation = await reserveUpload(
      nodeId: nodeId,
      sizeBytes: await file.length(),
      filename: filename,
      contentType: contentType ?? 'application/octet-stream',
      visibility: visibility,
      scope: scope,
      orgId: orgId,
      sha256: sha,
    );
    return uploadContent(reservation, file, contentType: contentType);
  }

  /// `GET /api/v2/drop/files` — caller's own Drop files.
  Future<List<DropGatewayFile>> fetchMyFiles() async {
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/drop/files'),
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    final files = (map['files'] as List?) ?? [];
    return files
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropGatewayFile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `GET /api/v2/orgs/{org_id}/drop/files` — org Drop files.
  Future<List<DropGatewayFile>> fetchOrgFiles(String orgId) async {
    final map = await GatewayHttp.getJson(
      GatewayHttp.apiUri(_base, path: '/api/v2/orgs/$orgId/drop/files'),
      bearerToken: bearerToken,
      onUnauthorized: onUnauthorized,
    );
    final files = (map['files'] as List?) ?? [];
    return files
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DropGatewayFile.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // Each logical upload needs a unique key: the gateway returns the existing
  // reservation for a repeated key, so a constant key made every later upload
  // silently resolve to the first file.
  String _randomIdempotencyKey() => randomIdempotencyKey();

  @visibleForTesting
  static String randomIdempotencyKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Encode(bytes).replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  }

  /// Downloads a gateway file to a temporary file.
  ///
  /// Tries several candidate URLs in order:
  /// 1. Server-provided `download_url` / `gateway_url`.
  /// 2. Public IPFS gateway at `GATEWAY_URL/ipfs/{cid}`.
  /// 3. Authenticated private-file endpoints.
  ///
  /// If [encryptionKey] is provided and the file is encrypted, the bytes are
  /// decrypted with AES-256-GCM before the file is returned.
  Future<File> downloadFile(
    DropGatewayFile file, {
    String? encryptionKey,
    void Function(int received, int total)? onProgress,
  }) async {
    if (file.encrypted && (encryptionKey == null || encryptionKey.isEmpty)) {
      throw GatewayException(
        'This file is encrypted. Provide a decryption key to download.',
      );
    }

    final candidates = _resolveDownloadCandidates(file);
    if (candidates.isEmpty) {
      throw GatewayException('No download URL available for this file.');
    }

    final directory = await _downloadStagingDirectory();
    await directory.create(recursive: true);
    final tempFile = await _uniqueStagingFile(
      directory,
      _safeName(file.filename),
    );

    GatewayException? lastError;
    for (var i = 0; i < candidates.length; i++) {
      final url = candidates[i];
      try {
        await _downloadToTemp(
          url,
          tempFile,
          needsAuth: _needsAuthForDownload(url),
          onProgress: onProgress,
        );
        lastError = null;
        break;
      } on GatewayException catch (e) {
        lastError = e;
        // Try the next candidate on HTTP errors (404, 403, etc.).
        if (i == candidates.length - 1) rethrow;
        continue;
      }
    }

    if (lastError != null) throw lastError;

    if (file.encrypted && encryptionKey != null && encryptionKey.isNotEmpty) {
      final encrypted = await tempFile.readAsBytes();
      Uint8List decrypted;
      try {
        decrypted = _decryptAesGcm(
          encrypted,
          encryptionKey,
          file.encryptionMetadata,
          file.fileId,
        );
      } catch (e) {
        throw GatewayException('Decryption failed: $e');
      }
      final decryptedFile = File('${tempFile.path}.dec');
      await decryptedFile.writeAsBytes(decrypted);
      return decryptedFile;
    }

    return tempFile;
  }

  /// Builds the ordered list of URLs to try for a file download.
  @visibleForTesting
  List<Uri> resolveDownloadCandidates(DropGatewayFile file) => _resolveDownloadCandidates(file);

  @visibleForTesting
  bool needsAuthForDownload(Uri url) => _needsAuthForDownload(url);

  List<Uri> _resolveDownloadCandidates(DropGatewayFile file) {
    final candidates = <Uri>[];
    void addRaw(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      final uri = Uri.tryParse(raw.trim());
      if (uri == null) return;
      if (uri.hasAbsolutePath && !uri.hasScheme) {
        candidates.add(_base.resolve(raw.trim()));
      } else {
        candidates.add(uri);
      }
    }

    addRaw(file.downloadUrl);
    addRaw(file.gatewayUrl);
    if (file.cid?.isNotEmpty == true) {
      candidates.add(
        GatewayHttp.apiUri(_ipfsGatewayBase, path: '/ipfs/${file.cid}'),
      );
    }
    if (file.fileId.isNotEmpty) {
      // Owner/org download streams through the gateway (works for private and
      // encrypted files); public files also have the unauthenticated route.
      candidates.add(
        GatewayHttp.apiUri(
          _base,
          path: '/api/v2/drop/files/${file.fileId}/content',
        ),
      );
      if (file.visibility == 'public' && file.scope == 'public') {
        candidates.add(
          GatewayHttp.apiUri(
            _base,
            path: '/api/v2/drop/public/${file.fileId}/content',
          ),
        );
      }
    }

    // Deduplicate while preserving order.
    final seen = <String>{};
    return candidates.where((u) => seen.add(u.toString())).toList();
  }

  /// Whether a download URL needs the bearer token.
  bool _needsAuthForDownload(Uri url) {
    return url.host == _base.host && url.path.startsWith('/api/v2/drop/files/');
  }

  /// Downloads [url] to [tempFile] and throws [GatewayException] on HTTP errors.
  Future<void> _downloadToTemp(
    Uri url,
    File tempFile, {
    required bool needsAuth,
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = GatewayHttp.createClient().connectionTimeout;
    try {
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 20));
      if (needsAuth && bearerToken != null && bearerToken!.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $bearerToken',
        );
      }
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode >= 400) {
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode == HttpStatus.unauthorized &&
            needsAuth &&
            bearerToken != null &&
            bearerToken!.isNotEmpty) {
          await onUnauthorized?.call(bearerToken!);
        }
        throw GatewayHttp.responseException(response.statusCode, body);
      }
      final sink = tempFile.openWrite();
      var received = 0;
      final total = response.contentLength;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
    } on SocketException catch (e) {
      throw GatewayException('Cannot reach Erebrus: ${e.message}');
    } on TimeoutException {
      throw GatewayException('Download timed out');
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory> _downloadStagingDirectory() async {
    final temp = await getTemporaryDirectory();
    return Directory(
      '${temp.path}${Platform.pathSeparator}erebrus_drop_downloads',
    );
  }

  Future<File> _uniqueStagingFile(Directory directory, String name) async {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    final random = Random.secure().nextInt(999999).toString().padLeft(6, '0');
    var candidate = File(
      '${directory.path}${Platform.pathSeparator}$base-$random$ext',
    );
    var index = 1;
    while (await candidate.exists()) {
      candidate = File(
        '${directory.path}${Platform.pathSeparator}$base-$random-$index$ext',
      );
      index++;
    }
    return candidate;
  }

  String _safeName(String name) {
    final safe = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.isEmpty ? 'download' : safe;
  }

  /// Decrypts [encryptedBytes] using AES-256-GCM.
  ///
  /// The [keyText] is treated as:
  ///   - a base64-encoded 32-byte key if it is 44 characters,
  ///   - a hex 32-byte key if it is 64 hex characters,
  ///   - otherwise it is hashed with SHA-256 to produce a 32-byte key.
  ///
  /// The 12-byte nonce is read from `metadata['iv']` or `metadata['nonce']`
  /// (base64). If absent, a deterministic nonce is derived from [fileId] so
  /// files encrypted without a stored nonce can still be decrypted.
  Uint8List _decryptAesGcm(
    Uint8List encryptedBytes,
    String keyText,
    Map<String, dynamic>? metadata,
    String fileId,
  ) {
    final key = _deriveKey(keyText);
    var nonce = _decodeNonce(metadata);
    if (nonce == null || nonce.length != 12) {
      final hash = sha256.convert(utf8.encode(fileId)).bytes;
      nonce = Uint8List.fromList(hash.take(12).toList());
    }

    // If the server returns the auth tag separately in metadata, append it.
    final tagBase64 = (metadata?['tag'] ?? metadata?['auth_tag'])?.toString();
    Uint8List cipherInput = encryptedBytes;
    if (tagBase64 != null && tagBase64.isNotEmpty) {
      final tag = base64Decode(tagBase64);
      cipherInput = Uint8List(encryptedBytes.length + tag.length)
        ..setAll(0, encryptedBytes)
        ..setAll(encryptedBytes.length, tag);
    }

    final cipher = GCMBlockCipher(
      AESEngine(),
    )..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    try {
      return cipher.process(cipherInput);
    } on ArgumentError catch (e) {
      throw StateError('Decryption failed: ${e.message}');
    }
  }

  Uint8List _deriveKey(String keyText) {
    if (keyText.length == 44) {
      try {
        final decoded = base64Decode(keyText);
        if (decoded.length == 32) return Uint8List.fromList(decoded);
      } catch (_) {}
    }
    if (keyText.length == 64) {
      try {
        final decoded = _hexDecode(keyText);
        if (decoded.length == 32) return Uint8List.fromList(decoded);
      } catch (_) {}
    }
    return Uint8List.fromList(sha256.convert(utf8.encode(keyText)).bytes);
  }

  Uint8List? _decodeNonce(Map<String, dynamic>? metadata) {
    final raw = metadata?['iv'] ?? metadata?['nonce'];
    if (raw == null) return null;
    final text = raw.toString();
    if (text.isEmpty) return null;
    try {
      if (text.length == 24) {
        // 12 bytes encoded as hex.
        return _hexDecode(text);
      }
      return base64Decode(text);
    } catch (_) {
      return utf8.encode(text) as Uint8List?;
    }
  }

  Uint8List _hexDecode(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.parse(hex.substring(i, i + 2), radix: 16);
      bytes.add(byte);
    }
    return Uint8List.fromList(bytes);
  }
}
