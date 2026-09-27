import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../ui/widgets/drop_widgets.dart';

const String _supportEmail = 'support@netsepio.com';

/// Privacy policy screen.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AppLogoLockup(compact: true),
            const SizedBox(height: 18),
            const _TextCard(
              text:
                  'Erebrus Drop does not collect analytics, advertising identifiers, contact lists, or location history. Local Drop Room contents, passwords, and links are not sent to Erebrus services.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'Erebrus Drop has three distinct paths. Local Drop Rooms transfer directly between devices on your Wi-Fi or hotspot. Global Send uploads only the file you explicitly choose to the selected Erebrus node. Grab downloads public media you ask for straight from the site that hosts it.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'Global features necessarily process your sign-in session, selected organization or node, and uploaded file. The Library shows each global file’s public or private and encrypted status when that information is available.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'When you use Grab, your device connects directly to the site behind the link, such as YouTube or TikTok. That site sees your IP address and ordinary request details, just as it would if you opened the link in a browser, and its own privacy policy applies. Links you grab and the files you save are never sent to NetSepio or Erebrus services, all processing happens on your device, and Grab never asks for your account on those sites.',
            ),
            const SizedBox(height: 8),
            const _TextCard(
              text:
                  'Permissions are feature-scoped: camera for QR scans, local network access for Drop Rooms, clipboard access only when you tap paste, and file or folder access for uploads, downloads, and grabbed media. You control when those features are used.',
            ),
            const SizedBox(height: 8),
            _TextCard(text: 'For privacy questions, contact $_supportEmail.'),
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
