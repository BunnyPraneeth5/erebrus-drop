import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/desktop_shell.dart';
import 'core/drop_models.dart';
import 'core/host_folder_bridge.dart';
import 'core/platform_capabilities.dart';
import 'core/platform_network.dart';
import 'features/gateway/drop_auth_service.dart';
import 'features/gateway/gateway_config.dart';
import 'features/gateway/gateway_http.dart';
import 'features/gateway/gateway_models.dart';
import 'features/gateway/gateway_sheets.dart';
import 'features/gateway/login_screen.dart';
import 'features/host/host_folder_service.dart';
import 'features/host/room_runtime_service.dart';
import 'features/join/join_room_service.dart';
import 'features/join/native_file_picker_service.dart';
import 'features/join/qr_scan_screen.dart';
import 'features/nearby/nearby_room_service.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/onboarding_store.dart';
import 'features/settings/about_screen.dart';
import 'features/smart_send/share_intake_service.dart';
import 'features/wallet/solana_wallet_service.dart';
import 'server/drop_server.dart';
import 'ui/layout/desktop_layout.dart';
import 'ui/theme/drop_theme.dart';
import 'ui/widgets/drop_widgets.dart';

const String _appVersion = '1.0.8+8';

class ErebrusDropApp extends StatefulWidget {
  const ErebrusDropApp({this.skipOnboarding = false, super.key});

  final bool skipOnboarding;

  @override
  State<ErebrusDropApp> createState() => _ErebrusDropAppState();
}

class _ErebrusDropAppState extends State<ErebrusDropApp> {
  final OnboardingStore _onboardingStore = OnboardingStore();
  late final Future<bool> _onboardingComplete = _onboardingStore.isComplete();
  bool _completedThisRun = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Erebrus Drop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: DropTheme.dark(),
      home: widget.skipOnboarding
          ? const DropHomeScreen()
          : FutureBuilder<bool>(
              future: _onboardingComplete,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const _BootScreen();
                }
                final complete = snapshot.data == true || _completedThisRun;
                if (complete) {
                  return const DropHomeScreen();
                }
                return OnboardingScreen(
                  onComplete: () async {
                    await _onboardingStore.markComplete();
                    if (mounted) {
                      setState(() => _completedThisRun = true);
                    }
                  },
                );
              },
            ),
    );
  }
}

/// Branded boot screen shown for the instant between the native splash and the
/// first real screen — visually identical to the native splash (glossy mark on
/// the brand near-black) so the handoff is seamless.
class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: DropTheme.black,
      body: Center(
        child: SizedBox(
          width: 176,
          height: 176,
          child: Image(image: AssetImage(DropTheme.logoFlat)),
        ),
      ),
    );
  }
}

class DropHomeScreen extends StatefulWidget {
  const DropHomeScreen({super.key});

  @override
  State<DropHomeScreen> createState() => _DropHomeScreenState();
}

class _DropHomeScreenState extends State<DropHomeScreen>
    with WidgetsBindingObserver {
  final DropServer _server = DropServer();
  final HostFolderService _hostFolderService = HostFolderService();
  final RoomRuntimeService _roomRuntimeService = RoomRuntimeService();
  final JoinRoomService _joinRoomService = JoinRoomService();
  final ShareIntakeService _shareIntakeService = ShareIntakeService();
  late final NearbyRoomService _nearbyRoomService = NearbyRoomService(
    joinRoomService: _joinRoomService,
  );
  final NativeFilePickerService _nativeFilePickerService =
      NativeFilePickerService();
  final HostFolderBridge _hostFolderBridge = HostFolderBridge();
  final SolanaWalletService _solanaWalletService = SolanaWalletService();
  late final DropAuthService _dropAuthService = DropAuthService(
    solana: _solanaWalletService,
  );
  final ValueNotifier<int> _networkUiVersion = ValueNotifier<int>(0);

  // Gateway / org state
  List<DropNode> _gatewayNodes = const [];
  List<DropGatewayFile> _gatewayFiles = const [];
  bool _gatewayNodesLoading = false;
  bool _gatewayFilesLoading = false;
  String? _gatewayError;
  DropNode? _selectedSendNode;
  bool _gatewayUploading = false;
  String? _gatewayUploadedCid;
  String _ipfsGatewayUrl = resolveIpfsGatewayUrl();
  int _libraryScopeIndex = 0; // 0 Local, 1 Global
  int _smartSendScopeIndex = 0; // 0 Local, 1 Global
  DropFileItem? _selectedLocalFile;
  DropGatewayFile? _selectedGlobalFile;
  bool _draggingFiles = false;
  final ValueNotifier<int> _joinUiVersion = ValueNotifier<int>(0);
  final TextEditingController _roomName = TextEditingController(
    text: _defaultRoomName(),
  );
  final TextEditingController _deviceName = TextEditingController(
    text: Platform.localHostname,
  );
  final TextEditingController _password = TextEditingController();
  final TextEditingController _smartText = TextEditingController();
  final TextEditingController _smartTitle = TextEditingController(
    text: 'Quick text',
  );
  final TextEditingController _joinUrl = TextEditingController();
  final TextEditingController _joinPassword = TextEditingController();
  final TextEditingController _joinFolderName = TextEditingController();
  final TextEditingController _joinTextTitle = TextEditingController(
    text: 'Native text',
  );
  final TextEditingController _joinTextBody = TextEditingController();
  final TextEditingController _referralCode = TextEditingController();
  bool _redeemingReferral = false;
  bool _stoppingRoom = false;

  final String _defaultUploadPath = '/';
  int _tab = 0;
  bool _starting = false;
  bool _hostFolderBusy = false;
  bool _loadingHostFolderSelection = true;
  bool _networkLoading = true;
  bool _loadingLibraryFiles = false;
  bool _appInForeground = true;
  bool _refreshingRoomData = false;
  bool _backDialogOpen = false;
  bool _joining = false;
  bool _discoveringRooms = false;
  bool _usePassword = true;
  bool _burnMode = false;
  RoomPermission _permission = RoomPermission.dropFolderOnly;
  StorageSnapshot? _storage;
  DropNetworkStatus _networkStatus = const DropNetworkStatus(
    mode: DropNetworkMode.unavailable,
  );
  HostFolderSelection? _hostFolderSelection;
  JoinRoomPreview? _joinPreview;
  JoinRoomSession? _joinSession;
  List<JoinRoomPreview> _foundJoinRooms = <JoinRoomPreview>[];
  String _libraryPath = '/';
  String _joinPath = '/';
  List<DropFileItem> _joinItems = <DropFileItem>[];
  String? _joinActivity;
  String? _nearbyDiscoveryMessage;
  TransferProgress? _joinTransfer;
  String? _libraryError;
  List<DropFileItem> _files = <DropFileItem>[];
  Timer? _refreshTimer;
  StreamSubscription<SharedPayload>? _shareSubscription;
  DateTime _lastNearbyDiscovery = DateTime.fromMillisecondsSinceEpoch(0);

  DropRoomSession? get _session => _server.session;

  static const String _kIpfsGatewayUrlPref = 'ipfs_gateway_url';

  static String _defaultRoomName() {
    final suffix = 1000 + math.Random.secure().nextInt(9000);
    return 'ErebrusDrop$suffix';
  }

  Future<void> _loadIpfsGatewayUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kIpfsGatewayUrlPref);
      final url = saved != null && saved.trim().isNotEmpty
          ? saved.trim()
          : resolveIpfsGatewayUrl();
      _ipfsGatewayUrl = url;
      _dropAuthService.gatewayClient.ipfsGatewayUrl = url;
    } catch (_) {
      // Leave the default/dart-define value in place.
    }
  }

  Future<void> _saveIpfsGatewayUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url.trim().isEmpty || url.trim() == resolveIpfsGatewayUrl()) {
      await prefs.remove(_kIpfsGatewayUrlPref);
    } else {
      await prefs.setString(_kIpfsGatewayUrlPref, url.trim());
    }
    setState(() => _ipfsGatewayUrl = url.trim());
    _dropAuthService.gatewayClient.ipfsGatewayUrl = url.trim();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _server.onSessionExpired = _handleRoomExpired;
    _syncWithExistingSession();
    unawaited(_loadDeviceName());
    unawaited(_loadHostFolderSelection());
    unawaited(_refreshNetworkStatus());
    unawaited(_loadIpfsGatewayUrl());
    unawaited(_loadGatewaySession());
    _dropAuthService.selectedOrg.addListener(_onSelectedOrgChanged);
    _dropAuthService.signedIn.addListener(_onGatewayAuthChanged);
    _shareSubscription = _shareIntakeService.watchIncomingShares().listen(
      (payload) => unawaited(_handleSharedPayload(payload)),
    );
    if (isDesktopPlatform) {
      DesktopShell.instance.registerQuitHandler(_desktopQuit);
      _syncDesktopTray();
    }
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_server.isRunning && _server.isExpired) {
        _handleRoomExpired();
        return;
      }
      if (_server.isRunning && _appInForeground) {
        unawaited(_refreshRoomData());
      }
      if (_tab == 1 && _appInForeground && !_discoveringRooms) {
        final now = DateTime.now();
        if (now.difference(_lastNearbyDiscovery) >=
            const Duration(seconds: 10)) {
          unawaited(_discoverNearbyRooms(silent: true));
        }
      }
    });
  }

  void _syncWithExistingSession() {
    final session = _server.session;
    if (session != null) {
      _roomName.text = session.name;
      _deviceName.text = session.deviceName;
      if (session.usesExternalHostFolder) {
        _hostFolderSelection = HostFolderSelection(
          uri: session.hostFolderUri!,
          name: session.hostFolderName ?? 'Selected folder',
          platform: session.hostFolderPlatform ?? 'Android SAF',
        );
      }
      unawaited(_refreshRoomData());
    }
  }

  void _syncDesktopTray() {
    if (!isDesktopPlatform) return;
    unawaited(
      DesktopShell.instance.setRoomActive(_server.isRunning).catchError((_) {}),
    );
  }

  Future<void> _loadGatewaySession() async {
    await _dropAuthService.loadSession();
    await _refreshGatewayNodes();
    if (mounted) {
      await _refreshGatewayFiles();
    }
  }

  void _onSelectedOrgChanged() {
    if (!_dropAuthService.isSignedIn || !mounted) return;
    unawaited(_refreshGatewayNodes());
    unawaited(_refreshGatewayFiles());
  }

  void _onGatewayAuthChanged() {
    if (!mounted) return;
    if (!_dropAuthService.isSignedIn) {
      setState(() {
        _gatewayNodes = const [];
        _gatewayFiles = const [];
        _selectedSendNode = null;
      });
      if (_dropAuthService.error.value ==
          'Your session expired. Please sign in again.') {
        _snack('Your session expired. Please sign in again.');
      }
    } else {
      setState(() {});
    }
  }

  Future<void> _revalidateGatewaySession() async {
    await _dropAuthService.revalidateSession();
    if (!mounted || !_dropAuthService.isSignedIn) return;
    await _refreshGatewayFiles();
  }

  Future<void> _refreshGatewayNodes() async {
    if (!_dropAuthService.isSignedIn || _gatewayNodesLoading) return;
    if (mounted) setState(() => _gatewayNodesLoading = true);
    _gatewayError = null;
    try {
      final public = await _dropAuthService.gatewayClient.fetchDropNodes(
        scope: 'public',
      );
      final org = _dropAuthService.selectedOrg.value;
      final private = org != null
          ? await _dropAuthService.gatewayClient.fetchDropNodes(
              scope: 'private',
              orgId: org.id,
            )
          : const <DropNode>[];
      final seen = <String>{};
      final nodes = <DropNode>[...public, ...private].where((n) {
        if (!n.online) return false;
        if (seen.contains(n.nodeId)) return false;
        return seen.add(n.nodeId);
      }).toList();
      if (mounted) {
        setState(() {
          _gatewayNodes = nodes;
          if (_selectedSendNode == null && nodes.isNotEmpty) {
            _selectedSendNode = nodes.firstWhere(
              (n) => n.acceptingUploads,
              orElse: () => nodes.first,
            );
          }
          _gatewayError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _gatewayError = e.toString());
    } finally {
      if (mounted) setState(() => _gatewayNodesLoading = false);
    }
  }

  Future<void> _showGatewayLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GatewayLoginScreen(auth: _dropAuthService),
      ),
    );
    if (!mounted) return;
    if (_dropAuthService.isSignedIn) {
      _snack('Signed in to Erebrus');
      setState(() => _tab = 2);
      await _refreshGatewayNodes();
      if (mounted) await _refreshGatewayFiles();
    }
  }

  Future<void> _refreshGatewayFiles() async {
    if (!_dropAuthService.isSignedIn || _gatewayFilesLoading) return;
    if (mounted) setState(() => _gatewayFilesLoading = true);
    try {
      final myFiles = await _dropAuthService.gatewayClient.fetchMyFiles();
      final org = _dropAuthService.selectedOrg.value;
      final orgFiles = org != null
          ? await _dropAuthService.gatewayClient.fetchOrgFiles(org.id)
          : const <DropGatewayFile>[];
      final seen = <String>{};
      final files = <DropGatewayFile>[...myFiles, ...orgFiles].where((f) {
        if (seen.contains(f.id)) return false;
        return seen.add(f.id);
      }).toList();
      files.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _gatewayFiles = files);
    } catch (e) {
      if (mounted) setState(() => _gatewayError = e.toString());
    } finally {
      if (mounted) setState(() => _gatewayFilesLoading = false);
    }
  }

  Future<void> _loadDeviceName() async {
    if (_server.isRunning) return;
    final fallback = Platform.localHostname;
    final deviceName = await PlatformNetwork.deviceName();
    if (!mounted || deviceName.isEmpty) return;
    if (_deviceName.text.trim().isEmpty || _deviceName.text == fallback) {
      _deviceName.text = deviceName;
    }
  }

  Future<void> _loadHostFolderSelection() async {
    if (_server.isRunning) {
      if (mounted) {
        setState(() => _loadingHostFolderSelection = false);
      }
      return;
    }
    final selection = await _hostFolderService.loadSavedSelection();
    if (!mounted) return;
    setState(() {
      _hostFolderSelection = selection;
      _loadingHostFolderSelection = false;
    });
    if (selection != null) {
      unawaited(_loadLibraryFiles());
    }
  }

  Future<void> _refreshNetworkStatus() async {
    _setNetworkState(() => _networkLoading = true);
    try {
      final status = await PlatformNetwork.currentNetworkStatus();
      if (!mounted) return;
      _setNetworkState(() {
        _networkStatus = status;
        _networkLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      _setNetworkState(() {
        _networkStatus = const DropNetworkStatus(
          mode: DropNetworkMode.unavailable,
        );
        _networkLoading = false;
      });
    }
  }

  void _setNetworkState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _networkUiVersion.value += 1;
  }

  void _setJoinState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _joinUiVersion.value += 1;
  }

  void _openInfoScreen(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _dropAuthService.selectedOrg.removeListener(_onSelectedOrgChanged);
    _dropAuthService.signedIn.removeListener(_onGatewayAuthChanged);
    _roomName.dispose();
    _deviceName.dispose();
    _password.dispose();
    _smartText.dispose();
    _smartTitle.dispose();
    _joinUrl.dispose();
    _joinPassword.dispose();
    _joinFolderName.dispose();
    _joinTextTitle.dispose();
    _joinTextBody.dispose();
    _referralCode.dispose();
    _networkUiVersion.dispose();
    _joinUiVersion.dispose();
    unawaited(_shareSubscription?.cancel());
    // A share intent can recreate the Flutter view even though the process and
    // its DropServer singleton are still alive. Widget disposal is therefore
    // not room ownership: stopping here would turn an Android/iOS UI lifecycle
    // event into an implicit press of the Stop button. Explicit stop/quit paths
    // perform the room teardown through _stopRoom().
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (_appInForeground) {
      if (_server.isRunning && _server.isExpired) {
        _handleRoomExpired();
      } else if (_server.isRunning) {
        unawaited(
          _roomRuntimeService.setKeepAwake(enabled: true).catchError((_) {}),
        );
      }
      unawaited(_loadLibraryFiles());
      unawaited(_refreshNetworkStatus());
      unawaited(_revalidateGatewaySession());
      unawaited(
        _shareIntakeService.consumeInitialShare().then((payload) {
          if (payload != null) {
            return _handleSharedPayload(payload);
          }
        }),
      );
    }
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
    if (index == 1) {
      unawaited(_discoverNearbyRooms());
    }
    if (index == 2) {
      unawaited(_loadLibraryFiles());
      if (_libraryScopeIndex == 1) {
        unawaited(_refreshGatewayFiles());
      }
    }
    if (index == 3 && _smartSendScopeIndex == 1) {
      unawaited(_refreshGatewayNodes());
    }
  }

  @override
  Widget build(BuildContext context) {
    final useSideRail = DesktopLayout.useSideRail(
      MediaQuery.sizeOf(context).width,
    );
    final shell = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_handleBackNavigation());
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              if (useSideRail) ...[
                _desktopNavigationRail(),
                const VerticalDivider(width: 1, color: DropTheme.line),
              ],
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    _homeTab(),
                    _roomsTab(),
                    _libraryTab(),
                    _smartSendTab(),
                    _settingsTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: useSideRail
            ? null
            : ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: DropTheme.black.withValues(alpha: 0.86),
                      border: const Border(
                        top: BorderSide(color: DropTheme.line),
                      ),
                    ),
                    child: NavigationBar(
                      selectedIndex: _tab,
                      onDestinationSelected: _selectTab,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home_rounded),
                          label: 'Home',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.hub_outlined),
                          selectedIcon: Icon(Icons.hub),
                          label: 'Rooms',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.folder_outlined),
                          selectedIcon: Icon(Icons.folder_rounded),
                          label: 'Library',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.bolt_outlined),
                          selectedIcon: Icon(Icons.bolt),
                          label: 'Send',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: 'Settings',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
    if (!isDesktopPlatform) return shell;
    return CallbackShortcuts(
      bindings: _desktopShortcutBindings(),
      child: Focus(autofocus: true, child: shell),
    );
  }

  Map<ShortcutActivator, VoidCallback> _desktopShortcutBindings() {
    final bindings = <ShortcutActivator, VoidCallback>{};
    void bind(LogicalKeyboardKey key, VoidCallback callback) {
      bindings[SingleActivator(key, meta: true)] = callback;
      bindings[SingleActivator(key, control: true)] = callback;
    }

    bind(LogicalKeyboardKey.digit1, () => _selectTab(0));
    bind(LogicalKeyboardKey.digit2, () => _selectTab(1));
    bind(LogicalKeyboardKey.digit3, () => _selectTab(2));
    bind(LogicalKeyboardKey.digit4, () => _selectTab(3));
    bind(LogicalKeyboardKey.digit5, () => _selectTab(4));
    bind(LogicalKeyboardKey.keyN, _showStartRoomSheet);
    bind(LogicalKeyboardKey.keyR, _refreshCurrentTab);
    return bindings;
  }

  void _refreshCurrentTab() {
    switch (_tab) {
      case 0:
        unawaited(_refreshNetworkStatus());
        if (_server.isRunning) unawaited(_refreshRoomData());
      case 1:
        unawaited(_discoverNearbyRooms());
      case 2:
        if (_libraryScopeIndex == 0) {
          unawaited(_loadLibraryFiles());
        } else {
          unawaited(_refreshGatewayFiles());
        }
      case 3:
        if (_smartSendScopeIndex == 1) unawaited(_refreshGatewayNodes());
      case 4:
        unawaited(_refreshNetworkStatus());
    }
  }

  Widget _desktopNavigationRail() {
    return NavigationRail(
      selectedIndex: _tab,
      onDestinationSelected: _selectTab,
      labelType: NavigationRailLabelType.all,
      groupAlignment: -0.35,
      leading: Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Image.asset(DropTheme.logoFlat, width: 38, height: 38),
      ),
      trailing: _desktopRailRoomStatus(),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: Text('Home'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.hub_outlined),
          selectedIcon: Icon(Icons.hub),
          label: Text('Rooms'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder_rounded),
          label: Text('Library'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.bolt_outlined),
          selectedIcon: Icon(Icons.bolt),
          label: Text('Send'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('Settings'),
        ),
      ],
    );
  }

  Widget _desktopRailRoomStatus() {
    final session = _session;
    final live = session != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 0),
      child: Tooltip(
        message: live
            ? '${session.name} · ${_server.activeGuestCount} guest(s)'
            : 'No active Drop Room',
        child: InkWell(
          onTap: () => _selectTab(0),
          borderRadius: BorderRadius.circular(DropTheme.radiusTile),
          child: Container(
            width: 82,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: live
                  ? DropTheme.success.withValues(alpha: 0.10)
                  : DropTheme.surface,
              borderRadius: BorderRadius.circular(DropTheme.radiusTile),
              border: Border.all(
                color: live
                    ? DropTheme.success.withValues(alpha: 0.28)
                    : DropTheme.line,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (live)
                  const PulsingDot(color: DropTheme.success, size: 7)
                else
                  const Icon(
                    Icons.circle_outlined,
                    color: DropTheme.faint,
                    size: 14,
                  ),
                const SizedBox(height: 6),
                Text(
                  live ? 'ROOM LIVE' : 'IDLE',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: live ? DropTheme.success : DropTheme.faint,
                    fontSize: 9,
                    letterSpacing: 0.7,
                  ),
                ),
                if (live) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_server.activeGuestCount} joined',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: DropTheme.muted,
                      fontSize: 9,
                    ),
                  ),
                  const SizedBox(height: 2),
                  IconButton(
                    onPressed: _stopRoom,
                    tooltip: 'Stop room',
                    visualDensity: VisualDensity.compact,
                    iconSize: 17,
                    color: DropTheme.danger,
                    icon: const Icon(Icons.stop_rounded),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _homeTab() {
    final session = _session;
    final ready = _networkStatus.isReady;
    final online = session != null || ready;
    return _Screen(
      child: _desktopFileDropTarget(
        global: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EnterTransition(child: _brandHeader()),
            const SizedBox(height: 18),
            if (session == null) ...[
              DropPill(
                dot: online,
                icon: online ? null : Icons.wifi_off_rounded,
                label: ready ? 'Ready · ${_networkStatus.label}' : 'Offline',
                color: online ? DropTheme.success : DropTheme.muted,
              ),
              const SizedBox(height: 22),
              EnterTransition(delayMs: 60, child: _homeHeadline()),
              const SizedBox(height: 12),
              Text(
                'Transfer directly when nearby. Choose Erebrus nodes when '
                'distance matters.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              EnterTransition(
                delayMs: 110,
                child: _homeActionCard(
                  hero: true,
                  icon: Icons.add_rounded,
                  title: 'Start Drop Room',
                  subtitle: 'Host a local browser room on this network.',
                  onTap: _showStartRoomSheet,
                ),
              ),
              const SizedBox(height: 12),
              _homeActionCard(
                hero: false,
                icon: Icons.login_rounded,
                title: 'Join Drop Room',
                subtitle: 'Enter a local Drop Link and browse after auth.',
                onTap: () => setState(() => _tab = 1),
              ),
              const SizedBox(height: 16),
              _trustStrip(),
            ] else
              _hostDashboard(session),
          ],
        ),
      ),
    );
  }

  Widget _homeHeadline() {
    final base = Theme.of(context).textTheme.displaySmall;
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Start, scan, '),
          TextSpan(
            text: 'send.',
            style: const TextStyle(color: DropTheme.orange),
          ),
        ],
      ),
      style: base,
    );
  }

  Widget _homeActionCard({
    required bool hero,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final row = Row(
      children: [
        LeadingTile(icon: icon, gradient: hero, size: 46),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 3),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.chevron_right_rounded, color: DropTheme.faint),
      ],
    );
    if (hero) {
      return DropCard.tinted(onTap: onTap, glow: true, child: row);
    }
    return DropCard(onTap: onTap, child: row);
  }

  Widget _trustStrip() {
    return DropCard.tinted(
      accent: DropTheme.success,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.shield_rounded, color: DropTheme.success, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Nearby rooms transfer directly over your network. Global uses '
              'a selected Erebrus node only when you choose it.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: DropTheme.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roomsTab() {
    final session = _session;
    return _Screen(
      glowAlignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head(
            title: 'Rooms',
            subtitle: 'Nearby on ${_networkStatus.label}',
            action: session == null
                ? TonalButton(
                    label: 'Start',
                    icon: Icons.add_rounded,
                    onPressed: _showStartRoomSheet,
                  )
                : TonalButton(
                    label: 'Drop Code',
                    icon: Icons.qr_code_rounded,
                    onPressed: () => _showQrDialog(session),
                  ),
          ),
          const SizedBox(height: 16),
          if (session != null) ...[
            _hostDashboard(session),
            const SizedBox(height: 12),
          ],
          _nearbyRoomsCard(),
          const SizedBox(height: 12),
          _manualJoinCard(),
          const SizedBox(height: 18),
          _scanningFooter(),
        ],
      ),
    );
  }

  Widget _scanningFooter() {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingDot(
            color: _discoveringRooms ? DropTheme.orange : DropTheme.faint,
            size: 8,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'Scanning network with mDNS…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _libraryTab() {
    final hasLibrarySource = _server.isRunning || _hostFolderSelection != null;
    return _Screen(
      glowAlignment: Alignment.topRight,
      layout: DesktopContentLayout.library,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Head(
            title: 'Library',
            subtitle: _libraryScopeIndex == 0
                ? 'Shared this session'
                : 'Files pinned to Erebrus nodes',
            action: DropIconButton(
              icon: Icons.refresh_rounded,
              busy: _loadingLibraryFiles || _gatewayFilesLoading,
              tooltip: 'Refresh',
              onPressed: () {
                if (_libraryScopeIndex == 0) {
                  if (hasLibrarySource) unawaited(_loadLibraryFiles());
                } else {
                  unawaited(_refreshGatewayFiles());
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          _scopeToggle(
            labels: const ['Local', 'Global'],
            selected: _libraryScopeIndex,
            onSelected: (i) {
              setState(() {
                _libraryScopeIndex = i;
                _selectedLocalFile = null;
                _selectedGlobalFile = null;
              });
              if (i == 1) unawaited(_refreshGatewayFiles());
            },
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final split = DesktopLayout.useSplitPane(constraints.maxWidth);
              final content = _libraryContent(
                hasLibrarySource: hasLibrarySource,
                selectionMode: split,
              );
              if (!split) return content;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: content),
                  const SizedBox(width: 16),
                  SizedBox(width: 320, child: _librarySelectionPanel()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _libraryContent({
    required bool hasLibrarySource,
    required bool selectionMode,
  }) {
    if (_libraryScopeIndex == 1) {
      return _gatewayLibraryPanel(selectionMode: selectionMode);
    }
    if (!hasLibrarySource) {
      return _InfoCard(
        title: 'Choose a Drop folder',
        subtitle:
            'Library opens your selected device folder even when no room is running.',
        icon: Icons.folder_special_outlined,
        onTap: () => unawaited(_selectHostFolder()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _libraryPathBar(),
        const SizedBox(height: 12),
        if (_libraryError != null)
          _InfoCard(
            title: 'Could not open folder',
            subtitle: _libraryError!,
            icon: Icons.error_outline,
            onTap: () => unawaited(_loadLibraryFiles()),
          )
        else if (_loadingLibraryFiles)
          const _InfoCard(
            title: 'Loading folder',
            subtitle: 'Reading the selected Drop folder.',
            icon: Icons.folder_open_outlined,
          )
        else if (_files.isEmpty)
          const _InfoCard(
            title: 'Folder is empty',
            subtitle: 'Uploads, pasted text, and local files appear here.',
            icon: Icons.folder_open_outlined,
          )
        else
          _libraryFilesCard(selectionMode: selectionMode),
      ],
    );
  }

  Widget _librarySelectionPanel() {
    if (_libraryScopeIndex == 1) {
      final file = _selectedGlobalFile;
      if (file == null) {
        return const _InfoCard(
          title: 'Select a global file',
          subtitle: 'File details and actions will appear here.',
          icon: Icons.touch_app_outlined,
        );
      }
      return DropCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Eyebrow('GLOBAL FILE'),
            const SizedBox(height: 10),
            Text(file.filename, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '${formatBytes(file.sizeBytes)} · ${file.isPublic ? 'Public' : 'Private'}${file.encrypted ? ' · Encrypted' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (file.cid?.isNotEmpty == true) ...[
              const SizedBox(height: 14),
              MonoText(file.cid!, size: 11, color: DropTheme.muted),
            ],
            const SizedBox(height: 18),
            PrimaryButton(
              label: 'Download',
              icon: Icons.download_rounded,
              onPressed: () => unawaited(_downloadGatewayFile(file)),
            ),
            if (file.cid?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              TonalButton(
                label: 'Copy CID',
                icon: Icons.copy_rounded,
                onPressed: () => _copy(file.cid!, 'IPFS CID copied'),
              ),
            ],
          ],
        ),
      );
    }

    final item = _selectedLocalFile;
    if (item == null) {
      return const _InfoCard(
        title: 'Select a file or folder',
        subtitle: 'Details and desktop actions will appear here.',
        icon: Icons.touch_app_outlined,
      );
    }
    final isFolder = item.type == 'folder';
    final (color, icon) = _fileTypeStyle(item);
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LeadingTile(icon: icon, accent: color, size: 46),
          const SizedBox(height: 12),
          Text(item.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 5),
          Text(
            isFolder
                ? 'Folder · ${_shortWhen(item.modifiedAt)}'
                : '${formatBytes(item.sizeBytes)} · ${_shortWhen(item.modifiedAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          PrimaryButton(
            label: isFolder ? 'Open folder' : 'Open file',
            icon: isFolder ? Icons.folder_open_rounded : Icons.open_in_new,
            onPressed: () {
              if (isFolder) {
                setState(() {
                  _libraryPath = item.path;
                  _selectedLocalFile = null;
                });
                unawaited(_loadLibraryFiles());
              } else {
                unawaited(_openLibraryFile(item));
              }
            },
          ),
          if (!isFolder) ...[
            const SizedBox(height: 8),
            TonalButton(
              label: 'Share',
              icon: Icons.ios_share_rounded,
              onPressed: () => unawaited(_shareLibraryFile(item)),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => unawaited(_confirmDeleteLibraryFile(item)),
              icon: const Icon(Icons.delete_outline, color: DropTheme.danger),
              label: const Text(
                'Delete',
                style: TextStyle(color: DropTheme.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _scopeToggle({
    required List<String> labels,
    required int selected,
    required ValueChanged<int> onSelected,
  }) {
    return ToggleButtons(
      isSelected: labels.map((_) => false).toList()..[selected] = true,
      onPressed: (index) => onSelected(index),
      borderRadius: BorderRadius.circular(DropTheme.radiusTile),
      borderColor: DropTheme.line,
      selectedBorderColor: DropTheme.orange,
      fillColor: DropTheme.orange.withValues(alpha: 0.18),
      selectedColor: DropTheme.orange,
      color: DropTheme.muted,
      constraints: const BoxConstraints(minHeight: 40, minWidth: 80),
      children: labels
          .map(
            (label) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(label),
            ),
          )
          .toList(),
    );
  }

  Widget _gatewayLibraryPanel({required bool selectionMode}) {
    if (!_dropAuthService.isSignedIn) {
      return _InfoCard(
        title: 'Sign in to view global files',
        subtitle:
            'Connect your wallet to see files pinned to public and organization nodes.',
        icon: Icons.cloud_outlined,
        onTap: () => unawaited(_showGatewayLogin()),
      );
    }
    if (_gatewayFilesLoading && _gatewayFiles.isEmpty) {
      return const _InfoCard(
        title: 'Loading global files',
        subtitle: 'Fetching files from public and organization nodes.',
        icon: Icons.cloud_sync_outlined,
      );
    }
    if (_gatewayFiles.isEmpty) {
      return _InfoCard(
        title: 'No global files yet',
        subtitle: _dropAuthService.selectedOrg.value == null
            ? 'Switch to a selected organization in Settings to see its pinned files.'
            : 'Files pinned to public or ${(_dropAuthService.selectedOrg.value?.name ?? 'organization')} nodes appear here.',
        icon: Icons.cloud_off_outlined,
        onTap: () => unawaited(_refreshGatewayFiles()),
      );
    }
    return DropCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _gatewayFiles.length; i++)
            _gatewayFileTile(
              _gatewayFiles[i],
              first: i == 0,
              selectionMode: selectionMode,
            ),
        ],
      ),
    );
  }

  Widget _gatewayFileTile(
    DropGatewayFile file, {
    required bool first,
    required bool selectionMode,
  }) {
    final (color, icon) = _fileTypeStyle(
      DropFileItem(
        id: file.id,
        name: file.filename,
        type: file.contentType ?? 'file',
        path: file.cid ?? '',
        sizeBytes: file.sizeBytes,
        createdAt: file.createdAt,
        modifiedAt: file.createdAt,
        mimeType: file.contentType,
        streamable: false,
      ),
    );
    final tags = <String>[
      formatBytes(file.sizeBytes),
      _shortWhen(file.createdAt),
      if (file.isPublic) 'Public' else 'Private',
      if (file.encrypted) 'Encrypted',
      if (file.orgId != null) 'Org',
    ];
    final meta = tags.join(' · ');
    final tile = DecoratedBox(
      decoration: BoxDecoration(
        color: selectionMode && _selectedGlobalFile?.fileId == file.fileId
            ? DropTheme.orange.withValues(alpha: 0.08)
            : null,
        border: first
            ? null
            : const Border(top: BorderSide(color: DropTheme.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            LeadingTile(icon: icon, accent: color, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (file.cid?.isNotEmpty == true)
              IconButton(
                onPressed: () => _copy(file.cid!, 'IPFS CID copied'),
                icon: const Icon(Icons.copy_rounded, size: 19),
                color: DropTheme.faint,
                tooltip: 'Copy CID',
                visualDensity: VisualDensity.compact,
              ),
            IconButton(
              onPressed: () => unawaited(_downloadGatewayFile(file)),
              icon: const Icon(Icons.download_rounded, size: 19),
              color: DropTheme.faint,
              tooltip: file.encrypted ? 'Download (encrypted)' : 'Download',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
    if (!selectionMode) return tile;
    return PressableScale(
      onTap: () => setState(() => _selectedGlobalFile = file),
      child: tile,
    );
  }

  Widget _libraryFilesCard({required bool selectionMode}) {
    return DropCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _files.length; i++)
            _fileTile(_files[i], first: i == 0, selectionMode: selectionMode),
        ],
      ),
    );
  }

  (Color, IconData) _fileTypeStyle(DropFileItem item) {
    if (item.type == 'folder') return (DropTheme.orange, Icons.folder_rounded);
    final mime = (item.mimeType ?? '').toLowerCase();
    final name = item.name.toLowerCase();
    if (mime.startsWith('image/')) {
      return (DropTheme.success, Icons.image_rounded);
    }
    if (mime.startsWith('video/')) {
      return (DropTheme.amber, Icons.movie_rounded);
    }
    if (mime.startsWith('audio/')) {
      return (DropTheme.amber, Icons.audiotrack_rounded);
    }
    if (mime.contains('pdf') || name.endsWith('.pdf')) {
      return (DropTheme.danger, Icons.picture_as_pdf_rounded);
    }
    if (name.endsWith('.zip') ||
        name.endsWith('.rar') ||
        name.endsWith('.gz') ||
        name.endsWith('.tar') ||
        name.endsWith('.7z')) {
      return (DropTheme.orange, Icons.folder_zip_rounded);
    }
    if (mime.startsWith('text/') ||
        name.endsWith('.txt') ||
        name.endsWith('.md')) {
      return (DropTheme.muted, Icons.description_rounded);
    }
    return (DropTheme.muted, Icons.insert_drive_file_rounded);
  }

  String _shortWhen(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  Widget _smartSendTab() {
    return _Screen(
      glowAlignment: Alignment.topLeft,
      layout: DesktopContentLayout.workspace,
      child: _desktopFileDropTarget(
        global: _smartSendScopeIndex == 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Head(
              title: 'Smart Send',
              subtitle: _smartSendScopeIndex == 0
                  ? 'Push text into the room'
                  : 'Upload files to Erebrus nodes and get the share link',
              action: _smartSendScopeIndex == 0
                  ? DropIconButton(
                      icon: Icons.content_paste_rounded,
                      tonal: true,
                      tooltip: 'Paste clipboard',
                      onPressed: _pasteClipboard,
                    )
                  : null,
            ),
            const SizedBox(height: 12),
            _scopeToggle(
              labels: const ['Local', 'Global'],
              selected: _smartSendScopeIndex,
              onSelected: (i) {
                setState(() => _smartSendScopeIndex = i);
                if (i == 1) unawaited(_refreshGatewayNodes());
              },
            ),
            const SizedBox(height: 16),
            if (_smartSendScopeIndex == 1)
              _gatewaySendPanel()
            else
              _localSmartSendBody(),
          ],
        ),
      ),
    );
  }

  Widget _desktopFileDropTarget({required bool global, required Widget child}) {
    if (!isDesktopPlatform) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _draggingFiles = true),
      onDragExited: (_) => setState(() => _draggingFiles = false),
      onDragDone: (detail) {
        setState(() => _draggingFiles = false);
        final paths = detail.files
            .map((file) => file.path)
            .where((path) => path.isNotEmpty)
            .toList();
        if (paths.isEmpty) return;
        if (global) {
          unawaited(_uploadDroppedFilesToGateway(paths));
        } else {
          unawaited(_handleSharedPayload(SharedPayload(filePaths: paths)));
        }
      },
      child: Stack(
        children: [
          child,
          if (_draggingFiles)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: DropTheme.black.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(DropTheme.radiusCard),
                    border: Border.all(color: DropTheme.orange, width: 2),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.file_download_outlined,
                          color: DropTheme.orange,
                          size: 42,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          global
                              ? 'Drop to send through the selected node'
                              : 'Drop to add to your local Drop folder',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _localSmartSendBody() {
    final hosting = _server.isRunning;
    final canSaveSmartText = hosting || _hostFolderSelection != null;
    final composer = DropCard(
      child: Column(
        children: [
          TextField(
            controller: _smartTitle,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _smartText,
            minLines: 7,
            maxLines: 13,
            decoration: const InputDecoration(
              labelText: 'Text, link, SMS copy, or note',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PrimaryButton(
                  label: hosting ? 'Send to Room' : 'Save to Folder',
                  icon: Icons.send_rounded,
                  onPressed: canSaveSmartText ? _saveSmartText : null,
                ),
              ),
              const SizedBox(width: 10),
              DropIconButton(
                icon: Icons.clear_rounded,
                tooltip: 'Clear',
                onPressed: () {
                  _smartText.clear();
                  _smartTitle.text = 'Quick text';
                },
              ),
            ],
          ),
        ],
      ),
    );
    final destination = _smartDestinationCard();
    final actions = _SmartSendActions(
      onAddFiles: () => unawaited(_pickAndAddFiles()),
      onSendLink: () => unawaited(_showAddLinkDialog()),
    );
    final contextPanel = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [destination, const SizedBox(height: 12), actions],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!DesktopLayout.useSplitPane(constraints.maxWidth)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              destination,
              const SizedBox(height: 12),
              composer,
              const SizedBox(height: 12),
              actions,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: composer),
            const SizedBox(width: 16),
            SizedBox(width: 330, child: contextPanel),
          ],
        );
      },
    );
  }

  Widget _gatewaySendPanel() {
    if (!_dropAuthService.isSignedIn) {
      return _InfoCard(
        title: 'Sign in to send to global nodes',
        subtitle:
            'Connect your wallet to access public and organization Drop nodes.',
        icon: Icons.cloud_outlined,
        onTap: () => unawaited(_showGatewayLogin()),
      );
    }
    if (_gatewayNodes.isEmpty && !_gatewayNodesLoading) {
      return _InfoCard(
        title: 'No global nodes available',
        subtitle:
            _gatewayError ??
            'No public or organization nodes are online right now.',
        icon: Icons.cloud_off_outlined,
        onTap: () => unawaited(_refreshGatewayNodes()),
      );
    }

    final selected = _selectedSendNode;
    final nodes = _gatewayNodes;
    final targetCard = DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Target node', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          if (selected != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LeadingTile(
                  icon: Icons.hub_rounded,
                  accent: selected.online
                      ? DropTheme.success
                      : DropTheme.danger,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${selected.region.isEmpty ? 'Global' : selected.region} · ${selected.capacity.isEmpty ? 'Unknown capacity' : selected.capacity.capitalize()}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                _NodeStatusChip(online: selected.online),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _NodeDetailChip(
                  icon: selected.isPublic
                      ? Icons.public_rounded
                      : Icons.lock_rounded,
                  label: selected.isPublic ? 'Public' : 'Private',
                  color: selected.isPublic
                      ? DropTheme.success
                      : DropTheme.orange,
                ),
                _NodeDetailChip(
                  icon: Icons.layers_rounded,
                  label: selected.deploymentProfile.capitalize(),
                  color: DropTheme.faint,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ] else
            Text(
              'Select a node to upload to',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: DropTheme.muted),
            ),
          const SizedBox(height: 10),
          // Deduplicate by nodeId and use String IDs as dropdown values
          // to avoid object-identity collisions from duplicate instances.
          Builder(
            builder: (context) {
              final uniqueNodes = <String, DropNode>{};
              for (final node in nodes) {
                uniqueNodes.putIfAbsent(node.nodeId, () => node);
              }
              final selectedId =
                  selected != null && uniqueNodes.containsKey(selected.nodeId)
                  ? selected.nodeId
                  : null;
              return DropdownButton<String>(
                isExpanded: true,
                value: selectedId,
                hint: const Text('Select a node'),
                items: uniqueNodes.values
                    .map(
                      (node) => DropdownMenuItem(
                        value: node.nodeId,
                        child: _NodeDropdownItem(node: node),
                      ),
                    )
                    .toList(),
                onChanged: (nodeId) =>
                    setState(() => _selectedSendNode = uniqueNodes[nodeId]),
              );
            },
          ),
        ],
      ),
    );
    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_gatewayUploadedCid?.isNotEmpty == true)
          DropCard.tinted(
            accent: DropTheme.success,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Eyebrow('IPFS CID', color: DropTheme.success),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: MonoText(
                        _gatewayUploadedCid!,
                        size: 13,
                        color: DropTheme.white,
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          _copy(_gatewayUploadedCid!, 'CID copied'),
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      color: DropTheme.success,
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (_gatewayUploadedCid?.isNotEmpty == true) const SizedBox(height: 12),
        PrimaryButton(
          label: _gatewayUploading ? 'Uploading…' : 'Add files',
          icon: Icons.cloud_upload_rounded,
          busy: _gatewayUploading,
          onPressed: selected != null && !_gatewayUploading
              ? () => unawaited(_uploadToGatewayNode())
              : null,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!DesktopLayout.useSplitPane(constraints.maxWidth)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [targetCard, const SizedBox(height: 12), actions],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: targetCard),
            const SizedBox(width: 16),
            SizedBox(width: 330, child: actions),
          ],
        );
      },
    );
  }

  Future<void> _uploadToGatewayNode() async {
    final picked = await _nativeFilePickerService.pickFileForUpload();
    if (picked == null || picked.path.isEmpty) return;
    await _uploadFileToGatewayNode(File(picked.path), picked.name);
  }

  Future<void> _uploadDroppedFilesToGateway(List<String> paths) async {
    if (!_dropAuthService.isSignedIn) {
      _snack('Sign in before sending files globally');
      return;
    }
    if (_selectedSendNode == null) {
      _snack('Select an Erebrus node first');
      return;
    }
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;
      final name = file.uri.pathSegments.isEmpty
          ? 'dropped-file'
          : file.uri.pathSegments.last;
      await _uploadFileToGatewayNode(file, name);
    }
  }

  Future<void> _uploadFileToGatewayNode(File file, String filename) async {
    final node = _selectedSendNode;
    final org = _dropAuthService.selectedOrg.value;
    if (node == null) return;
    if (!mounted) return;
    setState(() {
      _gatewayUploading = true;
      _gatewayUploadedCid = null;
    });
    try {
      final isOrgNode = org != null && node.orgId == org.id;
      final orgId = isOrgNode ? org.id : null;
      final uploaded = await _dropAuthService.gatewayClient.uploadFile(
        nodeId: node.nodeId,
        file: file,
        filename: filename,
        visibility: 'public',
        scope: isOrgNode ? 'private' : 'public',
        orgId: orgId,
      );
      if (!mounted) return;
      setState(() => _gatewayUploadedCid = uploaded.cid);
      _snack('$filename pinned to ${node.name}');
      unawaited(_refreshGatewayFiles());
    } catch (e) {
      if (!mounted) return;
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _gatewayUploading = false);
    }
  }

  Future<void> _downloadGatewayFile(DropGatewayFile file) async {
    if (_hostFolderSelection == null) {
      await _promptSelectDropFolder();
      if (_hostFolderSelection == null) {
        if (mounted) _snack('Choose a Drop folder to save downloads');
        return;
      }
    }

    String? encryptionKey;
    if (file.encrypted) {
      encryptionKey = await _promptEncryptionKey(file.filename);
      if (encryptionKey == null || encryptionKey.isEmpty) return;
    }
    if (!mounted) return;
    _snack('Downloading ${file.filename}…');
    try {
      final temp = await _dropAuthService.gatewayClient.downloadFile(
        file,
        encryptionKey: encryptionKey,
      );
      final selection = _hostFolderSelection!;
      final saved = await _hostFolderBridge.copyFileInto(
        rootUri: selection.uri,
        folderPath: '/',
        sourcePath: temp.path,
        name: file.filename,
        mimeType: file.contentType ?? 'application/octet-stream',
      );
      if (!mounted) return;
      _snack('Saved to ${saved.name} in ${selection.name}');
    } on GatewayException catch (e) {
      if (!mounted) return;
      _snack('Download failed: ${e.message}');
    } on PlatformException catch (e) {
      if (!mounted) return;
      _snack('Could not save file: ${e.message}. Re-select the Drop folder.');
      await _hostFolderService.clearSelection();
      setState(() => _hostFolderSelection = null);
    } catch (e) {
      if (!mounted) return;
      _snack('Download failed: $e');
    }
  }

  /// Asks the user to pick a Drop folder before downloading.
  /// Returns `true` if a folder was selected.
  Future<bool> _promptSelectDropFolder() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: DropTheme.black,
            title: const Text('Choose Drop folder'),
            content: const Text(
              'Gateway downloads are saved to your selected Drop folder. '
              'Please choose a folder and grant permission to write there.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  await _selectHostFolder();
                  if (ctx.mounted) {
                    Navigator.of(ctx).pop(_hostFolderSelection != null);
                  }
                },
                child: const Text('Choose folder'),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// Shows a dialog for entering or loading an encryption key.
  /// Returns the key text, or null if cancelled.
  Future<String?> _promptEncryptionKey(String filename) async {
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: DropTheme.black,
        title: Text('Decryption key for $filename'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the key used to encrypt this file, or load it from a text/key file.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'Passphrase or base64/hex key',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              ctrl.clear();
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final picked = await _nativeFilePickerService.pickFileForUpload();
              if (picked == null || picked.path.isEmpty) return;
              try {
                final text = await File(picked.path).readAsString();
                ctrl.text = text.trim();
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('Could not read key file: $e')),
                  );
                }
              }
            },
            child: const Text('Load key file'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    final result = ctrl.text.trim();
    ctrl.dispose();
    return result.isEmpty ? null : result;
  }

  Widget _smartDestinationCard() {
    final hosting = _server.isRunning;
    final hasFolder = _hostFolderSelection != null;
    if (hosting || hasFolder) {
      return DropCard.tinted(
        accent: DropTheme.success,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow(
                    hosting ? 'Live room' : 'Drop folder',
                    color: DropTheme.success,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    hosting
                        ? (_session?.name ?? 'Drop Room')
                        : _hostFolderSelection!.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(
              Icons.check_circle_rounded,
              color: DropTheme.success,
              size: 22,
            ),
          ],
        ),
      );
    }
    return DropCard(
      child: Row(
        children: [
          const LeadingTile(icon: Icons.folder_off_rounded, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No Drop folder selected',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  'Choose where text is saved',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TonalButton(
            label: 'Choose',
            onPressed: () => unawaited(_selectHostFolder()),
          ),
        ],
      ),
    );
  }

  Widget _settingsTab() {
    return _Screen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Head(title: 'Settings'),
          const SizedBox(height: 16),
          _gatewayAccountCard(),
          if (_dropAuthService.isSignedIn) ...[
            const SizedBox(height: 12),
            _referralCard(),
          ],
          const SizedBox(height: 12),
          DropCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _toggleRow(
                  icon: Icons.lock_rounded,
                  title: 'Require password by default',
                  description: 'New rooms start with a password.',
                  value: _usePassword,
                  onChanged: (value) => setState(() => _usePassword = value),
                  first: true,
                ),
                _toggleRow(
                  icon: Icons.local_fire_department_rounded,
                  title: 'Burn Mode default',
                  description: 'Auto-expire new rooms after 2 hours.',
                  value: _burnMode,
                  onChanged: (value) => setState(() => _burnMode = value),
                  first: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _hostFolderSettingsCard(),
          const SizedBox(height: 12),
          _ipfsGatewaySettingsCard(),
          const SizedBox(height: 22),
          const Eyebrow('ABOUT'),
          const SizedBox(height: 10),
          DropCard(
            padding: EdgeInsets.zero,
            child: _settingsRow(
              icon: Icons.info_outline_rounded,
              title: 'About',
              subtitle: 'Version, privacy, and terms',
              onTap: () => _openInfoScreen(const AboutScreen()),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: DropTheme.faint,
              ),
              first: true,
              last: true,
            ),
          ),
          if (_dropAuthService.isSignedIn) ...[
            const SizedBox(height: 22),
            _settingsSignInOutButton(),
          ],
          const SizedBox(height: 24),
          _settingsFooter(),
        ],
      ),
    );
  }

  Widget _toggleRow({
    required IconData icon,
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool first,
  }) {
    return _settingsRow(
      icon: icon,
      title: title,
      subtitle: description,
      first: first,
      last: true,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  Widget _settingsRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool first,
    required bool last,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: first
            ? null
            : const Border(top: BorderSide(color: DropTheme.line)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.vertical(
          top: first
              ? const Radius.circular(DropTheme.radiusCard)
              : Radius.zero,
          bottom: last
              ? const Radius.circular(DropTheme.radiusCard)
              : Radius.zero,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Row(
            children: [
              LeadingTile(icon: icon, accent: DropTheme.orange, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingsSignInOutButton() {
    final signedIn = _dropAuthService.isSignedIn;
    return GestureDetector(
      onTap: signedIn
          ? () async {
              final confirmed = await confirmGatewaySignOut(context);
              if (!confirmed || !mounted) return;
              await _dropAuthService.signOut();
              if (mounted) {
                _snack('Signed out');
                setState(() {});
              }
            }
          : () => unawaited(_showGatewayLogin()),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: signedIn
              ? DropTheme.danger.withValues(alpha: 0.08)
              : DropTheme.orange,
          borderRadius: BorderRadius.circular(DropTheme.radiusTile),
          border: signedIn
              ? Border.all(color: DropTheme.danger.withValues(alpha: 0.3))
              : null,
        ),
        child: Text(
          signedIn ? 'Sign out' : 'Sign in',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: signedIn ? DropTheme.danger : DropTheme.onAccent,
          ),
        ),
      ),
    );
  }

  Widget _gatewayAccountCard() {
    final signedIn = _dropAuthService.isSignedIn;
    if (signedIn) {
      final org = _dropAuthService.selectedOrg.value;
      final wallet = _dropAuthService.walletAddress;
      final label = org?.name ?? 'Personal';
      final identity = wallet != null && wallet.length > 12
          ? '${wallet.substring(0, 6)}…${wallet.substring(wallet.length - 4)}'
          : 'Signed in';
      final sub = '$identity · ${org?.planLabel ?? 'Free'}';
      return DropCard(
        child: Row(
          children: [
            LeadingTile(
              icon: Icons.cloud_done_rounded,
              accent: DropTheme.success,
              size: 42,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(sub, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (org != null)
              TonalButton(
                label: 'Switch',
                onPressed: () => unawaited(_showOrgSwitcher()),
              ),
          ],
        ),
      );
    }

    // Guest CTA at the top of Settings (mirrors the VPN app).
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DropTheme.orange.withValues(alpha: 0.14),
            DropTheme.orange.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(DropTheme.radiusCard),
        border: Border.all(color: DropTheme.orange.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Unlock public Drop nodes',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Sign in or register to send files through Erebrus nodes and manage your account.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => unawaited(_showGatewayLogin()),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DropTheme.orange,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'SIGN IN / REGISTER',
                style: TextStyle(
                  fontFamily: DropTheme.monoFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: DropTheme.onAccent,
                  letterSpacing: 13 * 0.05,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _referralCard() {
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const LeadingTile(
                icon: Icons.card_giftcard_rounded,
                accent: DropTheme.orange,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Have an invite code?',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Redeem a friend\'s code to credit them for the invite.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _referralCode,
                  enabled: !_redeemingReferral,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => unawaited(_redeemReferral()),
                  decoration: const InputDecoration(hintText: 'Invite code'),
                ),
              ),
              const SizedBox(width: 10),
              TonalButton(
                label: 'APPLY',
                busy: _redeemingReferral,
                onPressed: _redeemingReferral
                    ? null
                    : () => unawaited(_redeemReferral()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _redeemReferral() async {
    final code = _referralCode.text.trim();
    if (code.isEmpty) {
      _snack('Enter an invite code');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _redeemingReferral = true);
    try {
      final message = await _dropAuthService.redeemReferralCode(code);
      if (!mounted) return;
      _referralCode.clear();
      _snack(message);
    } catch (e) {
      if (mounted) _snack(e.toString());
    } finally {
      if (mounted) setState(() => _redeemingReferral = false);
    }
  }

  Future<void> _showOrgSwitcher() async {
    final result = await showGatewayOrgSheet(
      context: context,
      authService: _dropAuthService,
    );
    if (result == GatewayOrgSheetResult.changed && mounted) {
      _snack('Organization updated');
      unawaited(_refreshGatewayNodes());
      unawaited(_refreshGatewayFiles());
    }
  }

  Widget _hostFolderSettingsCard() {
    final selection = _hostFolderSelection;
    final pathLabel = selection == null
        ? (_loadingHostFolderSelection ? 'Checking…' : 'No folder selected')
        : selection.name;
    final canForget = selection != null && !_server.isRunning;
    return DropCard(
      child: Row(
        children: [
          const LeadingTile(
            icon: Icons.folder_special_rounded,
            accent: DropTheme.orange,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Drop folder',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                MonoText(pathLabel, size: 12, color: DropTheme.muted),
              ],
            ),
          ),
          DropIconButton(
            icon: Icons.drive_folder_upload_rounded,
            tooltip: selection == null ? 'Select folder' : 'Change folder',
            tonal: true,
            color: DropTheme.orange,
            size: 40,
            busy: _hostFolderBusy,
            onPressed: _hostFolderBusy
                ? null
                : () => unawaited(_selectHostFolder()),
          ),
          if (canForget) ...[
            const SizedBox(width: 4),
            DropIconButton(
              icon: Icons.restart_alt_rounded,
              tooltip: 'Forget folder',
              tonal: true,
              color: DropTheme.muted,
              size: 40,
              busy: _hostFolderBusy,
              onPressed: _hostFolderBusy ? null : _forgetHostFolderSelection,
            ),
          ],
        ],
      ),
    );
  }

  Widget _ipfsGatewaySettingsCard() {
    return DropCard(
      padding: EdgeInsets.zero,
      child: _settingsRow(
        icon: Icons.cloud_done_outlined,
        title: 'IPFS Gateway',
        subtitle: _ipfsGatewayUrl,
        onTap: () => unawaited(_showIpfsGatewayPicker()),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: DropTheme.faint,
        ),
        first: true,
        last: true,
      ),
    );
  }

  Future<void> _showIpfsGatewayPicker() async {
    const presets = <String>[
      'https://ipfs.erebrus.io',
      'https://cloudflare-ipfs.com',
      'https://gateway.pinata.cloud',
      'https://ipfs.io',
    ];
    final initial = _ipfsGatewayUrl;
    String? selected = presets.contains(initial) ? initial : null;
    final customCtrl = TextEditingController(
      text: presets.contains(initial) ? '' : initial,
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final effectiveUrl = selected ?? customCtrl.text.trim();
          return AlertDialog(
            backgroundColor: DropTheme.black,
            title: const Text('IPFS Gateway'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Choose the gateway used to fetch files by CID.'),
                  const SizedBox(height: 12),
                  for (final preset in presets)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        selected == preset
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected == preset
                            ? DropTheme.orange
                            : DropTheme.faint,
                      ),
                      title: Text(preset),
                      onTap: () {
                        setDialogState(() {
                          selected = preset;
                          customCtrl.clear();
                        });
                      },
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      selected == null
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: selected == null
                          ? DropTheme.orange
                          : DropTheme.faint,
                    ),
                    title: const Text('Custom'),
                    onTap: () => setDialogState(() => selected = null),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 34),
                    child: TextField(
                      controller: customCtrl,
                      enabled: selected == null,
                      decoration: const InputDecoration(
                        hintText: 'https://your-gateway.tld',
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: effectiveUrl.isEmpty
                    ? null
                    : () {
                        Navigator.of(ctx).pop();
                        unawaited(_saveIpfsGatewayUrl(effectiveUrl));
                      },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    customCtrl.dispose();
  }

  Widget _settingsFooter() {
    final shortVersion = _appVersion.split('+').first;
    return Center(
      child: MonoText(
        'v$shortVersion · NetSepio',
        size: 12,
        color: DropTheme.faint,
        weight: FontWeight.w500,
      ),
    );
  }

  Widget _dropFolderStartCard(StateSetter setSheetState) {
    final selection = _hostFolderSelection;
    return DropCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LeadingTile(
                icon: selection == null
                    ? Icons.folder_special_rounded
                    : Icons.folder_rounded,
                accent: selection == null ? DropTheme.amber : DropTheme.orange,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Drop folder',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      selection == null ? 'Required' : selection.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TonalButton(
                label: selection == null ? 'Select' : 'Change',
                busy: _hostFolderBusy,
                onPressed: _hostFolderBusy
                    ? null
                    : () async {
                        await _selectHostFolder();
                        setSheetState(() {});
                      },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            selection == null
                ? 'Used by Library, uploads, text, and browser drops.'
                : 'Library, uploads, text, and browser drops use this root.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _hostDashboard(DropRoomSession session) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Head(
          title: 'Live Room',
          subtitle: 'Hosting on ${_networkStatus.label}',
          action: _livePill(),
        ),
        const SizedBox(height: 16),
        _liveRoomCard(session),
        const SizedBox(height: 12),
        _webDavCard(session),
        const SizedBox(height: 12),
        _hostStatCards(session),
      ],
    );
  }

  Widget _livePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: DropTheme.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DropTheme.success.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PulsingDot(color: DropTheme.success, size: 7),
          const SizedBox(width: 7),
          Text(
            'LIVE',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: DropTheme.success,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _qrTile(String data, double size) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DropTheme.radiusTile),
      ),
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: size,
        backgroundColor: Colors.white,
      ),
    );
  }

  Widget _liveRoomCard(DropRoomSession session) {
    final guests = _server.activeGuestCount;
    return DropCard(
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _qrTile(session.baseUrl, 92),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    MonoText(
                      '${session.localIp}:${session.port}',
                      color: DropTheme.muted,
                      size: 13,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        DropPill(
                          icon: session.authRequired
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          label: session.authRequired ? 'Password' : 'Open',
                          color: session.authRequired
                              ? DropTheme.amber
                              : DropTheme.success,
                        ),
                        DropPill(
                          icon: Icons.group_rounded,
                          label: '$guests joined',
                          color: guests > 0
                              ? DropTheme.success
                              : DropTheme.muted,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: PrimaryButton(
                  label: 'Copy Drop Link',
                  icon: Icons.link_rounded,
                  onPressed: () => _copy(session.baseUrl, 'Drop Link copied'),
                ),
              ),
              const SizedBox(width: 10),
              DropIconButton(
                icon: Icons.qr_code_rounded,
                tonal: true,
                tooltip: 'Show Drop Code',
                onPressed: () => _showQrDialog(session),
              ),
              const SizedBox(width: 10),
              DropIconButton(
                icon: Icons.stop_rounded,
                tooltip: 'Stop room',
                onPressed: _stopRoom,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _webDavCard(DropRoomSession session) {
    final davUrl = '${session.baseUrl}/dav';
    final davDisplay = '${session.localIp}:${session.port}/dav';
    return DropCard.tinted(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LeadingTile(
                icon: Icons.desktop_windows_rounded,
                accent: DropTheme.orange,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Connect from desktop',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _miniTag('WEBDAV'),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Mount the room as a network drive.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _endpointInset(davDisplay, davUrl),
          const SizedBox(height: 14),
          const Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _WebDavClient(icon: Icons.laptop_mac_rounded, label: 'Finder'),
              _WebDavClient(icon: Icons.computer_rounded, label: 'Explorer'),
              _WebDavClient(icon: Icons.devices_rounded, label: 'Any client'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: DropTheme.orange.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(DropTheme.radiusPill),
        border: Border.all(color: DropTheme.orange.withValues(alpha: 0.30)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: DropTheme.orange,
          fontSize: 9.5,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _endpointInset(String display, String copyValue) {
    return SizedBox(
      height: 48,
      child: DropInset(
        color: DropTheme.black,
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            Expanded(
              child: MonoText(display, size: 13, color: DropTheme.white),
            ),
            IconButton(
              onPressed: () => _copy(copyValue, 'WebDAV URL copied'),
              icon: const Icon(Icons.copy_rounded, size: 18),
              color: DropTheme.orange,
              tooltip: 'Copy WebDAV URL',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _hostStatCards(DropRoomSession session) {
    final storage = _storage;
    final sharedBytes = session.usesExternalHostFolder
        ? (storage?.folderUsedBytes ?? storage?.roomUsedBytes)
        : storage?.roomUsedBytes;
    final sharedStr = storage == null
        ? '—'
        : (sharedBytes == null ? '—' : formatBytes(sharedBytes));
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DropCard(
              child: StatBlock(
                icon: Icons.swap_vert_rounded,
                value: sharedStr,
                label: 'Shared',
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropCard(child: _UptimeStat(since: session.createdAt)),
          ),
          if (session.expiresAt != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: DropCard(
                child: _ExpiryCountdownStat(expiresAt: session.expiresAt!),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fileTile(
    DropFileItem item, {
    required bool first,
    required bool selectionMode,
  }) {
    final isFolder = item.type == 'folder';
    final (color, icon) = _fileTypeStyle(item);
    final meta = isFolder
        ? 'Folder · ${_shortWhen(item.modifiedAt)}'
        : '${formatBytes(item.sizeBytes)} · ${_shortWhen(item.modifiedAt)}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selectionMode && _selectedLocalFile?.id == item.id
            ? DropTheme.orange.withValues(alpha: 0.08)
            : null,
        border: first
            ? null
            : const Border(top: BorderSide(color: DropTheme.line)),
      ),
      child: PressableScale(
        onTap: selectionMode
            ? () => setState(() => _selectedLocalFile = item)
            : isFolder
            ? () {
                setState(() => _libraryPath = item.path);
                unawaited(_loadLibraryFiles());
              }
            : () => unawaited(_openLibraryFile(item)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              LeadingTile(icon: icon, accent: color, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        if (item.streamable) ...[
                          const SizedBox(width: 8),
                          _miniBadge('Streamable', DropTheme.amber),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (isFolder)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: DropTheme.faint,
                  ),
                )
              else ...[
                IconButton(
                  onPressed: () => unawaited(_shareLibraryFile(item)),
                  icon: const Icon(Icons.ios_share_rounded, size: 19),
                  color: DropTheme.faint,
                  tooltip: 'Share',
                  visualDensity: VisualDensity.compact,
                ),
                PopupMenuButton<_LibraryFileAction>(
                  tooltip: 'File actions',
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: DropTheme.faint,
                  ),
                  onSelected: (action) {
                    switch (action) {
                      case _LibraryFileAction.open:
                        unawaited(_openLibraryFile(item));
                      case _LibraryFileAction.share:
                        unawaited(_shareLibraryFile(item));
                      case _LibraryFileAction.delete:
                        unawaited(_confirmDeleteLibraryFile(item));
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _LibraryFileAction.open,
                      child: ListTile(
                        leading: Icon(Icons.open_in_new_outlined),
                        title: Text('Open'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _LibraryFileAction.share,
                      child: ListTile(
                        leading: Icon(Icons.ios_share_outlined),
                        title: Text('Share'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _LibraryFileAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DropTheme.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0,
        ),
      ),
    );
  }

  Widget _libraryPathBar() {
    final atRoot = _libraryPath == '/';
    final label = atRoot
        ? _dropFolderLabel()
        : '${_dropFolderLabel()}$_libraryPath';
    return DropCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          const Icon(Icons.folder_rounded, color: DropTheme.orange, size: 18),
          const SizedBox(width: 10),
          Expanded(child: MonoText(label, size: 12.5, color: DropTheme.white)),
          const SizedBox(width: 8),
          Text(
            '${_files.length} item${_files.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (!atRoot)
            IconButton(
              onPressed: _libraryUpFolder,
              icon: const Icon(Icons.drive_folder_upload_outlined, size: 19),
              color: DropTheme.faint,
              tooltip: 'Up folder',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _manualJoinCard() {
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const LeadingTile(
                icon: Icons.link_rounded,
                accent: DropTheme.orange,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Join with a link',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _joinUrl,
            keyboardType: TextInputType.url,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontFamily: DropTheme.monoFont),
            decoration: const InputDecoration(
              hintText: 'http://192.168.1.23:8787',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PrimaryButton(
                  label: 'Join',
                  icon: Icons.login_rounded,
                  busy: _joining,
                  onPressed: _joining ? null : _previewJoinRoom,
                ),
              ),
              if (supportsNativeQrScanner) ...[
                const SizedBox(width: 10),
                TonalButton(
                  label: 'Scan QR',
                  icon: Icons.qr_code_scanner_rounded,
                  onPressed: _joining ? null : _scanDropCode,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _nearbyRoomsCard() {
    final rooms = _foundJoinRooms;
    return DropCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nearby rooms',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        rooms.isEmpty
                            ? (_nearbyDiscoveryMessage ??
                                  'Listening for advertised Drop Rooms')
                            : '${rooms.length} room${rooms.length == 1 ? '' : 's'} nearby',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                DropIconButton(
                  icon: Icons.refresh_rounded,
                  busy: _discoveringRooms,
                  size: 40,
                  tooltip: 'Discover nearby rooms',
                  onPressed: _discoveringRooms
                      ? null
                      : () => unawaited(_discoverNearbyRooms()),
                ),
              ],
            ),
          ),
          if (rooms.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 18),
              child: Row(
                children: [
                  const Icon(
                    Icons.radar_rounded,
                    color: DropTheme.faint,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Scan a Drop Code or paste a local link to add a room.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < rooms.length; i++)
              _nearbyRoomRow(rooms[i], first: i == 0),
        ],
      ),
    );
  }

  Widget _nearbyRoomRow(JoinRoomPreview preview, {required bool first}) {
    final active =
        _joinPreview?.baseUrl == preview.baseUrl && _joinSession != null;
    final state = active
        ? 'Joined'
        : preview.authRequired
        ? 'Password'
        : 'Open';
    return DecoratedBox(
      decoration: BoxDecoration(
        border: first
            ? null
            : const Border(top: BorderSide(color: DropTheme.line)),
      ),
      child: PressableScale(
        onTap: () => unawaited(_openJoinRoomDetail(preview)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              LeadingTile(
                icon: _roomIcon(preview),
                accent: active ? DropTheme.success : DropTheme.orange,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.roomName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$state · ${_roomPlatformLabel(preview)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const SignalMeter(bars: 3, color: DropTheme.success),
              const SizedBox(width: 12),
              TonalButton(
                label: 'Join',
                onPressed: () => unawaited(_openJoinRoomDetail(preview)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _rememberFoundRoom(JoinRoomPreview preview) {
    final existingIndex = _foundJoinRooms.indexWhere(
      (room) => room.baseUrl == preview.baseUrl,
    );
    if (existingIndex >= 0) {
      _foundJoinRooms[existingIndex] = preview;
      return;
    }
    _foundJoinRooms = [preview, ..._foundJoinRooms].take(5).toList();
  }

  Future<void> _discoverNearbyRooms({bool silent = false}) async {
    if (_discoveringRooms) return;
    _lastNearbyDiscovery = DateTime.now();
    _setJoinState(() {
      _discoveringRooms = true;
      if (!silent) {
        _nearbyDiscoveryMessage = null;
      }
    });
    try {
      final rooms = await _nearbyRoomService.discoverRooms();
      if (!mounted) return;
      final ownSession = _session;
      final visibleRooms = rooms
          .where(
            (room) =>
                ownSession?.id != room.roomId &&
                ownSession?.baseUrl != room.baseUrl,
          )
          .toList();
      _setJoinState(() {
        _foundJoinRooms = visibleRooms.take(5).toList();
        _nearbyDiscoveryMessage = visibleRooms.isEmpty
            ? 'No other Drop Rooms found on this network.'
            : 'Found ${visibleRooms.length} Drop Room${visibleRooms.length == 1 ? '' : 's'} nearby.';
      });
    } catch (error) {
      if (mounted) {
        _setJoinState(() {
          _nearbyDiscoveryMessage = 'Could not browse nearby rooms: $error';
        });
      }
    } finally {
      if (mounted) {
        _setJoinState(() => _discoveringRooms = false);
      }
    }
  }

  Future<void> _openJoinRoomDetail(JoinRoomPreview preview) async {
    _setJoinState(() {
      if (_joinPreview?.baseUrl != preview.baseUrl) {
        _joinSession = null;
        _joinItems = <DropFileItem>[];
        _joinPath = _initialJoinPath(preview);
        _joinActivity = null;
        _joinTransfer = null;
        _joinPassword.clear();
      }
      _joinPreview = preview;
      _rememberFoundRoom(preview);
    });

    if (preview.authRequired) {
      final password = await _promptJoinPassword(preview);
      if (!mounted || password == null) return;
      _joinPassword.text = password;
    }

    final joined = await _loginJoinRoom();
    if (!mounted || !joined) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: _joinUiVersion,
          builder: (context, _, _) {
            final activePreview = _joinPreview ?? preview;
            return _JoinedRoomDetailScreen(
              preview: activePreview,
              session: _joinSession,
              path: _joinPath,
              items: _joinItems,
              activity: _joinActivity,
              transfer: _joinTransfer,
              joining: _joining,
              passwordController: _joinPassword,
              folderNameController: _joinFolderName,
              textTitleController: _joinTextTitle,
              textBodyController: _joinTextBody,
              onJoin: () async {
                await _loginJoinRoom();
              },
              onRefresh: _loadJoinedFiles,
              onUpFolder: _joinedUpFolder,
              onUploadFiles: _pickAndUploadJoinedFiles,
              onCreateFolder: _createJoinedFolder,
              onSendText: _sendJoinedText,
              onFolderTap: (item) {
                _setJoinState(() => _joinPath = item.path);
                unawaited(_loadJoinedFiles());
              },
              onDownload: _downloadJoinedFile,
              onPullToHost: _server.isRunning ? _pullJoinedFileIntoRoom : null,
              transferBuilder: _transferPanel,
            );
          },
        ),
      ),
    );
    _disconnectJoinedRoom(preview);
  }

  Future<String?> _promptJoinPassword(JoinRoomPreview preview) async {
    _joinPassword.clear();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(preview.roomName),
          content: TextField(
            controller: _joinPassword,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Room password'),
            onSubmitted: (value) {
              final password = value.trim();
              if (password.isNotEmpty) {
                Navigator.of(context).pop(password);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final password = _joinPassword.text.trim();
                if (password.isNotEmpty) {
                  Navigator.of(context).pop(password);
                }
              },
              child: const Text('Join'),
            ),
          ],
        );
      },
    );
  }

  void _disconnectJoinedRoom(JoinRoomPreview preview) {
    if (_joinPreview?.baseUrl != preview.baseUrl) return;
    _setJoinState(() {
      _joinPreview = null;
      _joinSession = null;
      _joinItems = <DropFileItem>[];
      _joinPath = '/';
      _joinActivity = null;
      _joinTransfer = null;
      _joinPassword.clear();
    });
  }

  String _initialJoinPath(JoinRoomPreview preview) {
    return preview.scopedToDefaultFolder
        ? preview.scopePath
        : preview.defaultUploadPath;
  }

  IconData _roomIcon(JoinRoomPreview preview) {
    final platform = preview.devicePlatform.toLowerCase();
    final type = preview.deviceType.toLowerCase();
    if (platform.contains('android')) return Icons.android;
    if (platform.contains('ios')) return Icons.phone_iphone;
    if (type.contains('phone')) return Icons.smartphone_outlined;
    if (platform.contains('mac')) return Icons.laptop_mac_outlined;
    if (platform.contains('windows') || platform.contains('linux')) {
      return Icons.computer_outlined;
    }
    return Icons.devices_other_outlined;
  }

  String _roomPlatformLabel(JoinRoomPreview preview) {
    final platform = preview.devicePlatform.toLowerCase();
    if (platform.contains('android')) return 'Android phone';
    if (platform.contains('ios')) return 'iPhone';
    if (platform.contains('mac')) return 'Mac';
    if (platform.contains('windows')) return 'Windows';
    if (platform.contains('linux')) return 'Linux';
    return preview.deviceType.isEmpty ? 'Local device' : preview.deviceType;
  }

  Widget _transferPanel(TransferProgress transfer) {
    final progress = transfer.progress;
    final speed = transfer.speedBytesPerSecond <= 0
        ? 'Calculating...'
        : '${formatBytes(transfer.speedBytesPerSecond.round())}/s';
    final eta = transfer.completed
        ? 'Done'
        : transfer.eta == null
        ? 'ETA unavailable'
        : _formatEta(transfer.eta!);
    final total = transfer.totalBytes <= 0
        ? formatBytes(transfer.sentBytes)
        : '${formatBytes(transfer.sentBytes)} / ${formatBytes(transfer.totalBytes)}';
    return DropInset(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                transfer.direction == TransferDirection.upload
                    ? Icons.upload_rounded
                    : Icons.download_rounded,
                color: DropTheme.orange,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  transfer.title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (progress != null)
                Text(
                  '${(progress * 100).clamp(0, 100).round()}%',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontFamily: DropTheme.monoFont,
                    color: DropTheme.orange,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: progress, minHeight: 6),
          ),
          const SizedBox(height: 8),
          Text(
            '$total · $speed · $eta',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (transfer.detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(transfer.detail, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _networkPanel() {
    final status = _networkStatus;
    final isReady = status.isReady;
    final icon = isReady
        ? status.isHotspot
              ? Icons.wifi_tethering
              : Icons.network_wifi_outlined
        : Icons.wifi_tethering_error_outlined;
    final title = _networkLoading
        ? 'Checking network'
        : isReady
        ? 'Creating over ${status.label}'
        : 'Create a hotspot first';
    final description = _networkLoading
        ? 'Looking for Wi-Fi or an active hotspot.'
        : isReady
        ? 'Guests must join the same ${status.label} network.'
        : 'Turn on a phone hotspot, connect guests, then refresh.';
    final guideLabel = Platform.isIOS
        ? 'Personal Hotspot Guide'
        : 'Hotspot Guide';
    final accent = isReady
        ? (status.isHotspot ? DropTheme.amber : DropTheme.success)
        : DropTheme.amber;
    return DropCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LeadingTile(icon: icon, accent: accent, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _networkLoading
                    ? null
                    : () => unawaited(_refreshNetworkStatus()),
                icon: const Icon(Icons.refresh_rounded),
                color: DropTheme.faint,
                tooltip: 'Refresh network',
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_networkLoading)
            Row(
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  'Checking network…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            )
          else if (isReady)
            DropPill(
              icon: Icons.check_circle_rounded,
              label: status.label,
              color: accent,
            )
          else
            TonalButton(
              label: guideLabel,
              icon: Icons.help_outline_rounded,
              color: DropTheme.amber,
              onPressed: _showManualHotspotGuide,
            ),
        ],
      ),
    );
  }

  Future<void> _showStartRoomSheet() async {
    unawaited(_refreshNetworkStatus());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return ValueListenableBuilder<int>(
              valueListenable: _networkUiVersion,
              builder: (context, _, _) {
                final passwordRequiredButEmpty =
                    _usePassword && _password.text.trim().isEmpty;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    MediaQuery.of(context).viewInsets.bottom + 14,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Start Drop Room',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Guests on the same network can join from the app or a browser.',
                        ),
                        const SizedBox(height: 16),
                        _networkPanel(),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _roomName,
                          decoration: const InputDecoration(labelText: 'Room'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _deviceName,
                          decoration: const InputDecoration(labelText: 'User'),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Password Room'),
                          value: _usePassword,
                          onChanged: (value) {
                            setSheetState(() => _usePassword = value);
                            setState(() => _usePassword = value);
                          },
                        ),
                        if (_usePassword)
                          TextField(
                            controller: _password,
                            obscureText: true,
                            onChanged: (_) => setSheetState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Room password',
                              helperText: 'Required for password rooms.',
                            ),
                          ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<RoomPermission>(
                          initialValue: _permission,
                          decoration: const InputDecoration(
                            labelText: 'Permissions',
                            helperText:
                                'Drop folder only keeps guests inside the selected folder.',
                          ),
                          items: RoomPermission.values
                              .map(
                                (permission) => DropdownMenuItem(
                                  value: permission,
                                  child: Text(permission.label),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setSheetState(() => _permission = value);
                            setState(() => _permission = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _dropFolderStartCard(setSheetState),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Burn Mode'),
                          subtitle: const Text(
                            'Auto-expire this room after 2 hours.',
                          ),
                          value: _burnMode,
                          onChanged: (value) {
                            setSheetState(() => _burnMode = value);
                            setState(() => _burnMode = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        PrimaryButton(
                          label: 'Start Room',
                          icon: _networkStatus.isHotspot
                              ? Icons.wifi_tethering_rounded
                              : Icons.wifi_rounded,
                          busy: _starting,
                          onPressed:
                              _starting ||
                                  passwordRequiredButEmpty ||
                                  !_networkStatus.isReady
                              ? null
                              : () async {
                                  final navigator = Navigator.of(context);
                                  final started = await _startRoom();
                                  if (mounted && started) navigator.pop();
                                },
                        ),
                        if (passwordRequiredButEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Enter a password or turn off Password Room.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ] else if (!_networkStatus.isReady) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Connect to Wi-Fi or create a hotspot first.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<bool> _startRoom() async {
    final password = _password.text.trim();
    if (_usePassword && password.isEmpty) {
      _snack('Enter a room password or turn off Password Room.');
      return false;
    }
    setState(() => _starting = true);
    try {
      await _refreshNetworkStatus();
      if (!_networkStatus.isReady) {
        _snack('Connect to Wi-Fi or create a hotspot first.');
        _showManualHotspotGuide();
        return false;
      }
      final canStart = await _ensureDropFolderChoice();
      if (!canStart) return false;
      final session = await _server.start(
        DropRoomConfig(
          name: _roomName.text,
          deviceName: _deviceName.text,
          password: _usePassword ? password : '',
          permission: _permission,
          burnMode: _burnMode,
          expiry: _burnMode ? const Duration(hours: 2) : null,
          defaultUploadPath: _defaultUploadPath,
          hostFolderUri: _hostFolderSelection?.uri,
          hostFolderName: _hostFolderSelection?.name,
          hostFolderPlatform: _hostFolderSelection?.platform,
        ),
      );
      _syncDesktopTray();
      await _roomRuntimeService.setKeepAwake(enabled: true);
      await _roomRuntimeService.startForegroundRoom(
        roomName: session.name,
        baseUrl: session.baseUrl,
      );
      await _roomRuntimeService.publishMdnsRoom(session);
      await _refreshRoomData();
      if (mounted) {
        _snack('Drop Room is live');
      }
      return true;
    } catch (error) {
      if (mounted) {
        _snack('Could not start room: $error');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  void _showManualHotspotGuide() {
    final hotspotName = Platform.isIOS
        ? 'Personal Hotspot'
        : 'Portable Hotspot';
    final title = Platform.isIOS ? 'Personal Hotspot Guide' : 'Hotspot Guide';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Open system Settings.'),
            const SizedBox(height: 8),
            Text('2. Enable $hotspotName.'),
            const SizedBox(height: 8),
            const Text('3. Connect guests to that hotspot.'),
            const SizedBox(height: 8),
            const Text('4. Return here and tap Start Room.'),
            const SizedBox(height: 8),
            const Text('5. Keep Erebrus Drop open during transfers.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleBackNavigation() async {
    if (_backDialogOpen || !mounted) return;
    _backDialogOpen = true;
    try {
      final action = await _showBackActionDialog();
      if (!mounted || action == null) return;
      switch (action) {
        case _BackAction.background:
          await _moveAppToBackground();
        case _BackAction.close:
          await _closeAppFromBack();
      }
    } finally {
      _backDialogOpen = false;
    }
  }

  Future<_BackAction?> _showBackActionDialog() {
    final hosting = _server.isRunning;
    final canBackground = !Platform.isIOS;
    final desktopTray = isDesktopPlatform;
    return showDialog<_BackAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          hosting
              ? Platform.isIOS
                    ? 'Keep Drop Room open?'
                    : 'Keep Drop Room running?'
              : 'Close Erebrus Drop?',
        ),
        content: Text(
          hosting
              ? Platform.isIOS
                    ? 'The screen stays awake while this room is active. Keep Erebrus Drop open while guests transfer; iOS pauses local hosting if the app is backgrounded. Closing the app will stop the room.'
                    : desktopTray
                    ? 'A Drop Room is active. Minimize to the menu bar tray to keep hosting, or quit to stop the room and disconnect guests.'
                    : 'A Drop Room is active. You can keep Erebrus Drop running in the background so guests can continue transfers. Closing the app will stop the room and disconnect guests.'
              : desktopTray
              ? 'Erebrus Drop can stay in the menu bar tray while hosting or joining. Quit from the tray menu to exit completely.'
              : Platform.isIOS
              ? 'Close Erebrus Drop?'
              : 'You can keep Erebrus Drop in the background or close the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_BackAction.close),
            child: Text(
              hosting
                  ? 'Stop Room & Quit'
                  : desktopTray
                  ? 'Quit App'
                  : 'Close App',
            ),
          ),
          if (canBackground)
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_BackAction.background),
              child: Text(
                hosting
                    ? desktopTray
                          ? 'Minimize to Tray'
                          : 'Keep Hosting'
                    : desktopTray
                    ? 'Minimize to Tray'
                    : 'Background',
              ),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep Open'),
            ),
        ],
      ),
    );
  }

  Future<void> _moveAppToBackground() async {
    if (isDesktopPlatform) {
      await DesktopShell.instance.hideToTray();
      return;
    }
    try {
      await _roomRuntimeService.moveAppToBackground();
    } on PlatformException {
      await SystemNavigator.pop();
    }
  }

  Future<void> _desktopQuit() async {
    if (_server.isRunning) {
      await _stopRoom();
    }
  }

  Future<void> _closeAppFromBack() async {
    if (isDesktopPlatform) {
      await DesktopShell.instance.quit();
      return;
    }
    if (_server.isRunning) {
      await _stopRoom();
    }
    await SystemNavigator.pop();
  }

  Future<void> _stopRoom() => _teardownRoom(message: 'Drop Room stopped');

  /// Auto-expiry teardown for a burn-mode room whose deadline has passed.
  void _handleRoomExpired() {
    if (!_server.isRunning) return;
    unawaited(
      _teardownRoom(message: 'Drop Room expired — burn mode ended the session'),
    );
  }

  Future<void> _teardownRoom({required String message}) async {
    if (_stoppingRoom) return;
    _stoppingRoom = true;
    try {
      await _roomRuntimeService.setKeepAwake(enabled: false);
      await _roomRuntimeService.stopMdnsRoom();
      await _roomRuntimeService.stopForegroundRoom();
      await _server.stop();
      _syncDesktopTray();
      if (!mounted) return;
      setState(() {
        _storage = null;
        _files = <DropFileItem>[];
        _libraryPath = '/';
      });
      unawaited(_loadLibraryFiles());
      _snack(message);
    } finally {
      _stoppingRoom = false;
    }
  }

  Future<void> _refreshRoomData() async {
    if (!_server.isRunning || _refreshingRoomData) return;
    _refreshingRoomData = true;
    try {
      final storage = await _server.storageSnapshot();
      final files = await _server.listFiles(_libraryPath);
      if (!mounted) return;
      setState(() {
        _storage = storage;
        _files = files;
        _libraryError = null;
      });
    } catch (_) {
      // Upload temp files can move while storage is being measured.
      // The next periodic refresh will pick up the settled state.
    } finally {
      _refreshingRoomData = false;
    }
  }

  Future<void> _loadLibraryFiles() async {
    if (_loadingLibraryFiles) return;
    if (mounted) {
      setState(() {
        _loadingLibraryFiles = true;
        _libraryError = null;
      });
    }
    try {
      if (_server.isRunning) {
        await _refreshRoomData();
        return;
      }
      final selection = _hostFolderSelection;
      if (selection == null) {
        if (!mounted) return;
        setState(() {
          _files = <DropFileItem>[];
          _libraryError = null;
        });
        return;
      }
      final items = await _hostFolderBridge.list(
        rootUri: selection.uri,
        path: _libraryPath,
      );
      if (!mounted) return;
      setState(() {
        _files = items.map(_dropFileItemFromHostFolderItem).toList();
        _libraryError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _files = <DropFileItem>[];
        _libraryError = error.message ?? 'Could not read the selected folder.';
      });
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _files = <DropFileItem>[];
        _libraryError = 'Folder browsing is not available on this build.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _files = <DropFileItem>[];
        _libraryError = 'Could not read the selected folder: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingLibraryFiles = false);
      }
    }
  }

  void _libraryUpFolder() {
    if (_libraryPath == '/') return;
    final parts = _libraryPath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    parts.removeLast();
    setState(() {
      _libraryPath = parts.isEmpty ? '/' : '/${parts.join('/')}';
      _selectedLocalFile = null;
    });
    unawaited(_loadLibraryFiles());
  }

  Future<void> _saveSmartText() async {
    if (_smartText.text.trim().isEmpty) {
      _snack('Paste or type text first');
      return;
    }
    if (_server.isRunning) {
      await _server.saveTextSnippet(
        title: _smartTitle.text,
        body: _smartText.text,
      );
    } else {
      final selection = _hostFolderSelection;
      if (selection == null) {
        _snack('Choose a Drop folder first');
        return;
      }
      await _saveTextToHostFolder(
        selection: selection,
        title: _smartTitle.text,
        body: _smartText.text,
      );
      await _loadLibraryFiles();
    }
    _smartText.clear();
    await _refreshRoomData();
    _snack('Text saved to the Drop folder');
  }

  String _dropFolderLabel() {
    final session = _session;
    if (session?.usesExternalHostFolder == true) {
      return session!.hostFolderName ?? 'selected folder';
    }
    final selection = _hostFolderSelection;
    if (selection != null) {
      return selection.name;
    }
    return 'No Drop folder selected';
  }

  Future<void> _openLibraryFile(DropFileItem item) async {
    try {
      final selection = _hostFolderSelection;
      if (_server.isRunning) {
        await _server.openFile(item);
      } else if (selection != null) {
        await _hostFolderBridge.openFile(
          rootUri: selection.uri,
          path: item.path,
        );
      } else {
        _snack('Select a Drop folder first.');
      }
    } on FileSystemException catch (error) {
      _snack(error.message);
    } on PlatformException catch (error) {
      _snack(error.message ?? 'Could not open ${item.name}');
    } on MissingPluginException {
      _snack(
        'File opening needs the latest native build. Stop the app and run a fresh build, then try again.',
      );
    } catch (error) {
      _snack('Could not open ${item.name}: $error');
    }
  }

  Future<void> _shareLibraryFile(DropFileItem item) async {
    try {
      final selection = _hostFolderSelection;
      if (item.type == 'folder') {
        _snack('Share a file, not a folder.');
      } else if (_server.isRunning) {
        await _server.shareFile(item);
      } else if (selection != null) {
        await _hostFolderBridge.shareFile(
          rootUri: selection.uri,
          path: item.path,
        );
      } else {
        _snack('Select a Drop folder first.');
      }
    } on FileSystemException catch (error) {
      _snack(error.message);
    } on PlatformException catch (error) {
      _snack(error.message ?? 'Could not share ${item.name}');
    } on MissingPluginException {
      _snack(
        'File sharing needs the latest native build. Stop the app and run a fresh build, then try again.',
      );
    } catch (error) {
      _snack('Could not share ${item.name}: $error');
    }
  }

  Future<void> _confirmDeleteLibraryFile(DropFileItem item) async {
    if (item.type == 'folder') {
      _snack('Delete a file, not a folder.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('Delete ${item.name}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: DropTheme.danger,
              foregroundColor: DropTheme.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteLibraryFile(item);
    }
  }

  Future<void> _deleteLibraryFile(DropFileItem item) async {
    try {
      final selection = _hostFolderSelection;
      if (_server.isRunning) {
        await _server.deleteFile(item);
        await _refreshRoomData();
      } else if (selection != null) {
        await _hostFolderBridge.deleteFile(
          rootUri: selection.uri,
          path: item.path,
        );
        await _loadLibraryFiles();
      } else {
        _snack('Select a Drop folder first.');
        return;
      }
      if (mounted) {
        setState(() => _selectedLocalFile = null);
        _snack('${item.name} deleted');
      }
    } on FileSystemException catch (error) {
      _snack(error.message);
    } on PlatformException catch (error) {
      _snack(error.message ?? 'Could not delete ${item.name}');
    } on MissingPluginException {
      _snack(
        'File deletion needs the latest native build. Stop the app and run a fresh build, then try again.',
      );
    } catch (error) {
      _snack('Could not delete ${item.name}: $error');
    }
  }

  DropFileItem _dropFileItemFromHostFolderItem(HostFolderItem item) {
    final isDirectory = item.type == 'folder';
    final mimeType = isDirectory
        ? null
        : item.mimeType ?? _mimeTypeForName(item.name);
    return DropFileItem(
      id: item.path,
      name: item.name,
      type: isDirectory ? 'folder' : 'file',
      path: _normalizeLibraryPath(item.path),
      sizeBytes: isDirectory ? 0 : item.sizeBytes,
      createdAt: item.modifiedAt,
      modifiedAt: item.modifiedAt,
      mimeType: mimeType,
      streamable: _isStreamableMime(mimeType),
    );
  }

  bool _isStreamableMime(String? mimeType) {
    return mimeType?.startsWith('video/') == true ||
        mimeType?.startsWith('audio/') == true;
  }

  String _normalizeLibraryPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == '/') {
      return '/';
    }
    final withSlash = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return withSlash.length > 1 && withSlash.endsWith('/')
        ? withSlash.substring(0, withSlash.length - 1)
        : withSlash;
  }

  String _mimeTypeForName(String name) {
    final extension = name.split('.').last.toLowerCase();
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'log':
      case 'md':
        return 'text/plain';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'm4v':
        return 'video/x-m4v';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _previewJoinRoom() async {
    _setJoinState(() => _joining = true);
    try {
      final preview = await _joinRoomService.preview(_joinUrl.text);
      if (!mounted) return;
      _setJoinState(() {
        _joinPreview = preview;
        _joinSession = null;
        _joinItems = <DropFileItem>[];
        _joinPath = _initialJoinPath(preview);
        _joinActivity = null;
        _joinTransfer = null;
        _rememberFoundRoom(preview);
      });
      _snack('Found ${preview.roomName}');
    } catch (error) {
      if (mounted) _snack('Could not find room: $error');
    } finally {
      if (mounted) _setJoinState(() => _joining = false);
    }
  }

  Future<bool> _loginJoinRoom() async {
    final preview = _joinPreview;
    if (preview == null) {
      await _previewJoinRoom();
      return false;
    }
    _setJoinState(() => _joining = true);
    try {
      final joinSession = await _joinRoomService.login(
        baseUrl: preview.baseUrl,
        password: preview.authRequired ? _joinPassword.text : '',
      );
      if (!mounted) return false;
      _setJoinState(() {
        _joinSession = joinSession;
        _joinPath = _initialJoinPath(preview);
      });
      _snack('Joined ${preview.roomName}');
      await _loadJoinedFiles();
      return true;
    } catch (error) {
      if (mounted) _snack('Could not join room: $error');
      return false;
    } finally {
      if (mounted) _setJoinState(() => _joining = false);
    }
  }

  Future<void> _scanDropCode() async {
    final scannedUrl = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (scannedUrl == null || scannedUrl.trim().isEmpty) return;
    _setJoinState(() {
      _tab = 1;
      _joinUrl.text = scannedUrl;
      _joinPreview = null;
      _joinSession = null;
      _joinItems = <DropFileItem>[];
      _joinPath = '/';
    });
    await _previewJoinRoom();
  }

  Future<void> _loadJoinedFiles() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null) return;
    _setJoinState(() => _joinActivity = 'Loading remote files...');
    try {
      final items = await _joinRoomService.listFiles(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        path: _joinPath,
      );
      if (!mounted) return;
      _setJoinState(() {
        _joinItems = items;
        _joinActivity = null;
      });
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinActivity = 'Could not load files: $error');
      }
    }
  }

  Future<void> _createJoinedFolder() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    final folderName = _joinFolderName.text.trim();
    if (preview == null || joinSession == null || folderName.isEmpty) return;
    try {
      await _joinRoomService.createFolder(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        path: _joinPath == '/' ? '/$folderName' : '$_joinPath/$folderName',
      );
      _joinFolderName.clear();
      await _loadJoinedFiles();
      _snack('Folder created');
    } catch (error) {
      if (mounted) _snack('Could not create folder: $error');
    }
  }

  Future<void> _sendJoinedText() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null ||
        joinSession == null ||
        _joinTextBody.text.trim().isEmpty) {
      return;
    }
    try {
      await _joinRoomService.sendText(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        title: _joinTextTitle.text,
        body: _joinTextBody.text,
      );
      _joinTextBody.clear();
      await _loadJoinedFiles();
      _snack('Text sent to joined room');
    } catch (error) {
      if (mounted) _snack('Could not send text: $error');
    }
  }

  Future<void> _downloadJoinedFile(DropFileItem item) async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null) return;
    final stopwatch = Stopwatch()..start();
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final saved = await _joinRoomService.downloadFile(
        baseUrl: preview.baseUrl,
        token: joinSession.token,
        item: item,
        onProgress: (received, total) {
          if (!mounted) return;
          final now = DateTime.now();
          if (now.difference(lastUpdate).inMilliseconds < 250 &&
              received != total) {
            return;
          }
          lastUpdate = now;
          final elapsed = math.max(stopwatch.elapsedMilliseconds / 1000, 0.001);
          final speed = received / elapsed;
          _setJoinState(
            () => _joinTransfer = TransferProgress(
              direction: TransferDirection.download,
              title: 'Downloading ${item.name}',
              detail: 'Saving to this device',
              sentBytes: received,
              totalBytes: total < 0 ? 0 : total,
              speedBytesPerSecond: speed,
            ),
          );
        },
      );
      if (!mounted) return;
      _setJoinState(() {
        _joinTransfer = TransferProgress.complete(
          direction: TransferDirection.download,
          title: 'Downloaded ${saved.name}',
          detail: 'Saved to ${saved.location}',
          totalBytes: item.sizeBytes,
        );
        _joinActivity = null;
      });
      _snack('Saved to ${saved.location}');
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinTransfer = null);
        _snack('Could not download file: $error');
      }
    }
  }

  Future<void> _pullJoinedFileIntoRoom(DropFileItem item) async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null || !_server.isRunning) return;
    final stopwatch = Stopwatch()..start();
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _server.pullFileFromRoom(
        sourceBaseUrl: preview.baseUrl,
        sourceToken: joinSession.token,
        item: item,
        destinationPath: _defaultUploadPath,
        onProgress: (received, total) {
          if (!mounted) return;
          final now = DateTime.now();
          if (now.difference(lastUpdate).inMilliseconds < 250 &&
              received != total) {
            return;
          }
          lastUpdate = now;
          final elapsed = math.max(stopwatch.elapsedMilliseconds / 1000, 0.001);
          _setJoinState(
            () => _joinTransfer = TransferProgress(
              direction: TransferDirection.download,
              title: 'Pulling ${item.name}',
              detail: 'Saving into your live room',
              sentBytes: received,
              totalBytes: total < 0 ? item.sizeBytes : total,
              speedBytesPerSecond: received / elapsed,
            ),
          );
        },
      );
      if (!mounted) return;
      _setJoinState(() {
        _joinTransfer = TransferProgress.complete(
          direction: TransferDirection.download,
          title: 'Pulled ${item.name}',
          detail: 'Saved to your Drop Room',
          totalBytes: item.sizeBytes,
        );
      });
      await _refreshRoomData();
      _snack('Pulled ${item.name} into your room');
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinTransfer = null);
        _snack('Could not pull file: $error');
      }
    }
  }

  Future<void> _pickAndUploadJoinedFiles() async {
    final preview = _joinPreview;
    final joinSession = _joinSession;
    if (preview == null || joinSession == null) return;
    final pickedFiles = await _nativeFilePickerService.pickFilesForUpload();
    if (pickedFiles.isEmpty) return;
    final totalBytes = pickedFiles.fold<int>(
      0,
      (sum, file) => sum + file.sizeBytes,
    );
    final stopwatch = Stopwatch()..start();
    var uploadedBeforeCurrent = 0;
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      for (var index = 0; index < pickedFiles.length; index++) {
        final picked = pickedFiles[index];
        final fileName = picked.name;
        await _joinRoomService.uploadFile(
          baseUrl: preview.baseUrl,
          token: joinSession.token,
          path: _joinPath,
          file: File(picked.path),
          fileName: fileName,
          onProgress: (sent, total) {
            if (!mounted) return;
            final overallSent = uploadedBeforeCurrent + sent;
            final now = DateTime.now();
            if (now.difference(lastUpdate).inMilliseconds < 250 &&
                sent != total) {
              return;
            }
            lastUpdate = now;
            final elapsed = math.max(
              stopwatch.elapsedMilliseconds / 1000,
              0.001,
            );
            final speed = overallSent / elapsed;
            _setJoinState(
              () => _joinTransfer = TransferProgress(
                direction: TransferDirection.upload,
                title: 'Uploading ${index + 1}/${pickedFiles.length} $fileName',
                detail: 'Target $_joinPath',
                sentBytes: overallSent,
                totalBytes: totalBytes,
                speedBytesPerSecond: speed,
              ),
            );
          },
        );
        uploadedBeforeCurrent += picked.sizeBytes;
      }
      if (!mounted) return;
      _setJoinState(() {
        _joinTransfer = TransferProgress.complete(
          direction: TransferDirection.upload,
          title: 'Uploaded ${pickedFiles.length} file(s)',
          detail: 'Saved to $_joinPath',
          totalBytes: totalBytes,
        );
        _joinActivity = null;
      });
      await _loadJoinedFiles();
    } catch (error) {
      if (mounted) {
        _setJoinState(() => _joinTransfer = null);
        _snack('Could not upload files: $error');
      }
    }
  }

  void _joinedUpFolder() {
    if (_joinPath == '/') return;
    final preview = _joinPreview;
    final scopedRoot = preview?.scopedToDefaultFolder == true
        ? preview!.scopePath
        : '/';
    if (_joinPath == scopedRoot) return;
    final parts = _joinPath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    parts.removeLast();
    final nextPath = parts.isEmpty ? '/' : '/${parts.join('/')}';
    _setJoinState(
      () => _joinPath =
          preview?.scopedToDefaultFolder == true &&
              (nextPath == '/' || !nextPath.startsWith(scopedRoot))
          ? scopedRoot
          : nextPath,
    );
    unawaited(_loadJoinedFiles());
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null || data!.text!.isEmpty) {
      _snack('Clipboard is empty');
      return;
    }
    _smartText.text = data.text!;
  }

  Future<void> _pickAndAddFiles() async {
    final picked = await _nativeFilePickerService.pickFilesForUpload();
    final paths = picked
        .map((file) => file.path)
        .where((path) => path.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;

    if (_smartSendScopeIndex == 1) {
      await _uploadDroppedFilesToGateway(paths);
    } else {
      await _handleSharedPayload(SharedPayload(filePaths: paths));
    }
  }

  String? _extractUrl(String value) {
    final match = RegExp(r'https?://[^\s]+').firstMatch(value.trim());
    if (match == null) return null;
    final url = match.group(0);
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return url;
  }

  Future<void> _showAddLinkDialog() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;

    final clipboardUrl = _extractUrl(data?.text ?? '');
    final controller = TextEditingController(text: clipboardUrl ?? '');

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final hasClipboardUrl = _extractUrl(data?.text ?? '') != null;
          return AlertDialog(
            backgroundColor: DropTheme.black,
            title: const Text('Send a link'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'https://...',
                labelText: 'URL',
              ),
              onChanged: (_) => setDialogState(() {}),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: hasClipboardUrl
                    ? () {
                        final pasted = _extractUrl(data?.text ?? '');
                        if (pasted != null) {
                          controller.text = pasted;
                          setDialogState(() {});
                        }
                      }
                    : null,
                child: const Text('Paste from clipboard'),
              ),
              FilledButton(
                onPressed: controller.text.trim().isNotEmpty
                    ? () => Navigator.of(ctx).pop(controller.text.trim())
                    : null,
                child: const Text('Add to composer'),
              ),
            ],
          );
        },
      ),
    );

    controller.dispose();
    if (result == null || !mounted) return;

    final url = _extractUrl(result);
    if (url == null) {
      _snack('Enter a valid http or https URL');
      return;
    }

    if (_smartText.text.trim().isEmpty) {
      _smartTitle.text = 'Link';
      _smartText.text = url;
    } else {
      if (_smartTitle.text.trim().isEmpty) {
        _smartTitle.text = 'Link';
      }
      final current = _smartText.text.trim();
      _smartText.text = '$current\n$url';
    }
    _snack('Link added to composer');
  }

  Future<void> _handleSharedPayload(SharedPayload payload) async {
    if (payload.isEmpty || !mounted) return;
    if (_loadingHostFolderSelection) {
      await _loadHostFolderSelection();
    }
    final text = payload.text?.trim();
    var importedFiles = 0;
    var importedText = false;
    final selection = _hostFolderSelection;
    if (text != null && text.isNotEmpty) {
      _smartTitle.text = 'Shared text';
      _smartText.text = text;
      if (_server.isRunning) {
        await _server.saveTextSnippet(
          title: _smartTitle.text,
          body: text,
          source: 'share_sheet',
        );
        importedText = true;
      } else if (selection != null) {
        await _saveTextToHostFolder(
          selection: selection,
          title: _smartTitle.text,
          body: text,
        );
        importedText = true;
      }
    }
    if (payload.filePaths.isNotEmpty) {
      for (final path in payload.filePaths) {
        final file = File(path);
        if (!await file.exists()) continue;
        if (_server.isRunning) {
          await _server.importLocalFile(
            file: file,
            name: file.uri.pathSegments.isEmpty
                ? 'shared-file'
                : file.uri.pathSegments.last,
          );
        } else if (selection != null) {
          await _hostFolderBridge.copyFileInto(
            rootUri: selection.uri,
            folderPath: '/',
            sourcePath: file.path,
            name: file.uri.pathSegments.isEmpty
                ? 'shared-file'
                : file.uri.pathSegments.last,
            mimeType: _mimeTypeForName(file.path),
          );
        } else {
          continue;
        }
        importedFiles++;
      }
    }
    if (_server.isRunning) {
      await _refreshRoomData();
    } else if (selection != null) {
      await _loadLibraryFiles();
    }
    if (!mounted) return;
    if (importedFiles > 0 || importedText) {
      final pieces = <String>[
        if (importedFiles > 0) '$importedFiles file(s)',
        if (importedText) 'text',
      ];
      _snack('Added ${pieces.join(' and ')} to the Drop folder');
      setState(() => _tab = 2);
    } else if (text != null && text.isNotEmpty) {
      _snack('Choose a Drop folder to save shared content');
      setState(() => _tab = 3);
    } else {
      _snack('Choose a Drop folder to save shared files');
      setState(() => _tab = 2);
    }
  }

  Future<void> _saveTextToHostFolder({
    required HostFolderSelection selection,
    required String title,
    required String body,
  }) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final safeTitle = _safeSharedName(
      title.trim().isEmpty ? 'Shared text' : title,
    );
    final temp = File('${Directory.systemTemp.path}/$timestamp-$safeTitle.txt');
    await temp.writeAsString(body);
    try {
      await _hostFolderBridge.copyFileInto(
        rootUri: selection.uri,
        folderPath: '/',
        sourcePath: temp.path,
        name: temp.uri.pathSegments.last,
        mimeType: 'text/plain',
      );
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  String _safeSharedName(String value) {
    final safe = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.isEmpty ? 'shared-file' : safe;
  }

  Future<bool> _selectHostFolder() async {
    setState(() => _hostFolderBusy = true);
    try {
      final selection = await _hostFolderService.selectHostFolder();
      if (!mounted) return false;
      if (selection == null) {
        _snack('No Drop folder selected.');
        return false;
      }
      setState(() {
        _hostFolderSelection = selection;
        _libraryPath = '/';
        _libraryError = null;
      });
      try {
        await _hostFolderService.saveSelection(selection);
      } on Object {
        if (mounted) {
          _snack(
            'Selected for this session. Could not save folder permission.',
          );
        }
      }
      if (_server.isRunning) {
        await _server.updateHostFolder(
          hostFolderUri: selection.uri,
          hostFolderName: selection.name,
          hostFolderPlatform: selection.platform,
        );
      }
      await _loadLibraryFiles();
      if (mounted) {
        _snack('Selected ${selection.name}');
      }
      return true;
    } on PlatformException catch (error) {
      if (mounted) {
        if (Platform.isIOS && error.code == 'PICK_FOLDER_UNAVAILABLE') {
          _snack(
            'The iOS Files picker is not active in this installed build. Stop the app and run a fresh iOS build, then try again.',
          );
        } else {
          _snack(error.message ?? 'Could not select a host folder');
        }
      }
      return false;
    } on MissingPluginException {
      if (mounted) {
        _snack(
          'Folder selection needs the latest native build. Stop the app and run a fresh build, then try again.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _hostFolderBusy = false);
    }
  }

  Future<void> _forgetHostFolderSelection() async {
    if (_server.isRunning) {
      _snack('Stop the active room before forgetting the Drop folder.');
      return;
    }
    await _hostFolderService.clearSelection();
    setState(() {
      _hostFolderSelection = null;
      _libraryPath = '/';
      _files = <DropFileItem>[];
      _libraryError = null;
    });
    if (mounted) {
      _snack('Drop folder permission forgotten');
    }
  }

  Future<bool> _ensureDropFolderChoice() async {
    if (_loadingHostFolderSelection) {
      await _loadHostFolderSelection();
    }
    if (!mounted) {
      return false;
    }
    if (_hostFolderSelection != null) {
      return true;
    }
    final shouldSelect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Drop folder'),
        content: const Text(
          'Erebrus Drop needs a folder selected from Files or phone storage before it can host a room. Create or choose an ErebrusDrop folder in the picker.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Select Folder'),
          ),
        ],
      ),
    );
    if (shouldSelect == true) {
      return _selectHostFolder();
    }
    _snack('Select a Drop folder to start hosting.');
    return false;
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    _snack(message);
  }

  void _showQrDialog(DropRoomSession session) {
    showDialog<void>(
      context: context,
      builder: (context) => DropCodeDialog(
        link: session.baseUrl,
        onCopy: () => _copy(session.baseUrl, 'Drop Link copied'),
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatEta(Duration duration) {
    if (duration.inSeconds <= 0) {
      return 'ETA now';
    }
    if (duration.inHours > 0) {
      final minutes = duration.inMinutes.remainder(60);
      return 'ETA ${duration.inHours}h ${minutes}m';
    }
    if (duration.inMinutes > 0) {
      final seconds = duration.inSeconds.remainder(60);
      return 'ETA ${duration.inMinutes}m ${seconds}s';
    }
    return 'ETA ${duration.inSeconds}s';
  }

  Widget _brandHeader() {
    return Row(
      children: [
        const Expanded(
          child: BrandLockup(
            markSize: 46,
            eyebrow: 'Local-first',
            subtitle: 'Direct nearby. Decentralized when distance matters.',
          ),
        ),
        if (supportsNativeQrScanner) ...[
          const SizedBox(width: 12),
          DropIconButton(
            icon: Icons.qr_code_scanner_rounded,
            onPressed: _scanDropCode,
            tooltip: 'Scan Drop Code',
          ),
        ],
      ],
    );
  }
}

enum _BackAction { background, close }

enum _LibraryFileAction { open, share, delete }

enum _JoinedFileAction { download, pullToHost }

enum TransferDirection { upload, download }

class TransferProgress {
  const TransferProgress({
    required this.direction,
    required this.title,
    required this.detail,
    required this.sentBytes,
    required this.totalBytes,
    required this.speedBytesPerSecond,
    this.completed = false,
  });

  factory TransferProgress.complete({
    required TransferDirection direction,
    required String title,
    required String detail,
    required int totalBytes,
  }) {
    return TransferProgress(
      direction: direction,
      title: title,
      detail: detail,
      sentBytes: totalBytes,
      totalBytes: totalBytes,
      speedBytesPerSecond: 0,
      completed: true,
    );
  }

  final TransferDirection direction;
  final String title;
  final String detail;
  final int sentBytes;
  final int totalBytes;
  final double speedBytesPerSecond;
  final bool completed;

  bool get isActive => !completed;

  double? get progress {
    if (totalBytes <= 0) {
      return null;
    }
    return (sentBytes / totalBytes).clamp(0.0, 1.0);
  }

  Duration? get eta {
    if (completed || totalBytes <= 0 || speedBytesPerSecond <= 0) {
      return null;
    }
    final remaining = math.max(0, totalBytes - sentBytes);
    return Duration(seconds: (remaining / speedBytesPerSecond).ceil());
  }
}

class _JoinedRoomDetailScreen extends StatelessWidget {
  const _JoinedRoomDetailScreen({
    required this.preview,
    required this.session,
    required this.path,
    required this.items,
    required this.activity,
    required this.transfer,
    required this.joining,
    required this.passwordController,
    required this.folderNameController,
    required this.textTitleController,
    required this.textBodyController,
    required this.onJoin,
    required this.onRefresh,
    required this.onUpFolder,
    required this.onUploadFiles,
    required this.onCreateFolder,
    required this.onSendText,
    required this.onFolderTap,
    required this.onDownload,
    required this.onPullToHost,
    required this.transferBuilder,
  });

  final JoinRoomPreview preview;
  final JoinRoomSession? session;
  final String path;
  final List<DropFileItem> items;
  final String? activity;
  final TransferProgress? transfer;
  final bool joining;
  final TextEditingController passwordController;
  final TextEditingController folderNameController;
  final TextEditingController textTitleController;
  final TextEditingController textBodyController;
  final Future<void> Function() onJoin;
  final Future<void> Function() onRefresh;
  final VoidCallback onUpFolder;
  final Future<void> Function() onUploadFiles;
  final Future<void> Function() onCreateFolder;
  final Future<void> Function() onSendText;
  final void Function(DropFileItem item) onFolderTap;
  final void Function(DropFileItem item) onDownload;
  final void Function(DropFileItem item)? onPullToHost;
  final Widget Function(TransferProgress transfer) transferBuilder;

  @override
  Widget build(BuildContext context) {
    final joined = session != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(preview.roomName),
        actions: [
          if (joined)
            IconButton(
              onPressed: () => unawaited(onRefresh()),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh room',
            ),
        ],
      ),
      body: _Screen(
        layout: DesktopContentLayout.library,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _roomHeader(context),
            const SizedBox(height: 12),
            if (!joined) _joinCard(context) else _joinedFilesCard(context),
            if (joined) ...[
              const SizedBox(height: 12),
              _sendToolsCard(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _roomHeader(BuildContext context) {
    return DropCard(
      glow: session != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LeadingTile(
                icon: _roomIcon,
                accent: session != null ? DropTheme.success : DropTheme.orange,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.roomName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${preview.deviceName} · $_platformLabel',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    MonoText(preview.baseUrl, size: 12, color: DropTheme.muted),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DropPill(
                icon: preview.authRequired
                    ? Icons.lock_rounded
                    : Icons.lock_open_rounded,
                label: preview.authRequired ? 'Password' : 'Open',
                color: preview.authRequired
                    ? DropTheme.amber
                    : DropTheme.success,
              ),
              DropPill(
                icon: Icons.folder_rounded,
                label: preview.scopedToDefaultFolder
                    ? 'Scoped folder'
                    : 'Drop folder',
                color: DropTheme.orange,
              ),
              if (session != null)
                const DropPill(
                  icon: Icons.check_circle_rounded,
                  label: 'Joined',
                  color: DropTheme.success,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _joinCard(BuildContext context) {
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            preview.authRequired ? 'Enter room password' : 'Join open room',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (preview.authRequired) ...[
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Room password'),
            ),
          ],
          const SizedBox(height: 14),
          PrimaryButton(
            label: joining ? 'Joining…' : 'Join Room',
            icon: Icons.login_rounded,
            busy: joining,
            onPressed: joining ? null : () => unawaited(onJoin()),
          ),
        ],
      ),
    );
  }

  Widget _joinedFilesCard(BuildContext context) {
    final scopedRoot = preview.scopedToDefaultFolder ? preview.scopePath : '/';
    final canGoUp = path != '/' && path != scopedRoot;
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Files',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    MonoText(path, size: 12, color: DropTheme.muted),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => unawaited(onRefresh()),
                icon: const Icon(Icons.refresh_rounded),
                color: DropTheme.faint,
                tooltip: 'Refresh room',
              ),
              IconButton(
                onPressed: canGoUp ? onUpFolder : null,
                icon: const Icon(Icons.drive_folder_upload_outlined),
                color: DropTheme.faint,
                tooltip: 'Up folder',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropPill(
                  icon: Icons.upload_rounded,
                  label: 'Upload to $path',
                  color: DropTheme.orange,
                ),
              ),
              const SizedBox(width: 10),
              TonalButton(
                label: 'Upload',
                icon: Icons.upload_file_rounded,
                onPressed: transfer?.isActive == true
                    ? null
                    : () => unawaited(onUploadFiles()),
              ),
            ],
          ),
          if (transfer != null) ...[
            const SizedBox(height: 10),
            transferBuilder(transfer!),
          ],
          if (activity != null) ...[
            const SizedBox(height: 10),
            _InlineActivity(message: activity!),
          ],
          const SizedBox(height: 12),
          if (items.isEmpty && activity == null)
            const _EmptyFolderState()
          else
            ...items.map(
              (item) => _JoinedFileTile(
                item: item,
                onFolderTap: onFolderTap,
                onDownload: onDownload,
                onPullToHost: onPullToHost,
              ),
            ),
        ],
      ),
    );
  }

  Widget _sendToolsCard(BuildContext context) {
    return DropCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Send', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: folderNameController,
                  decoration: const InputDecoration(labelText: 'New folder'),
                ),
              ),
              const SizedBox(width: 10),
              DropIconButton(
                icon: Icons.create_new_folder_rounded,
                tonal: true,
                tooltip: 'Create folder',
                onPressed: () => unawaited(onCreateFolder()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: textTitleController,
            decoration: const InputDecoration(labelText: 'Text title'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: textBodyController,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Text to send'),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Send Text',
            icon: Icons.send_rounded,
            onPressed: () => unawaited(onSendText()),
          ),
        ],
      ),
    );
  }

  IconData get _roomIcon {
    final platform = preview.devicePlatform.toLowerCase();
    final type = preview.deviceType.toLowerCase();
    if (platform.contains('android')) return Icons.android;
    if (platform.contains('ios')) return Icons.phone_iphone;
    if (type.contains('phone')) return Icons.smartphone_outlined;
    if (platform.contains('mac')) return Icons.laptop_mac_outlined;
    if (platform.contains('windows') || platform.contains('linux')) {
      return Icons.computer_outlined;
    }
    return Icons.devices_other_outlined;
  }

  String get _platformLabel {
    final platform = preview.devicePlatform.toLowerCase();
    if (platform.contains('android')) return 'Android phone';
    if (platform.contains('ios')) return 'iPhone';
    if (platform.contains('mac')) return 'Mac';
    if (platform.contains('windows')) return 'Windows';
    if (platform.contains('linux')) return 'Linux';
    return preview.deviceType.isEmpty ? 'Local device' : preview.deviceType;
  }
}

class _JoinedFileTile extends StatelessWidget {
  const _JoinedFileTile({
    required this.item,
    required this.onFolderTap,
    required this.onDownload,
    required this.onPullToHost,
  });

  final DropFileItem item;
  final void Function(DropFileItem item) onFolderTap;
  final void Function(DropFileItem item) onDownload;
  final void Function(DropFileItem item)? onPullToHost;

  @override
  Widget build(BuildContext context) {
    final isFolder = item.type == 'folder';
    final Color color;
    final IconData icon;
    if (isFolder) {
      color = DropTheme.orange;
      icon = Icons.folder_rounded;
    } else if (item.streamable) {
      color = DropTheme.amber;
      icon = Icons.play_circle_rounded;
    } else {
      color = DropTheme.muted;
      icon = Icons.insert_drive_file_rounded;
    }
    final meta = isFolder
        ? 'Folder'
        : '${formatBytes(item.sizeBytes)} · ${item.mimeType ?? 'file'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropInset(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: PressableScale(
          onTap: isFolder ? () => onFolderTap(item) : () => onDownload(item),
          child: Row(
            children: [
              LeadingTile(icon: icon, accent: color, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (isFolder)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: DropTheme.faint,
                  ),
                )
              else
                PopupMenuButton<_JoinedFileAction>(
                  tooltip: 'File actions',
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: DropTheme.faint,
                  ),
                  onSelected: (action) {
                    switch (action) {
                      case _JoinedFileAction.download:
                        onDownload(item);
                      case _JoinedFileAction.pullToHost:
                        onPullToHost?.call(item);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _JoinedFileAction.download,
                      child: ListTile(
                        leading: Icon(Icons.download_outlined),
                        title: Text('Download'),
                      ),
                    ),
                    if (onPullToHost != null)
                      const PopupMenuItem(
                        value: _JoinedFileAction.pullToHost,
                        child: ListTile(
                          leading: Icon(Icons.sync_alt_outlined),
                          title: Text('Pull to my room'),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFolderState extends StatelessWidget {
  const _EmptyFolderState();

  @override
  Widget build(BuildContext context) {
    return DropInset(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: Column(
        children: [
          const Icon(
            Icons.folder_open_rounded,
            size: 34,
            color: DropTheme.faint,
          ),
          const SizedBox(height: 10),
          Text(
            'This folder is empty',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ),
    );
  }
}

class _InlineActivity extends StatelessWidget {
  const _InlineActivity({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final isError = message.startsWith('Could not');
    return DropInset(
      child: Row(
        children: [
          if (isError)
            const Icon(Icons.error_outline, size: 18, color: DropTheme.danger)
          else
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// Live, self-ticking uptime stat (hh:mm:ss) for the host dashboard.
class _UptimeStat extends StatefulWidget {
  const _UptimeStat({required this.since});

  final DateTime since;

  @override
  State<_UptimeStat> createState() => _UptimeStatState();
}

class _UptimeStatState extends State<_UptimeStat> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = DateTime.now().difference(widget.since);
    final d = raw.isNegative ? Duration.zero : raw;
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return StatBlock(
      icon: Icons.timer_outlined,
      value: '$h:$m:$s',
      label: 'Uptime',
      mono: true,
    );
  }
}

/// Live "expires in HH:MM:SS" countdown for a burn-mode room. Recomputes from
/// the absolute [expiresAt] each tick, so it stays accurate across skipped
/// ticks and clamps to zero once the deadline passes.
class _ExpiryCountdownStat extends StatefulWidget {
  const _ExpiryCountdownStat({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_ExpiryCountdownStat> createState() => _ExpiryCountdownStatState();
}

class _ExpiryCountdownStatState extends State<_ExpiryCountdownStat> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.expiresAt.difference(DateTime.now());
    final d = raw.isNegative ? Duration.zero : raw;
    final expiringSoon = d <= const Duration(minutes: 5);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return StatBlock(
      icon: Icons.local_fire_department_rounded,
      value: '$h:$m:$s',
      label: 'Expires in',
      mono: true,
      valueColor: expiringSoon ? DropTheme.danger : DropTheme.white,
    );
  }
}

/// Capitalizes the first character of a string.
extension _StringCapitalize on String {
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}

/// Status pill showing whether a gateway node is online or offline.
class _NodeStatusChip extends StatelessWidget {
  const _NodeStatusChip({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? DropTheme.success : DropTheme.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            online ? 'Online' : 'Offline',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: DropTheme.white,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small attribute chip used to display node capabilities.
class _NodeDetailChip extends StatelessWidget {
  const _NodeDetailChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: DropTheme.white,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

/// A richer dropdown row for selecting a gateway node.
class _NodeDropdownItem extends StatelessWidget {
  const _NodeDropdownItem({required this.node});

  final DropNode node;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: node.online ? DropTheme.success : DropTheme.danger,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text(
                '${node.region.isEmpty ? 'Global' : node.region} · ${node.capacity.isEmpty ? 'Unknown' : node.capacity.capitalize()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A WebDAV client affordance: small icon + label (Finder · Explorer · …).
class _WebDavClient extends StatelessWidget {
  const _WebDavClient({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: DropTheme.muted),
        const SizedBox(width: 7),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Screen extends StatelessWidget {
  const _Screen({
    required this.child,
    this.glowAlignment = Alignment.topRight,
    this.layout = DesktopContentLayout.standard,
  });

  final Widget child;
  final Alignment glowAlignment;
  final DesktopContentLayout layout;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: AmbientGlow(alignment: glowAlignment)),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = DesktopLayout.contentMaxWidth(
              windowWidth: constraints.maxWidth,
              layout: layout,
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: child,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Screen "Head": display title with optional subtitle and a trailing action.
class _Head extends StatelessWidget {
  const _Head({required this.title, this.subtitle, this.action});

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
    if (action == null) return text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: text),
        const SizedBox(width: 12),
        action!,
      ],
    );
  }
}

class DropCodeDialog extends StatelessWidget {
  const DropCodeDialog({required this.link, required this.onCopy, super.key});

  final String link;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(screen.width - 32, 360.0);
    final qrSize = math.min(dialogWidth - 64, 220.0);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 360,
          maxHeight: math.max(280, screen.height - 32),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Drop Code',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 18),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(DropTheme.radiusCard),
                  ),
                  child: SizedBox.square(
                    dimension: qrSize,
                    child: QrImageView(
                      data: link,
                      version: QrVersions.auto,
                      size: qrSize,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: MonoText(
                  link,
                  size: 12.5,
                  color: DropTheme.muted,
                  selectable: true,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TonalButton(
                      label: 'Close',
                      expand: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: PrimaryButton(
                      label: 'Copy Link',
                      icon: Icons.copy_rounded,
                      onPressed: onCopy,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DropCard(
      onTap: onTap,
      child: Row(
        children: [
          LeadingTile(icon: icon, accent: DropTheme.orange, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 3),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: DropTheme.faint),
          ],
        ],
      ),
    );
  }
}

class _SmartSendActions extends StatelessWidget {
  const _SmartSendActions({
    required this.onAddFiles,
    required this.onSendLink,
  });

  final VoidCallback onAddFiles;
  final VoidCallback onSendLink;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _SmartSendActionCard(
              icon: Icons.file_upload_outlined,
              title: 'Add files',
              subtitle: isDesktopPlatform
                  ? 'Drop files here or click to browse'
                  : 'Tap to choose files',
              onTap: onAddFiles,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SmartSendActionCard(
              icon: Icons.add_link_rounded,
              title: 'Send a link',
              subtitle: 'Tap to paste a URL into the composer',
              onTap: onSendLink,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmartSendActionCard extends StatelessWidget {
  const _SmartSendActionCard({
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
    return DropCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: DropTheme.orange, size: 22),
              const Spacer(),
              const Icon(
                Icons.chevron_right_rounded,
                color: DropTheme.faint,
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
