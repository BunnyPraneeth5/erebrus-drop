import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/theme/drop_theme.dart';
import 'desktop_mdns_service.dart';
import 'platform_capabilities.dart';

typedef DesktopQuitHandler = Future<void> Function();

class DesktopShell with WindowListener, TrayListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  static bool _initialized = false;
  DesktopQuitHandler? _onQuit;
  bool? _roomActive;

  static Future<void> ensureInitialized() async {
    if (!isDesktopPlatform || _initialized) {
      return;
    }
    await windowManager.ensureInitialized();
    await instance._configureWindow();
    await instance._configureTray();
    windowManager.addListener(instance);
    trayManager.addListener(instance);
    _initialized = true;
  }

  void registerQuitHandler(DesktopQuitHandler handler) {
    _onQuit = handler;
  }

  /// Keeps the tray glyph in sync with the room lifecycle. On macOS both
  /// states are template images, so the active glyph automatically becomes
  /// black or white with the menu bar while the inactive glyph stays muted.
  Future<void> setRoomActive(bool active) async {
    if (!isDesktopPlatform || _roomActive == active) {
      return;
    }
    await _applyTrayVisual(active);
    _roomActive = active;
  }

  Future<void> hideToTray() async {
    if (!isDesktopPlatform) {
      return;
    }
    if (Platform.isMacOS) {
      // Keep macOS in accessory-app mode so hiding the window cannot leave a
      // Dock icon behind. The menu bar item is the app's reopen affordance.
      await windowManager.setSkipTaskbar(true);
    }
    await windowManager.hide();
  }

  Future<void> showFromTray() async {
    if (!isDesktopPlatform) {
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (!isDesktopPlatform) {
      return;
    }
    final handler = _onQuit;
    if (handler != null) {
      await handler();
    }
    await DesktopMdnsService.instance.stopPublish();
    await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }

  Future<void> _configureWindow() async {
    final options = WindowOptions(
      size: const Size(880, 820),
      minimumSize: const Size(720, 640),
      center: true,
      skipTaskbar: Platform.isMacOS,
      title: 'Erebrus Drop',
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    await windowManager.setPreventClose(true);
  }

  Future<void> _configureTray() async {
    await _applyTrayVisual(false);
    _roomActive = false;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show Erebrus Drop'),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    );
  }

  Future<void> _applyTrayVisual(bool active) async {
    if (Platform.isMacOS) {
      await trayManager.setIcon(
        active
            ? DropTheme.trayIconTemplate
            : DropTheme.trayIconTemplateInactive,
        isTemplate: true,
        iconSize: 18,
      );
    } else {
      await trayManager.setIcon(
        active ? DropTheme.trayIcon : DropTheme.trayIconInactive,
      );
    }
    await trayManager.setToolTip(
      active ? 'Erebrus Drop — Room live' : 'Erebrus Drop — No active room',
    );
  }

  @override
  void onWindowClose() {
    unawaited(hideToTray());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showFromTray());
      case 'quit':
        unawaited(quit());
    }
  }
}
