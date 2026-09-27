import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';

import 'grab_models.dart';

/// Runs one bundled-FFmpeg command (argument list, so paths with spaces
/// need no quoting) and reports time-based progress when [duration] is known.
abstract final class FfmpegRunner {
  static bool _configured = false;

  static Future<void> run(
    List<String> args, {
    Duration? duration,
    void Function(double? fraction)? onProgress,
    GrabCancelToken? cancel,
  }) async {
    if (!_configured) {
      _configured = true;
      // Keep only warnings and errors in the session log we surface.
      await FFmpegKitConfig.setLogLevel(24);
    }
    cancel?.throwIfCancelled();
    final done = Completer<void>();
    final totalMs = duration?.inMilliseconds ?? 0;
    final session = await FFmpegKit.executeWithArgumentsAsync(
      ['-hide_banner', '-nostdin', ...args],
      (session) async {
        final code = await session.getReturnCode();
        if (done.isCompleted) return;
        if (ReturnCode.isSuccess(code)) {
          done.complete();
        } else if (ReturnCode.isCancel(code) ||
            (cancel?.isCancelled ?? false)) {
          done.completeError(const GrabCancelled());
        } else {
          final logs = await session.getAllLogsAsString() ?? '';
          final tail = logs.length > 1200
              ? logs.substring(logs.length - 1200)
              : logs;
          done.completeError(GrabException(_friendly(tail), detail: tail));
        }
      },
      null,
      (statistics) {
        if (onProgress == null) return;
        if (totalMs <= 0) {
          onProgress(null);
          return;
        }
        onProgress((statistics.getTime() / totalMs).clamp(0.0, 1.0));
      },
    );
    final unregister = cancel?.onCancel(
      () => FFmpegKit.cancel(session.getSessionId()),
    );
    try {
      await done.future;
    } finally {
      unregister?.call();
    }
  }

  static String _friendly(String log) {
    final lower = log.toLowerCase();
    if (lower.contains('403 forbidden') ||
        lower.contains('server returned 403')) {
      return 'The media server refused the stream.';
    }
    if (lower.contains('404 not found')) {
      return 'The stream has expired. Try grabbing again.';
    }
    if (lower.contains('no space left')) {
      return 'Not enough storage space to finish.';
    }
    if (lower.contains('could not find codec parameters') ||
        lower.contains('invalid data found')) {
      return 'The media stream was unreadable.';
    }
    return 'Processing the media failed.';
  }
}
