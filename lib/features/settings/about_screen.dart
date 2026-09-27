import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../ui/theme/drop_theme.dart';
import '../../ui/widgets/drop_widgets.dart';
import 'privacy_screen.dart';
import 'terms_screen.dart';

/// About Erebrus Drop — brand, capabilities, and legal links.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About Erebrus Drop')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: DropTheme.accentGradient,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: DropTheme.heroGlow(DropTheme.orange),
                ),
                clipBehavior: Clip.antiAlias,
                child: const Image(
                  image: AssetImage(DropTheme.logoFlat),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Text(
                'Erebrus Drop',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text(
                'by NetSepio',
                style: TextStyle(color: DropTheme.muted),
              ),
            ),
            const SizedBox(height: 8),
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final version = snapshot.hasData
                    ? 'v${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                    : '';
                return Center(
                  child: Text(
                    version,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: DropTheme.faint),
                  ),
                );
              },
            ),
            const SizedBox(height: 28),
            const Eyebrow('OUR ETHOS'),
            const SizedBox(height: 10),
            DropCard(
              child: Text(
                'NetSepio builds privacy infrastructure for a decentralized web. '
                'Erebrus Drop is direct when nearby and decentralized when distance '
                'matters. Local Drop Rooms move content across your current network '
                'without passing through Erebrus services. Global Send is a separate, '
                'explicit action that uploads a file you choose to the Erebrus node '
                'you select. Grab runs entirely on your device, fetching public media '
                'straight from the source site with nothing routed through NetSepio.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 22),
            const Eyebrow('WHAT EREBRUS DROP CAN DO'),
            const SizedBox(height: 10),
            DropCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _Section('Nearby'),
                  _Bullet(
                    'Host a Drop Room over Wi-Fi or hotspot and share it by QR '
                    'code or Drop Link',
                  ),
                  _Bullet(
                    'Guests join from the app or any browser, with no install '
                    'needed',
                  ),
                  _Bullet(
                    'Move files, folders, text, and streamable media between '
                    'nearby devices',
                  ),
                  _Bullet(
                    'Protect rooms with a password, keep guests in one folder, '
                    'or let Burn Mode close the room after two hours',
                  ),
                  _Bullet('Connect WebDAV clients to a live room'),
                  _Bullet(
                    'Receive files, text, and links from other apps through the '
                    'share sheet',
                  ),
                  _Section('Global'),
                  _Bullet(
                    'Send files through public or organization Erebrus nodes '
                    'and share the link',
                  ),
                  _Bullet(
                    'Sign in with a Solana wallet, email, Google, or Apple, and '
                    'redeem a friend\'s invite code',
                  ),
                  _Section('Grab'),
                  _Bullet(
                    'Save videos, audio, and photos from public links on '
                    'YouTube, X, TikTok, Reddit, Bluesky, Vimeo, SoundCloud, '
                    'and direct media links',
                  ),
                  _Bullet(
                    'Choose video, audio (MP3 or original), or muted video, up '
                    'to 4K',
                  ),
                  _Section('Everywhere'),
                  _Bullet('Runs on Android, iOS, macOS, Windows, and Linux'),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Eyebrow('LEGAL'),
            const SizedBox(height: 10),
            DropCard(
              padding: EdgeInsets.zero,
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(DropTheme.radiusCard),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _LegalRow(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Privacy Policy',
                      subtitle: 'What we collect and what we never log',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const PrivacyScreen(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 58, endIndent: 16),
                    _LegalRow(
                      icon: Icons.description_outlined,
                      title: 'Terms of Use',
                      subtitle: 'Acceptable use, disclaimers, and beta notice',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const TermsScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            const Center(
              child: Text(
                'Erebrus © 2026 NetSepio LLC. All rights reserved.',
                textAlign: TextAlign.center,
                style: TextStyle(color: DropTheme.faint, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(color: DropTheme.orange),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '• ',
            style: TextStyle(color: DropTheme.orange, fontSize: 14),
          ),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _LegalRow extends StatelessWidget {
  const _LegalRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: DropTheme.muted, size: 22),
      title: Text(
        title,
        style: const TextStyle(
          color: DropTheme.white,
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: DropTheme.faint, fontSize: 12.5),
      ),
      trailing: const Icon(Icons.chevron_right, color: DropTheme.faint),
    );
  }
}
