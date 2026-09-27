import 'dart:async';

import 'package:erebrus_drop/app.dart';
import 'package:erebrus_drop/features/gateway/gateway_sheets.dart';
import 'package:erebrus_drop/features/onboarding/onboarding_screen.dart';
import 'package:erebrus_drop/features/settings/about_screen.dart';
import 'package:erebrus_drop/ui/theme/drop_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _pumpDialogFrames(WidgetTester tester, {int count = 20}) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: 'Dialog frame $frame');
  }
}

Future<void> _mountDialogHarness(
  WidgetTester tester,
  Future<void> Function(BuildContext) open,
) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: DropTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => unawaited(open(context)),
            child: const Text('Open test dialog'),
          ),
        ),
      ),
    ),
  );
  expect(tester.takeException(), isNull);
}

Future<TextEditingController> _openTestDialog(WidgetTester tester) async {
  await tester.tap(find.text('Open test dialog'));
  await tester.pump();
  expect(tester.takeException(), isNull);
  await _pumpDialogFrames(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
  expect(_dialogField, findsOneWidget);
  return tester.widget<TextField>(_dialogField).controller!;
}

Future<void> _editDialog(WidgetTester tester, String text) async {
  await tester.enterText(_dialogField, text);
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void _expectButtonEnabled(WidgetTester tester, String text, bool enabled) {
  final button = tester.widget<ButtonStyleButton>(
    find.ancestor(
      of: find.text(text),
      matching: find.bySubtype<ButtonStyleButton>(),
    ),
  );
  expect(button.onPressed, enabled ? isNotNull : isNull);
}

Future<void> _dismissTestDialog(WidgetTester tester, String exit) async {
  if (exit == 'back') {
    await tester.binding.handlePopRoute();
  } else if (exit == 'barrier') {
    await tester.tapAt(const Offset(5, 5));
  } else {
    await tester.tap(find.text(exit));
  }
}

Future<void> _finishDialogDismissal(
  WidgetTester tester,
  TextEditingController controller,
) async {
  final fieldElement = tester.element(_dialogField);
  final editableElement = tester.element(
    find.descendant(of: _dialogField, matching: find.byType(EditableText)),
  );
  final route = ModalRoute.of(fieldElement)!;
  await tester.pump();
  expect(tester.takeException(), isNull);
  expect(route.isCurrent, isFalse);
  expect(fieldElement.mounted, isTrue);
  expect(find.byType(AlertDialog), findsOneWidget);
  tester.view.viewInsets = const FakeViewPadding(bottom: 48);
  fieldElement.markNeedsBuild();
  editableElement.markNeedsBuild();
  await _pumpDialogFrames(tester, count: 1);
  expect(fieldElement.mounted, isTrue);
  void listener() {}
  expect(() => controller.addListener(listener), returnsNormally);
  controller.removeListener(listener);
  await _pumpDialogFrames(tester);
  expect(fieldElement.mounted, isFalse);
  expect(find.byType(AlertDialog), findsNothing);
  expect(() => controller.addListener(listener), throwsFlutterError);
  tester.view.resetViewInsets();
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final clipboardUrl in <String?>[null, 'https://clipboard.example']) {
    for (final exit in ['Cancel', 'back', 'barrier', 'Add to composer']) {
      testWidgets('link dialog $exit with clipboard $clipboardUrl', (
        tester,
      ) async {
        final results = <String?>[];
        await _mountDialogHarness(tester, (context) async {
          results.add(
            await showAddLinkDialog(context, clipboardUrl: clipboardUrl),
          );
        });
        TextEditingController? previous;
        for (var repeat = 0; repeat < 2; repeat++) {
          final controller = await _openTestDialog(tester);
          expect(find.text('Send a link'), findsOneWidget);
          expect(controller, isNot(same(previous)));
          expect(controller.text, clipboardUrl ?? '');
          _expectButtonEnabled(
            tester,
            'Paste from clipboard',
            clipboardUrl != null,
          );
          _expectButtonEnabled(tester, 'Add to composer', clipboardUrl != null);
          await _editDialog(tester, '   ');
          _expectButtonEnabled(tester, 'Add to composer', false);
          if (clipboardUrl != null) {
            await tester.tap(find.text('Paste from clipboard'));
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(controller.text, clipboardUrl);
            _expectButtonEnabled(tester, 'Add to composer', true);
          }
          await _editDialog(tester, '  https://edited.example/path  ');
          _expectButtonEnabled(tester, 'Add to composer', true);
          await _dismissTestDialog(tester, exit);
          await _finishDialogDismissal(tester, controller);
          expect(results.length, repeat + 1);
          expect(
            results.last,
            exit == 'Add to composer' ? 'https://edited.example/path' : isNull,
          );
          previous = controller;
        }
      });
    }
  }

  for (final exit in [
    'Cancel',
    'back',
    'barrier',
    'Download',
    'empty Download',
  ]) {
    testWidgets(
      'encryption dialog $exit preserves result and controller lifetime',
      (tester) async {
        final results = <String?>[];
        await _mountDialogHarness(tester, (context) async {
          results.add(
            await showEncryptionKeyDialog(
              context,
              filename: 'secret.bin',
              loadKeyFile: () async => null,
            ),
          );
        });
        TextEditingController? previous;
        for (var repeat = 0; repeat < 2; repeat++) {
          final controller = await _openTestDialog(tester);
          expect(find.text('Decryption key for secret.bin'), findsOneWidget);
          expect(controller, isNot(same(previous)));
          expect(controller.text, isEmpty);
          expect(tester.widget<TextField>(_dialogField).obscureText, isTrue);
          await _editDialog(
            tester,
            exit == 'empty Download' ? '   ' : '  typed key  ',
          );
          if (exit == 'barrier') {
            await _dismissTestDialog(tester, 'barrier');
            await _pumpDialogFrames(tester);
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(
              ModalRoute.of(tester.element(_dialogField))!.isCurrent,
              isTrue,
            );
            expect(controller.text, '  typed key  ');
            expect(results.length, repeat);
            await _dismissTestDialog(tester, 'Cancel');
          } else {
            await _dismissTestDialog(
              tester,
              exit == 'empty Download' ? 'Download' : exit,
            );
          }
          await _finishDialogDismissal(tester, controller);
          expect(results.length, repeat + 1);
          expect(
            results.last,
            exit == 'back' || exit == 'Download' ? 'typed key' : isNull,
          );
          previous = controller;
        }
      },
    );
  }

  const presets = [
    'https://ipfs.erebrus.io',
    'https://cloudflare-ipfs.com',
    'https://gateway.pinata.cloud',
    'https://ipfs.io',
  ];
  for (final initialUrl in [...presets, 'https://custom.example', '']) {
    for (final exit in [
      'Cancel',
      'back',
      'barrier',
      'Save custom',
      'Save preset',
    ]) {
      testWidgets('IPFS dialog $exit from "$initialUrl"', (tester) async {
        final saves = <String>[];
        var completions = 0;
        ModalRoute<dynamic>? dialogRoute;
        await _mountDialogHarness(tester, (context) async {
          await showIpfsGatewayPickerDialog(
            context,
            initialUrl: initialUrl,
            onSave: (url) async {
              expect(dialogRoute!.isCurrent, isFalse);
              saves.add(url);
            },
          );
          completions++;
        });
        TextEditingController? previous;
        for (var repeat = 0; repeat < 2; repeat++) {
          final controller = await _openTestDialog(tester);
          dialogRoute = ModalRoute.of(tester.element(_dialogField));
          expect(find.text('IPFS Gateway'), findsOneWidget);
          expect(controller, isNot(same(previous)));
          expect(
            controller.text,
            presets.contains(initialUrl) ? '' : initialUrl,
          );
          expect(
            tester.widget<TextField>(_dialogField).enabled,
            !presets.contains(initialUrl),
          );
          _expectButtonEnabled(tester, 'Save', initialUrl.isNotEmpty);
          for (final preset in presets) {
            expect(find.text(preset), findsOneWidget);
          }
          await tester.tap(find.text('Custom'));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(tester.widget<TextField>(_dialogField).enabled, isTrue);
          await _editDialog(tester, '   ');
          _expectButtonEnabled(tester, 'Save', false);
          await _editDialog(tester, '  https://edited-gateway.example  ');
          _expectButtonEnabled(tester, 'Save', true);
          for (final preset in presets) {
            await tester.tap(find.text(preset));
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(controller.text, isEmpty);
            expect(tester.widget<TextField>(_dialogField).enabled, isFalse);
            _expectButtonEnabled(tester, 'Save', true);
            await tester.tap(find.text('Custom'));
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(tester.widget<TextField>(_dialogField).enabled, isTrue);
            _expectButtonEnabled(tester, 'Save', false);
            await _editDialog(tester, '  https://edited-gateway.example  ');
          }
          if (exit == 'Save preset') {
            await tester.tap(
              find.text(
                initialUrl.isNotEmpty && presets.contains(initialUrl)
                    ? initialUrl
                    : presets[repeat],
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
          }
          await _dismissTestDialog(
            tester,
            exit.startsWith('Save') ? 'Save' : exit,
          );
          await _finishDialogDismissal(tester, controller);
          expect(completions, repeat + 1);
          if (exit.startsWith('Save')) {
            expect(saves.length, repeat + 1);
            expect(
              saves.last,
              exit == 'Save custom'
                  ? 'https://edited-gateway.example'
                  : presets.contains(initialUrl)
                  ? initialUrl
                  : presets[repeat],
            );
          } else {
            expect(saves, isEmpty);
          }
          previous = controller;
        }
      });
    }
  }

  for (final outcome in ['success', 'cancel', 'error']) {
    testWidgets('key file $outcome while encryption dialog is mounted', (
      tester,
    ) async {
      late Completer<String?> pending;
      var calls = 0;
      final results = <String?>[];
      await _mountDialogHarness(tester, (context) async {
        results.add(
          await showEncryptionKeyDialog(
            context,
            filename: 'loaded.bin',
            loadKeyFile: () {
              calls++;
              return pending.future;
            },
          ),
        );
      });
      TextEditingController? previous;
      for (var repeat = 0; repeat < 2; repeat++) {
        pending = Completer<String?>();
        final controller = await _openTestDialog(tester);
        expect(controller, isNot(same(previous)));
        expect(controller.text, isEmpty);
        await _editDialog(tester, '  original key  ');
        await tester.tap(find.text('Load key file'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(calls, repeat + 1);
        expect(controller.text, '  original key  ');
        expect(results.length, repeat);
        if (outcome == 'error') {
          pending.completeError(StateError('key read failed'));
        } else {
          pending.complete(outcome == 'success' ? ' \n loaded key \n ' : null);
        }
        await tester.pump();
        expect(tester.takeException(), isNull);
        await _pumpDialogFrames(tester);
        expect(
          controller.text,
          outcome == 'success' ? 'loaded key' : '  original key  ',
        );
        if (outcome == 'error') {
          expect(find.byType(SnackBar), findsOneWidget);
          expect(
            find.textContaining('Could not read key file:'),
            findsOneWidget,
          );
          expect(find.textContaining('key read failed'), findsOneWidget);
          ScaffoldMessenger.of(
            tester.element(_dialogField),
          ).removeCurrentSnackBar();
          await tester.pump();
          expect(tester.takeException(), isNull);
        } else {
          expect(find.byType(SnackBar), findsNothing);
        }
        await _dismissTestDialog(tester, 'Download');
        await _finishDialogDismissal(tester, controller);
        expect(
          results.last,
          outcome == 'success' ? 'loaded key' : 'original key',
        );
        previous = controller;
      }
    });

    for (final reopenBeforeCompletion in [false, true]) {
      testWidgets(
        'late key file $outcome after disposal, next dialog open: $reopenBeforeCompletion',
        (tester) async {
          late Completer<String?> pending;
          final results = <String?>[];
          await _mountDialogHarness(tester, (context) async {
            results.add(
              await showEncryptionKeyDialog(
                context,
                filename: 'late.bin',
                loadKeyFile: () => pending.future,
              ),
            );
          });
          for (var repeat = 0; repeat < 2; repeat++) {
            pending = Completer<String?>();
            final oldController = await _openTestDialog(tester);
            expect(oldController.text, isEmpty);
            await _editDialog(tester, 'old key');
            await tester.tap(find.text('Load key file'));
            await tester.pump();
            expect(tester.takeException(), isNull);
            await _dismissTestDialog(tester, 'Cancel');
            await _finishDialogDismissal(tester, oldController);
            expect(results.last, isNull);
            TextEditingController? newController;
            if (reopenBeforeCompletion) {
              newController = await _openTestDialog(tester);
              expect(newController, isNot(same(oldController)));
              expect(newController.text, isEmpty);
              await _editDialog(tester, '  next key  ');
            }
            if (outcome == 'error') {
              pending.completeError(StateError('late read failure'));
            } else {
              pending.complete(
                outcome == 'success' ? '  stale loaded key  ' : null,
              );
            }
            await tester.pump();
            expect(tester.takeException(), isNull);
            await _pumpDialogFrames(tester);
            expect(find.byType(SnackBar), findsNothing);
            if (!reopenBeforeCompletion) {
              expect(find.byType(AlertDialog), findsNothing);
              newController = await _openTestDialog(tester);
              expect(newController, isNot(same(oldController)));
              expect(newController.text, isEmpty);
              await _editDialog(tester, '  next key  ');
            }
            expect(newController!.text, '  next key  ');
            await _dismissTestDialog(tester, 'Download');
            await _finishDialogDismissal(tester, newController);
            expect(
              results,
              List<String?>.generate(
                (repeat + 1) * 2,
                (index) => index.isEven ? null : 'next key',
              ),
            );
          }
        },
      );
    }
  }

  testWidgets('onboarding adapts to landscape Android screens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(872, 393));
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: OnboardingScreen(onComplete: () async {}),
      ),
    );
    await tester.pump();

    expect(find.text('Create a private Drop Room'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(find.text('Guests can join from browser'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(find.text('Local-first by default.'), findsOneWidget);
    expect(
      find.text('Direct nearby. Decentralized when distance matters.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows Erebrus Drop home actions', (tester) async {
    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();

    expect(find.text('Erebrus Drop', findRichText: true), findsWidgets);
    expect(find.text('Start Drop Room'), findsOneWidget);
    expect(find.text('Join Drop Room'), findsOneWidget);
    expect(find.text('Send'), findsWidgets);
  });

  testWidgets('large desktop exposes rail status and split workspaces', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();

    expect(find.text('IDLE'), findsOneWidget);
    expect(
      find.text('Direct nearby. Decentralized when distance matters.'),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pump();
    expect(find.text('Select a file or folder'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pump();
    expect(find.text('Add files'), findsOneWidget);
    expect(find.text('Send a link'), findsOneWidget);
    expect(find.text('Share Sheet'), findsNothing);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('about legal rows paint on their own material surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: DropTheme.dark(), home: const AboutScreen()),
    );
    await tester.pump();

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
    expect(find.textContaining('direct when nearby'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign-out confirmation supports cancel and confirm', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: DropTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await confirmGatewaySignOut(context);
              },
              child: const Text('Open sign-out dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open sign-out dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('Open sign-out dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out').last);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('renders primary tabs across common Android screen sizes', (
    tester,
  ) async {
    final sizes = <Size>[
      const Size(360, 640),
      const Size(360, 780),
      const Size(393, 851),
      const Size(640, 360),
      const Size(872, 393),
      const Size(800, 1280),
    ];

    for (final size in sizes) {
      await tester.binding.setSurfaceSize(size);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        return tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
      await tester.pump();
      expect(tester.takeException(), isNull);

      for (final icon in const [
        Icons.hub_outlined,
        Icons.folder_outlined,
        Icons.bolt_outlined,
        Icons.download_for_offline_outlined,
        Icons.home_outlined,
      ]) {
        await tester.tap(find.byIcon(icon).last);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }

      // Settings lives behind the Home header gear on phones.
      await tester.tap(find.byIcon(Icons.settings_outlined).last);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsWidgets);
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Start Drop Room'), findsOneWidget);
    }
  });

  testWidgets('small phones with large text keep every tab overflow-free', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      return tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final icon in const [
      Icons.hub_outlined,
      Icons.folder_outlined,
      Icons.bolt_outlined,
      Icons.download_for_offline_outlined,
      Icons.home_outlined,
      Icons.settings_outlined,
    ]) {
      await tester.tap(find.byIcon(icon).last);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'overflow on $icon');
    }
  });

  testWidgets('shows hotspot guide when no Wi-Fi or hotspot is available', (
    tester,
  ) async {
    const channel = MethodChannel('com.erebrus.drop/network');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'getCurrentNetworkStatus') {
        return {'mode': 'unavailable', 'address': null, 'interface': null};
      }
      if (call.method == 'getDeviceName') {
        return 'Test Phone';
      }
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });

    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();

    await tester.tap(find.text('Start Drop Room'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Create a hotspot first'), findsOneWidget);
    expect(find.text('Hotspot Guide'), findsOneWidget);
    expect(find.text('Create Local Hotspot'), findsNothing);
    expect(find.text('Stop Hotspot'), findsNothing);
  });

  testWidgets('shows drop QR dialog on compact Android screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DropCodeDialog(
              link: 'http://192.168.1.24:8787',
              onCopy: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Drop Code'), findsOneWidget);
    expect(find.text('http://192.168.1.24:8787'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Send a link opens a dialog and adds a URL to the composer', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'https://example.com'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.binding.setSurfaceSize(const Size(393, 851));
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(const ErebrusDropApp(skipOnboarding: true));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.bolt_outlined));
    await tester.pump();
    expect(find.text('Add files'), findsOneWidget);
    expect(find.text('Send a link'), findsOneWidget);
    expect(find.text('Share Sheet'), findsNothing);

    await tester.tap(find.text('Send a link'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AlertDialog), findsOneWidget);

    final urlField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(urlField, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('https://example.com'),
      ),
      findsOneWidget,
    );

    await tester.enterText(urlField, 'https://example.org');
    await tester.pump();

    await tester.tap(find.text('Add to composer'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('https://example.org'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
}
