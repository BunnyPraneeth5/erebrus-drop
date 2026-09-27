import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../ui/widgets/drop_widgets.dart';

const String _supportEmail = 'support@netsepio.com';

/// Terms of use screen.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AppLogoLockup(compact: true),
            const SizedBox(height: 18),
            const _TextCard(
              text:
                  'Erebrus Drop provides direct nearby Drop Rooms, optional Global Send through Erebrus nodes, and Grab for saving public media from links. Use these features only for files and content you own or have permission to share or download.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'You are responsible for who joins your Drop Room, the network you use, and the files or text you send. Keep room passwords and Drop Links private when sharing sensitive content.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'Grab only works with media that is publicly available without signing in, and it does not bypass DRM or other access controls. You alone are responsible for making sure you have the right to download and use what you grab, including complying with copyright law and the terms of the site that hosts it. NetSepio does not host, store, or review grabbed content, and sites can change or block access at any time, so Grab may stop working for a site without notice.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'The app is provided as-is. Local transfers depend on your devices and network conditions. Global transfers additionally depend on the selected node, gateway availability, and the access or encryption status shown for the file.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'To the fullest extent permitted by law, you agree to indemnify and hold NetSepio harmless from claims, losses, damages, liabilities, and expenses arising from your use of Erebrus Drop, the content you share or download, or your violation of these terms or applicable law.',
            ),
            const SizedBox(height: 8),
            _TextCard(
              text:
                  'Erebrus Platform, brand, and apps are products of NetSepio. For support, contact $_supportEmail.',
            ),
          ],
        ),
      ),
    );
  }
}

class _AppLogoLockup extends StatelessWidget {
  const _AppLogoLockup({this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final version = snapshot.hasData
            ? 'v${snapshot.data!.version} (${snapshot.data!.buildNumber})'
            : '';
        return Center(
          child: BrandLockup(
            centered: true,
            markSize: compact ? 76 : 96,
            wordmarkSize: compact ? 26 : 30,
            subtitle: version,
          ),
        );
      },
    );
  }
}

class _TextCard extends StatelessWidget {
  const _TextCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return DropCard(
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
