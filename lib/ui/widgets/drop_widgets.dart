import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/drop_theme.dart';

/// Reusable building blocks for the Erebrus Drop redesign (spec §5).
///
/// Everything here is a thin, themed primitive — cards, buttons, pills, tiles,
/// stat blocks and a couple of subtle motion helpers — so screens stay
/// declarative and the accent stays a single source of truth.

// --- Motion ----------------------------------------------------------------

/// Wraps [child] with a gentle press scale (0.98) + optional tap handling.
/// Respects the platform reduced-motion setting.
class PressableScale extends StatefulWidget {
  const PressableScale({
    required this.child,
    this.onTap,
    this.enabled = true,
    this.borderRadius,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final BorderRadius? borderRadius;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final pressed = _down && !reduceMotion;
    return Semantics(
      button: _interactive,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _interactive ? (_) => setState(() => _down = true) : null,
        onTapUp: _interactive ? (_) => setState(() => _down = false) : null,
        onTapCancel: _interactive ? () => setState(() => _down = false) : null,
        onTap: _interactive ? widget.onTap : null,
        child: AnimatedScale(
          scale: pressed ? 0.98 : 1,
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A soft, slow pulsing dot — used for the LIVE marker and "scanning" footer.
class PulsingDot extends StatefulWidget {
  const PulsingDot({this.color = DropTheme.success, this.size = 8, super.key});

  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      return _dot(1);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => _dot(0.45 + _controller.value * 0.55),
    );
  }

  Widget _dot(double opacity) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: opacity),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: opacity * 0.6),
            blurRadius: widget.size,
            spreadRadius: widget.size * 0.15,
          ),
        ],
      ),
    );
  }
}

/// A 200ms fade + 8px rise used on screen-enter for the title and first card.
class EnterTransition extends StatefulWidget {
  const EnterTransition({required this.child, this.delayMs = 0, super.key});

  final Widget child;
  final int delayMs;

  @override
  State<EnterTransition> createState() => _EnterTransitionState();
}

class _EnterTransitionState extends State<EnterTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    if (widget.delayMs <= 0) {
      _controller.forward();
    } else {
      _startTimer = Timer(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) return widget.child;
    final curved = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, (1 - curved.value) * 8),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

// --- Surfaces --------------------------------------------------------------

/// Card surface with a 1px hairline border and no shadow (spec §4: borders over
/// shadows). Variants: [DropCard.tinted] for feature/CTA cards, [glow] for the
/// single hero card per screen.
class DropCard extends StatelessWidget {
  const DropCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.glow = false,
    super.key,
  }) : _fill = DropTheme.surface,
       _border = DropTheme.line,
       _glowColor = DropTheme.orange;

  DropCard.tinted({
    required this.child,
    Color accent = DropTheme.orange,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.glow = false,
    super.key,
  }) : _fill = DropTheme.tinted(accent),
       _border = DropTheme.tintBorder(accent),
       _glowColor = accent;

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool glow;
  final Color _fill;
  final Color _border;
  final Color _glowColor;

  @override
  Widget build(BuildContext context) {
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: BorderRadius.circular(DropTheme.radiusCard),
        border: Border.all(color: _border),
        boxShadow: glow ? DropTheme.heroGlow(_glowColor) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DropTheme.radiusCard),
      child: card,
    );
  }
}

/// Inset surface for lists, progress panels, and empty states — a lighter
/// `surfaceHigh` tile with a hairline border and `radiusTile`. Use this instead
/// of hand-rolling `DecoratedBox`/`Container` surfaces inside screens.
class DropInset extends StatelessWidget {
  const DropInset({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.color = DropTheme.surfaceHigh,
    this.borderColor = DropTheme.line,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(DropTheme.radiusTile),
        border: Border.all(color: borderColor),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A soft radial accent glow bleed for a screen corner (spec §4). Decorative
/// and non-interactive — drop it into a Stack behind the scroll body.
class AmbientGlow extends StatelessWidget {
  const AmbientGlow({
    this.color = DropTheme.orange,
    this.alignment = Alignment.topRight,
    this.diameter = 360,
    this.opacity = 0.16,
    super.key,
  });

  final Color color;
  final Alignment alignment;
  final double diameter;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Transform.translate(
          offset: Offset(diameter * 0.18, -diameter * 0.32),
          child: Container(
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  color.withValues(alpha: opacity),
                  color.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Buttons ---------------------------------------------------------------

Widget _spinner(Color color) => SizedBox.square(
  dimension: 18,
  child: CircularProgressIndicator(strokeWidth: 2, color: color),
);

/// Phone-width layouts (small Android phones, iPhone SE/mini) get tighter
/// buttons so a trailing action never crowds the text beside it.
bool isCompactWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 390;

/// Button labels sit in fixed-height pills, so large accessibility text is
/// capped here instead of overflowing; body text still scales fully.
TextScaler _buttonTextScaler(BuildContext context) =>
    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);

/// Icon + single-line label that shrink together to fit the space they are
/// given, instead of wrapping, ellipsizing or overflowing on narrow phones.
Widget _buttonContent(
  BuildContext context, {
  required String label,
  required TextStyle style,
  Widget? leading,
  double gap = 8,
  bool expand = true,
}) {
  return Center(
    // Shrink-wrap unless the button is meant to fill its slot.
    widthFactor: expand ? null : 1,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading, SizedBox(width: gap)],
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            textScaler: _buttonTextScaler(context),
            style: style,
          ),
        ],
      ),
    ),
  );
}

/// Primary CTA: accent gradient, near-black foreground, weight 800, h48, r14,
/// subtle accent shadow (spec §5).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.expand = true,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final fg = enabled ? DropTheme.onAccent : DropTheme.faint;
    final compact = isCompactWidth(context);
    final content = _buttonContent(
      expand: expand,
      context,
      leading: busy
          ? _spinner(fg)
          : (icon == null
                ? null
                : Icon(icon, size: compact ? 18 : 19, color: fg)),
      gap: compact ? 7 : 9,
      label: label,
      style: TextStyle(
        fontFamily: DropTheme.bodyFont,
        fontWeight: FontWeight.w800,
        fontSize: compact ? 13.5 : 14,
        letterSpacing: 0.1,
        color: fg,
      ),
    );
    return PressableScale(
      enabled: enabled,
      onTap: enabled ? onPressed : null,
      child: Container(
        height: compact ? 46 : 48,
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 18),
        decoration: BoxDecoration(
          gradient: enabled ? DropTheme.accentGradient : null,
          color: enabled ? null : DropTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(DropTheme.radiusButton),
          border: enabled ? null : Border.all(color: DropTheme.line),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: DropTheme.orange.withValues(alpha: 0.32),
                    blurRadius: 24,
                    spreadRadius: -8,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: content,
      ),
    );
  }
}

/// Tonal button: accent@16% fill, accent text, accent@30% border (spec §5).
class TonalButton extends StatelessWidget {
  const TonalButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.expand = false,
    this.color = DropTheme.orange,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final fg = enabled ? color : DropTheme.faint;
    final compact = isCompactWidth(context);
    final content = _buttonContent(
      expand: expand,
      context,
      leading: busy
          ? _spinner(fg)
          : (icon == null
                ? null
                : Icon(icon, size: compact ? 16 : 18, color: fg)),
      gap: compact ? 6 : 8,
      label: label,
      style: TextStyle(
        fontFamily: DropTheme.bodyFont,
        fontWeight: FontWeight.w800,
        fontSize: compact ? 13 : 13.5,
        color: fg,
      ),
    );
    Widget button = PressableScale(
      enabled: enabled,
      onTap: enabled ? onPressed : null,
      child: Container(
        height: compact ? 40 : 44,
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.16)
              : DropTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(DropTheme.radiusButton),
          border: Border.all(
            color: enabled ? color.withValues(alpha: 0.30) : DropTheme.line,
          ),
        ),
        child: content,
      ),
    );
    if (!expand) {
      // Trailing actions in list rows: never take more than a third of a
      // phone screen, so the title/description beside them keeps its room.
      button = ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: compact ? MediaQuery.sizeOf(context).width * 0.36 : 220,
        ),
        child: button,
      );
    }
    return button;
  }
}

/// Square icon button. [tonal] = accent@16% fill + accent icon; otherwise the
/// neutral surfaceHigh + 1px line + white icon (spec §5).
class DropIconButton extends StatelessWidget {
  const DropIconButton({
    required this.icon,
    required this.onPressed,
    this.tonal = false,
    this.color = DropTheme.orange,
    this.busy = false,
    this.tooltip,
    this.size,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool tonal;
  final Color color;
  final bool busy;
  final String? tooltip;

  /// Square side; defaults to 44 (40 on compact screens).
  final double? size;

  @override
  Widget build(BuildContext context) {
    final size = this.size ?? (isCompactWidth(context) ? 40.0 : 44.0);
    final enabled = onPressed != null && !busy;
    final iconColor = tonal
        ? (enabled ? color : DropTheme.faint)
        : (enabled ? DropTheme.white : DropTheme.faint);
    Widget button = PressableScale(
      enabled: enabled,
      onTap: enabled ? onPressed : null,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tonal ? color.withValues(alpha: 0.16) : DropTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(DropTheme.radiusIconButton),
          border: Border.all(
            color: tonal ? color.withValues(alpha: 0.30) : DropTheme.line,
          ),
        ),
        child: busy
            ? _spinner(iconColor)
            : Icon(icon, size: 20, color: iconColor),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// Segmented selector (Local/Global, Video/Audio…). With [expand] the
/// segments share the full width, which keeps labels on one line on phones.
class DropSegmented extends StatelessWidget {
  const DropSegmented({
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.icons,
    this.expand = false,
    super.key,
  });

  final List<String> labels;
  final List<IconData>? icons;
  final int selected;
  final ValueChanged<int> onSelected;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final compact = isCompactWidth(context);
    Widget segment(int index) {
      final active = index == selected;
      final fg = active ? DropTheme.orange : DropTheme.muted;
      final icon = icons?[index];
      return Semantics(
        button: true,
        selected: active,
        child: InkWell(
          onTap: () => onSelected(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: compact ? 38 : 40,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? DropTheme.orange.withValues(alpha: 0.18)
                  : Colors.transparent,
              border: active ? Border.all(color: DropTheme.orange) : null,
              borderRadius: BorderRadius.circular(DropTheme.radiusTile - 1),
            ),
            child: _buttonContent(
              context,
              leading: icon == null ? null : Icon(icon, size: 16, color: fg),
              gap: 6,
              label: labels[index],
              style: TextStyle(
                fontFamily: DropTheme.bodyFont,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                fontSize: compact ? 13 : 14,
                color: fg,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DropTheme.radiusTile),
        border: Border.all(color: DropTheme.line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DropTheme.radiusTile - 1),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            for (var i = 0; i < labels.length; i++)
              if (expand) Expanded(child: segment(i)) else segment(i),
          ],
        ),
      ),
    );
  }
}

// --- Tiles, pills, meters --------------------------------------------------

/// Rounded leading icon tile for list rows / headers. Defaults to surfaceHigh;
/// pass [accent] to tint, or [gradient] for the accent hero tile.
class LeadingTile extends StatelessWidget {
  const LeadingTile({
    required this.icon,
    this.accent,
    this.gradient = false,
    this.size = 42,
    super.key,
  });

  final IconData icon;
  final Color? accent;
  final bool gradient;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (gradient) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: DropTheme.accentGradient,
          borderRadius: BorderRadius.circular(size * 0.3),
          boxShadow: [
            BoxShadow(
              color: DropTheme.orange.withValues(alpha: 0.36),
              blurRadius: 18,
              spreadRadius: -6,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(icon, color: DropTheme.onAccent, size: size * 0.5),
      );
    }
    final tint = accent != null;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint ? accent!.withValues(alpha: 0.14) : DropTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(
          color: tint ? accent!.withValues(alpha: 0.30) : DropTheme.line,
        ),
      ),
      child: Icon(
        icon,
        color: tint ? accent : DropTheme.white,
        size: size * 0.48,
      ),
    );
  }
}

/// Status chip: icon + label, currentColor at 12% bg / 22% border (spec §5).
class DropPill extends StatelessWidget {
  const DropPill({
    required this.label,
    this.icon,
    this.color = DropTheme.muted,
    this.dot = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final Color color;

  /// Show a small (optionally pulsing) leading dot instead of an icon.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
          ] else if (icon != null) ...[
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontFamily: DropTheme.bodyFont,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Uppercase eyebrow / label (spec §3).
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {this.color = DropTheme.faint, super.key});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: DropTheme.bodyFont,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
        color: color,
      ),
    );
  }
}

/// Monospace text for IPs, URLs, /dav, versions and paths (spec §3).
class MonoText extends StatelessWidget {
  const MonoText(
    this.text, {
    this.color = DropTheme.white,
    this.size = 13,
    this.weight = FontWeight.w600,
    this.selectable = false,
    super.key,
  });

  final String text;
  final Color color;
  final double size;
  final FontWeight weight;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: DropTheme.monoFont,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: 0,
    );
    if (selectable) {
      return SelectableText(text, style: style);
    }
    return Text(text, style: style, overflow: TextOverflow.ellipsis);
  }
}

/// Big display number + small muted label (spec §5 stat block).
class StatBlock extends StatelessWidget {
  const StatBlock({
    required this.value,
    required this.label,
    this.icon,
    this.valueColor = DropTheme.white,
    this.mono = false,
    super.key,
  });

  final String value;
  final String label;
  final IconData? icon;
  final Color valueColor;

  /// Render the value in the monospace family (stable digits for timers).
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: DropTheme.faint),
          const SizedBox(height: 10),
        ],
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: mono ? DropTheme.monoFont : DropTheme.displayFont,
            fontSize: mono ? 21 : 26,
            fontWeight: FontWeight.w700,
            letterSpacing: mono ? 0 : -0.5,
            color: valueColor,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            fontFamily: DropTheme.bodyFont,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: DropTheme.muted,
          ),
        ),
      ],
    );
  }
}

/// The Erebrus Drop brand mark — the glossy 3D mark with a soft accent halo.
class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 46, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = size >= 28 ? DropTheme.logoFlat : DropTheme.logoFlat;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: DropTheme.orange.withValues(alpha: 0.30),
            blurRadius: size * 0.42,
            spreadRadius: -size * 0.12,
            offset: Offset(0, size * 0.18),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        asset,
        fit: BoxFit.cover,
        semanticLabel: 'Erebrus Drop logo',
      ),
    );
  }
}

/// "Erebrus Drop" wordmark — "Drop" in the accent colour (spec §1).
class Wordmark extends StatelessWidget {
  const Wordmark({this.size = 22, this.align = TextAlign.start, super.key});

  final double size;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontFamily: DropTheme.displayFont,
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      height: 1.0,
      color: DropTheme.white,
    );
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Erebrus '),
          TextSpan(
            text: 'Drop',
            style: const TextStyle(color: DropTheme.orange),
          ),
        ],
      ),
      textAlign: align,
      style: base,
    );
  }
}

/// Full brand lockup: mark + wordmark, with optional eyebrow and subtitle.
/// Horizontal by default; [centered] stacks it for splash/info surfaces.
class BrandLockup extends StatelessWidget {
  const BrandLockup({
    this.markSize = 46,
    this.wordmarkSize = 22,
    this.eyebrow,
    this.subtitle,
    this.centered = false,
    super.key,
  });

  final double markSize;
  final double wordmarkSize;
  final String? eyebrow;
  final String? subtitle;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final cross = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final align = centered ? TextAlign.center : TextAlign.start;
    final text = Column(
      crossAxisAlignment: cross,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow != null) ...[
          Eyebrow(eyebrow!),
          SizedBox(height: centered ? 10 : 6),
        ],
        Wordmark(size: wordmarkSize, align: align),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            textAlign: align,
            style: const TextStyle(
              fontFamily: DropTheme.bodyFont,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: DropTheme.muted,
            ),
          ),
        ],
      ],
    );
    if (centered) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrandMark(size: markSize),
          const SizedBox(height: 16),
          text,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        BrandMark(size: markSize),
        const SizedBox(width: 13),
        Flexible(child: text),
      ],
    );
  }
}

/// 3-bar signal meter for nearby rooms (spec §7 Rooms).
class SignalMeter extends StatelessWidget {
  const SignalMeter({this.bars = 3, this.color = DropTheme.success, super.key});

  /// Number of filled bars, 0-3.
  final int bars;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        final filled = i < bars;
        return Padding(
          padding: EdgeInsets.only(right: i == 2 ? 0 : 3),
          child: Container(
            width: 4,
            height: 7.0 + i * 4,
            decoration: BoxDecoration(
              color: filled ? color : DropTheme.lineStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}
