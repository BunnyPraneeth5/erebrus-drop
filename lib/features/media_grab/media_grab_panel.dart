import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme/drop_theme.dart';
import '../../ui/widgets/drop_widgets.dart';
import 'grab_models.dart';
import 'media_grab_service.dart';

/// Where a finished grab was stored, for the confirmation line; null when
/// the user backed out (e.g. declined to choose a Drop folder).
typedef GrabSaveHandler = Future<String?> Function(GrabResult result);

/// "Grab" tab body: paste a public link, pick video/audio/muted, and the file
/// lands in the Drop folder (or the live room) ready to share.
class MediaGrabPanel extends StatefulWidget {
  const MediaGrabPanel({
    required this.service,
    required this.onSave,
    required this.ensureDestination,
    required this.destinationLabel,
    this.incomingLink,
    super.key,
  });

  final MediaGrabService service;
  final GrabSaveHandler onSave;

  /// Makes sure there is somewhere to save (asks for a Drop folder when no
  /// room is live) before any bytes are downloaded; false aborts the grab.
  final Future<bool> Function() ensureDestination;

  /// e.g. `Drop Room` or the Drop folder name.
  final String destinationLabel;

  /// Links handed over from the share sheet; consumed and cleared.
  final ValueNotifier<String?>? incomingLink;

  @override
  State<MediaGrabPanel> createState() => _MediaGrabPanelState();
}

/// MP4 qualities first so the default (1080p) is visible without
/// scrolling; the WebM-only YouTube tiers and Best follow.
const List<GrabQuality> _qualityOrder = [
  GrabQuality.p1080,
  GrabQuality.p720,
  GrabQuality.p480,
  GrabQuality.p360,
  GrabQuality.p1440,
  GrabQuality.p2160,
  GrabQuality.max,
];

class _ItemState {
  GrabProgress? progress;
  bool busy = false;
  String? savedTo;
  String? error;
}

class _MediaGrabPanelState extends State<MediaGrabPanel> {
  final TextEditingController _url = TextEditingController();
  GrabOptions _options = const GrabOptions();
  bool _resolving = false;
  String? _error;
  GrabMedia? _media;
  final Map<int, _ItemState> _items = {};
  GrabCancelToken? _cancel;
  int _generation = 0;

  bool get _downloading => _items.values.any((s) => s.busy);

  @override
  void initState() {
    super.initState();
    widget.incomingLink?.addListener(_onIncoming);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onIncoming());
  }

  @override
  void didUpdateWidget(MediaGrabPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incomingLink != widget.incomingLink) {
      oldWidget.incomingLink?.removeListener(_onIncoming);
      widget.incomingLink?.addListener(_onIncoming);
    }
  }

  @override
  void dispose() {
    widget.incomingLink?.removeListener(_onIncoming);
    _cancel?.cancel();
    _url.dispose();
    super.dispose();
  }

  void _onIncoming() {
    final link = widget.incomingLink?.value;
    if (link == null || !mounted) return;
    widget.incomingLink!.value = null;
    _url.text = link;
    unawaited(_resolve());
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _url.text = text;
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final input = _url.text.trim();
    if (input.isEmpty || _downloading) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    setState(() {
      _resolving = true;
      _error = null;
      _media = null;
      _items.clear();
    });
    try {
      final media = await widget.service.resolve(input, _options);
      if (!mounted || generation != _generation) return;
      setState(() {
        _media = media;
        _resolving = false;
      });
      // Paste → file: a single result starts right away.
      if (media.items.length == 1) unawaited(_grab(0));
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _resolving = false;
        _error = _describe(e);
      });
    }
  }

  Future<void> _grab(int index, {bool destinationReady = false}) async {
    final media = _media;
    if (media == null || _downloading) return;
    final state = _items.putIfAbsent(index, _ItemState.new);
    if (!destinationReady && !await widget.ensureDestination()) {
      if (mounted) {
        setState(() => state.error = 'Choose a Drop folder to save into.');
      }
      return;
    }
    if (!mounted || _media != media) return;
    final cancel = _cancel = GrabCancelToken();
    setState(() {
      state
        ..busy = true
        ..error = null
        ..savedTo = null
        ..progress = const GrabProgress(GrabStage.fetching);
    });
    GrabResult? result;
    try {
      result = await widget.service.fetch(
        media.items[index],
        _options,
        cancel: cancel,
        onProgress: (p) {
          if (mounted) setState(() => state.progress = p);
        },
      );
      if (!mounted) return;
      setState(() => state.progress = const GrabProgress(GrabStage.saving));
      final savedTo = await widget.onSave(result);
      if (!mounted) return;
      setState(() {
        state.savedTo = savedTo;
        if (savedTo == null) state.error = 'Not saved — choose a Drop folder.';
      });
    } on GrabCancelled {
      // Back to idle.
    } catch (e) {
      if (mounted) setState(() => state.error = _describe(e));
    } finally {
      if (result != null) unawaited(widget.service.discard(result));
      if (mounted) {
        setState(() {
          state
            ..busy = false
            ..progress = null;
        });
      }
    }
  }

  Future<void> _grabAll() async {
    final media = _media;
    if (media == null || !await widget.ensureDestination()) return;
    for (var i = 0; i < media.items.length; i++) {
      if (!mounted || _media != media) return;
      if (_items[i]?.savedTo != null) continue;
      await _grab(i, destinationReady: true);
      if (_cancel?.isCancelled ?? false) return;
    }
  }

  void _setOptions(GrabOptions options) {
    setState(() => _options = options);
    // Extractors pick streams for the chosen mode/quality, so re-resolve.
    if (_media != null && !_downloading) unawaited(_resolve());
  }

  static String _describe(Object error) {
    if (error is GrabException) {
      if (kDebugMode && error.detail != null) {
        debugPrint('Grab failed: ${error.detail}');
      }
      return error.message;
    }
    if (kDebugMode) debugPrint('Grab failed: $error');
    return 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _composer(context),
        if (_error != null) ...[const SizedBox(height: 12), _errorCard()],
        if (_media != null) ...[
          const SizedBox(height: 12),
          _results(context, _media!),
        ],
        const SizedBox(height: 16),
        _footer(context),
      ],
    );
  }

  Widget _composer(BuildContext context) {
    final audio = _options.mode == GrabMode.audio;
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            enabled: !_resolving,
            onSubmitted: (_) => unawaited(_resolve()),
            decoration: InputDecoration(
              hintText: 'Paste a video, audio or post link',
              prefixIcon: const Icon(Icons.link_rounded, size: 20),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _url,
                builder: (context, value, _) => value.text.isEmpty
                    ? IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste_rounded),
                        onPressed: _resolving ? null : _paste,
                      )
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _resolving
                            ? null
                            : () => setState(() {
                                _url.clear();
                                _media = null;
                                _error = null;
                                _items.clear();
                              }),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          DropSegmented(
            expand: true,
            labels: GrabMode.values.map((m) => m.label).toList(),
            icons: const [
              Icons.movie_outlined,
              Icons.music_note_rounded,
              Icons.volume_off_rounded,
            ],
            selected: _options.mode.index,
            onSelected: (i) =>
                _setOptions(_options.copyWith(mode: GrabMode.values[i])),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: audio
                  ? [
                      for (final f in GrabAudioFormat.values)
                        _chip(
                          f.label,
                          _options.audioFormat == f,
                          () => _setOptions(_options.copyWith(audioFormat: f)),
                        ),
                    ]
                  : [
                      for (final q in _qualityOrder)
                        _chip(
                          q.chipLabel,
                          _options.quality == q,
                          () => _setOptions(_options.copyWith(quality: q)),
                        ),
                    ],
            ),
          ),
          if (!audio && _options.quality.savesAsWebm) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: DropTheme.amber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'YouTube above 1080p is saved as WebM (VP9). It plays in '
                    'VLC and on Android, but not in iPhone Photos. 1080p and '
                    'below are MP4 everywhere.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          PrimaryButton(
            label: _resolving ? 'Finding media…' : 'Grab',
            icon: Icons.download_rounded,
            busy: _resolving,
            onPressed: _resolving || _downloading
                ? null
                : () => unawaited(_resolve()),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(
          fontFamily: DropTheme.bodyFont,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          fontSize: 12.5,
          color: selected ? DropTheme.orange : DropTheme.muted,
        ),
        selectedColor: DropTheme.orange.withValues(alpha: 0.16),
        backgroundColor: DropTheme.surfaceHigh,
        side: BorderSide(
          color: selected
              ? DropTheme.orange.withValues(alpha: 0.5)
              : DropTheme.line,
        ),
        onSelected: _downloading ? null : (_) => onTap(),
      ),
    );
  }

  Widget _errorCard() {
    return DropCard.tinted(
      accent: DropTheme.danger,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: DropTheme.danger,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DropTheme.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context, GrabMedia media) {
    final textTheme = Theme.of(context).textTheme;
    final many = media.items.length > 1;
    final pending = media.items.indexed.where(
      (e) => _items[e.$1]?.savedTo == null,
    );
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumb(url: media.thumbnail ?? media.items.first.thumbnail),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      media.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        media.service,
                        if (media.author != null) media.author!,
                        if (many) '${media.items.length} items',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (index, item) in media.items.indexed)
            _itemRow(context, index, item),
          if (many && pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            TonalButton(
              label: 'Save all (${pending.length})',
              icon: Icons.download_for_offline_outlined,
              expand: true,
              onPressed: _downloading ? null : () => unawaited(_grabAll()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _itemRow(BuildContext context, int index, GrabItem item) {
    final state = _items[index];
    final textTheme = Theme.of(context).textTheme;
    final progress = state?.progress;
    final (icon, color) = switch (item.kind) {
      GrabKind.video => (Icons.movie_rounded, DropTheme.orange),
      GrabKind.audio => (Icons.music_note_rounded, DropTheme.amber),
      GrabKind.photo => (Icons.image_rounded, DropTheme.success),
      GrabKind.gif => (Icons.gif_box_rounded, DropTheme.success),
    };
    final String status;
    if (state?.busy == true && progress != null) {
      status = switch (progress.stage) {
        GrabStage.fetching =>
          progress.total != null && progress.bytes != null
              ? 'Downloading ${_mb(progress.bytes!)} / ${_mb(progress.total!)}'
              : 'Downloading…',
        GrabStage.processing => 'Processing…',
        GrabStage.saving => 'Saving…',
      };
    } else if (state?.savedTo != null) {
      status = 'Saved to ${state!.savedTo}';
    } else if (state?.error != null) {
      status = state!.error!;
    } else {
      status = item.label ?? item.kind.name;
    }
    final statusColor = state?.error != null
        ? DropTheme.danger
        : state?.savedTo != null
        ? DropTheme.success
        : DropTheme.muted;

    Widget trailing;
    if (state?.busy == true) {
      trailing = DropIconButton(
        icon: Icons.close_rounded,
        tooltip: 'Cancel',
        onPressed: () => _cancel?.cancel(),
      );
    } else if (state?.savedTo != null) {
      trailing = const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.check_circle_rounded, color: DropTheme.success),
      );
    } else {
      trailing = DropIconButton(
        icon: state?.error != null
            ? Icons.refresh_rounded
            : Icons.download_rounded,
        tonal: true,
        tooltip: state?.error != null ? 'Retry' : 'Save',
        onPressed: _downloading ? null : () => unawaited(_grab(index)),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              LeadingTile(icon: icon, accent: color, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: DropTheme.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(color: statusColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
          if (state?.busy == true) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: progress?.fraction,
                color: DropTheme.orange,
                backgroundColor: DropTheme.surfaceHigh,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Eyebrow('WORKS WITH'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final s in MediaGrabService.supportedServices)
              DropPill(label: s, color: DropTheme.muted),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Runs entirely on this device. Files are saved to '
          '${widget.destinationLabel}. Only download media you have the '
          'right to save.',
          style: textTheme.bodySmall,
        ),
      ],
    );
  }

  static String _mb(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({this.url});

  final Uri? url;

  @override
  Widget build(BuildContext context) {
    const size = 56.0;
    final placeholder = Container(
      width: size,
      height: size,
      color: DropTheme.surfaceHigh,
      alignment: Alignment.center,
      child: const Icon(
        Icons.play_circle_outline_rounded,
        color: DropTheme.faint,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(DropTheme.radiusTile),
      child: url == null
          ? placeholder
          : Image.network(
              url.toString(),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}
