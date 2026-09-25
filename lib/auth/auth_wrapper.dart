// lib/auth/auth_wrapper.dart
//
// RiskRadar — Auth Wrapper (Offline-First, Production Ready)
// ─────────────────────────────────────────────────────────────────────────────
// Boot sequence (STRICT ORDER — never deviate):
//
//   1. Check LocalStorageService for cached role + profile
//      → If found: render correct dashboard INSTANTLY (zero network calls)
//      → Then silently refresh from Supabase in background
//
//   2. If no cache: check connectivity
//      → Online  → fetch role from Supabase → cache it → render dashboard
//      → Offline → show LoginScreen (first login always needs internet)
//
//   3. On new login: fetch role → cache role + profile → render dashboard
//
//   4. On logout: clear ALL cache → show LoginScreen
//
// What is NOT changed from original:
//   - Deep linking logic
//   - FCM token save / clear
//   - Hazard notifiers
//   - Theme handling
//   - All named routes
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:app_links/app_links.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'login_screen.dart';
import 'package:riskradar/services/repositories/auth_repository.dart';
import 'package:riskradar/services/sync_service.dart';

// Notifiers
import 'package:riskradar/hse_worker/screens/hse_worker_hazard_notifier.dart'
    as hse_notifications;
import 'package:riskradar/officers/notifications/officer_hazard_notifier.dart';
import 'package:riskradar/workers/settings/worker_hazard_notifier.dart'
    as worker_notifications;

// Screens
import 'package:riskradar/workers/screens/worker_home_screen.dart';
import 'package:riskradar/officers/screens/officer_home_screen.dart';
import 'package:riskradar/shared/screens/profile_setup_screen.dart';
import 'package:riskradar/hse_worker/screens/hse_worker_dashboard.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Boot state — drives what the build() method renders
// ─────────────────────────────────────────────────────────────────────────────
enum _BootState {
  /// Still running the boot sequence — show loading UI
  loading,

  /// Cache hit: rendering dashboard instantly; background sync in progress
  cachedSession,

  /// Supabase confirmed session (fresh login or background refresh done)
  authenticatedSession,

  /// No session anywhere — show LoginScreen
  unauthenticated,

  /// Role could not be determined — send to ProfileSetupScreen
  noRole,
}

class AuthWrapper extends StatefulWidget {
  final ThemeMode currentThemeMode;
  final void Function(ThemeMode) onThemeChanged;

  const AuthWrapper({
    super.key,
    required this.currentThemeMode,
    required this.onThemeChanged,
  });

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  // ── State ──────────────────────────────────────────────────────────────────
  _BootState _bootState = _BootState.loading;
  Session? _session;
  String? _userRole;

  // ── Internal ───────────────────────────────────────────────────────────────
  late final StreamSubscription<AuthState> _authSub;
  late final AppLinks _appLinks;

  // ── Constants ──────────────────────────────────────────────────────────────
  static const String _allowedScheme = 'hazardreporter';
  static const String _allowedHost = 'login-callback';
  static const Duration _roleTimeout = Duration(seconds: 10);
  static const Duration _fcmTimeout = Duration(seconds: 5);

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();

    _session = Supabase.instance.client.auth.currentSession;

    _listenToAuthChanges();
    _initDeepLinking();
    _listenForFcmTokenRefresh();

    // ── BOOT SEQUENCE ──────────────────────────────────────────────────────
    _boot();
  }

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BOOT — cache-first, never blocks on network
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _boot() async {
    final cache = AuthRepository();

    // ── Step 1: Try cache ─────────────────────────────────────────────────
    if (cache.hasCachedSession) {
      final cachedRole = cache.getRole();

      debugPrint(
        '✅ [Boot] Cache hit — role: $cachedRole. Rendering instantly.',
      );

      if (mounted) {
        setState(() {
          _userRole = cachedRole;
          _bootState = _BootState.cachedSession;
        });
      }

      // Silently refresh from Supabase in background — UI already visible
      _startHazardNotifierForRole();
      _refreshFcmToken();
      _backgroundRefresh();
      return;
    }

    // ── Step 2: No cache — need network ──────────────────────────────────
    debugPrint('ℹ️ [Boot] No cache found. Checking session...');

    if (_session == null) {
      // No Supabase session either — user has never logged in on this device
      debugPrint('ℹ️ [Boot] No session. Showing login.');
      if (mounted) setState(() => _bootState = _BootState.unauthenticated);
      return;
    }

    // Has a Supabase session but no local cache
    // (e.g. fresh install, cache manually cleared, or first run after update)
    await _initializeUser(_session!.user.id, isBackground: false);
  }

  // ── Silent background refresh after a cache boot ───────────────────────────
  Future<void> _backgroundRefresh() async {
    if (_session == null) return;

    final isOnline = await _checkConnectivity();
    if (!isOnline) {
      debugPrint('ℹ️ [BgRefresh] Offline — skipping background refresh.');
      return;
    }

    debugPrint('🔄 [BgRefresh] Online — refreshing role + profile silently.');

    try {
      await _determineAndCacheRole(_session!.user.id, isBackground: true);
      await _startHazardNotifierForRole();
      await _refreshFcmToken();
      SyncService.instance.run();
    } catch (e) {
      // Non-fatal — user already sees their dashboard from cache
      debugPrint('⚠️ [BgRefresh] Failed (non-fatal): $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // USER INITIALIZATION — called on new login or cache miss
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initializeUser(
    String userId, {
    required bool isBackground,
  }) async {
    if (!isBackground && mounted) {
      setState(() => _bootState = _BootState.loading);
    }

    try {
      final isOnline = await _checkConnectivity();

      if (!isOnline) {
        debugPrint('⚠️ [Init] Offline with no cache — cannot determine role.');
        if (!isBackground && mounted) {
          setState(() => _bootState = _BootState.unauthenticated);
        }
        return;
      }

      await _determineAndCacheRole(userId, isBackground: isBackground).timeout(
        _roleTimeout,
        onTimeout: () {
          debugPrint('⚠️ [Init] Role determination timed out.');
          _userRole = null;
        },
      );

      if (_userRole != null) {
        await _refreshFcmToken();
      }

      await _startHazardNotifierForRole();
      SyncService.instance.run();
    } on SocketException {
      debugPrint('⚠️ [Init] SocketException — no internet.');
      if (!isBackground && mounted) {
        setState(() => _bootState = _BootState.unauthenticated);
      }
      return;
    } catch (e) {
      debugPrint('❌ [Init] Unexpected error: $e');
      if (!isBackground && mounted) {
        setState(() {
          _userRole = null;
          _bootState = _BootState.noRole;
        });
      }
      return;
    }

    if (!isBackground && mounted) {
      setState(() {
        _bootState = _userRole != null
            ? _BootState.authenticatedSession
            : _BootState.noRole;
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ROLE DETERMINATION + CACHE WRITE
  //
  // Fetches role + full profile in one parallel round trip.
  // Writes result to LocalStorageService immediately on success.
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _determineAndCacheRole(
    String userId, {
    required bool isBackground,
  }) async {
    final supabase = Supabase.instance.client;
    final cache = AuthRepository();

    try {
      // Fetch role + profile columns in parallel — one query per role table
      final results = await Future.wait([
        supabase
            .from('officers')
            .select(
              'id, first_name, last_name, email, role, officer_uid, profile_image_url',
            )
            .eq('id', userId)
            .maybeSingle(),
        supabase
            .from('workers')
            .select(
              'id, first_name, last_name, email, role, officer_uid, work_type, '
              'profile_image_url, is_active, default_site_id, current_site_id',
            )
            .eq('id', userId)
            .maybeSingle(),
        supabase
            .from('hse_workers')
            .select(
              'id, first_name, last_name, email, role, officer_uid, designation, '
              'profile_image_url, is_active, is_available, current_site_id',
            )
            .eq('id', userId)
            .maybeSingle(),
      ]);

      if (!mounted) return;

      String? resolvedRole;
      Map<String, dynamic>? resolvedProfile;

      if (results[0] != null) {
        resolvedRole = 'officer';
        resolvedProfile = results[0] as Map<String, dynamic>;
      } else if (results[1] != null) {
        resolvedRole = 'worker';
        resolvedProfile = results[1] as Map<String, dynamic>;
      } else if (results[2] != null) {
        resolvedRole = 'hse_worker';
        resolvedProfile = results[2] as Map<String, dynamic>;
      }

      debugPrint('✅ [Role] Resolved: $resolvedRole');

      // ── Persist to cache ─────────────────────────────────────────────────
      if (resolvedRole != null && resolvedProfile != null) {
        await Future.wait([
          cache.saveRole(resolvedRole),
          cache.saveUserId(userId),
          cache.saveProfileForRole(resolvedRole, resolvedProfile),
        ]);
        debugPrint('✅ [Cache] Role + profile saved.');
      }

      // ── Update in-memory state ───────────────────────────────────────────
      if (!isBackground) {
        _userRole = resolvedRole;
      } else if (resolvedRole != null && resolvedRole != _userRole) {
        // Role changed server-side — update UI silently without a loading flash
        debugPrint('ℹ️ [BgRefresh] Role updated: $_userRole → $resolvedRole');
        if (mounted) setState(() => _userRole = resolvedRole);
      }
    } on SocketException {
      rethrow;
    } catch (e) {
      debugPrint('❌ [Role] Error: $e');
      if (!isBackground) _userRole = null;
      rethrow;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // AUTH STATE LISTENER
  // ══════════════════════════════════════════════════════════════════════════

  void _listenToAuthChanges() {
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((
      data,
    ) async {
      if (!mounted) return;

      final newSession = data.session;
      final isNewLogin = newSession != null && _session == null;
      final isLogout = newSession == null && _session != null;

      setState(() => _session = newSession);

      if (isNewLogin) {
        debugPrint('🔑 [Auth] New login detected.');
        await _initializeUser(newSession.user.id, isBackground: false);
      } else if (isLogout) {
        debugPrint('🚪 [Auth] Logout detected.');
        await _handleLogout();
      }
    }, onError: (e) => debugPrint('⚠️ [Auth] Stream error: $e'));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LOGOUT — clears ALL local cache as per CLAUDE.md spec
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _handleLogout() async {
    // Fire-and-forget FCM clear — don't block UI on network failure
    _clearFcmTokenFromBackend().catchError(
      (e) => debugPrint('⚠️ [Logout] FCM clear failed: $e'),
    );

    // Stop notifiers
    try {
      worker_notifications.workerHazardNotifier.stopChecking();
      hse_notifications.workerHazardNotifier.stopChecking();
      officerHazardNotifier.stopChecking();
      officerHazardNotifier.clearNotifications();
    } catch (e) {
      debugPrint('⚠️ [Logout] Notifier stop failed: $e');
    }

    // ── Wipe ALL local cache ───────────────────────────────────────────────
    await AuthRepository().clearAll();
    debugPrint('✅ [Cache] All data cleared on logout.');

    if (mounted) {
      setState(() {
        _userRole = null;
        _bootState = _BootState.unauthenticated;
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CONNECTIVITY CHECK
  // Lightweight DNS lookup — no extra packages required.
  // ══════════════════════════════════════════════════════════════════════════

  Future<bool> _checkConnectivity() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 5));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HAZARD NOTIFIERS — unchanged logic, cleaner switch
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _startHazardNotifierForRole() async {
    try {
      worker_notifications.workerHazardNotifier.stopChecking();
      hse_notifications.workerHazardNotifier.stopChecking();
      officerHazardNotifier.stopChecking();

      switch (_userRole) {
        case 'officer':
          await officerHazardNotifier.startChecking();
          break;
        case 'worker':
          await worker_notifications.workerHazardNotifier.startChecking();
          break;
        case 'hse_worker':
          await hse_notifications.workerHazardNotifier.startChecking();
          break;
      }
    } catch (e) {
      debugPrint('⚠️ [Notifier] Start error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FCM TOKEN — unchanged logic, extracted into helpers
  // ══════════════════════════════════════════════════════════════════════════

  void _listenForFcmTokenRefresh() {
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) await _saveFcmToken(newToken);
    });
  }

  Future<void> _refreshFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken().timeout(
        _fcmTimeout,
        onTimeout: () {
          debugPrint('⚠️ [FCM] Token fetch timed out.');
          return null;
        },
      );
      if (token != null) await _saveFcmToken(token);
    } catch (e) {
      debugPrint('⚠️ [FCM] Refresh error: $e');
    }
  }

  Future<void> _saveFcmToken(String token) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || _userRole == null) {
      debugPrint('⚠️ [FCM] Skipping save — user or role not available.');
      return;
    }

    final userId = user.id;
    final client = Supabase.instance.client;
    final roleTable = _tableForRole(_userRole!);

    try {
      debugPrint(
        '🔑 [FCM][Role $_userRole] Registering device token for $userId',
      );

      await Future.wait([
        client.rpc('register_fcm_token', params: {'p_token': token}),
        if (roleTable != null)
          client.from(roleTable).update({'fcm_token': token}).eq('id', userId),
      ]);
      debugPrint('✅ [FCM] Token saved for role: $_userRole');
    } catch (e) {
      debugPrint('⚠️ [FCM] Save error: $e');
    }
  }

  Future<void> _clearFcmTokenFromBackend() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final userId = user.id;
    final client = Supabase.instance.client;

    try {
      await Future.wait([
        client.from('user_fcm_tokens').delete().eq('user_id', userId),
        client.from('officers').update({'fcm_token': null}).eq('id', userId),
        client.from('workers').update({'fcm_token': null}).eq('id', userId),
        client.from('hse_workers').update({'fcm_token': null}).eq('id', userId),
      ]);
      debugPrint('✅ [FCM] Tokens cleared on logout.');
    } catch (e) {
      debugPrint('⚠️ [FCM] Clear error: $e');
    }
  }

  String? _tableForRole(String role) {
    switch (role) {
      case 'officer':
        return 'officers';
      case 'worker':
        return 'workers';
      case 'hse_worker':
        return 'hse_workers';
      default:
        return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DEEP LINKING — unchanged from original
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _initDeepLinking() async {
    _appLinks = AppLinks();
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null && _isValidDeepLink(uri)) {
        await _handleDeepLink(uri);
      }
    } catch (e) {
      debugPrint('⚠️ [DeepLink] Init error: $e');
    }

    _appLinks.uriLinkStream.listen((uri) {
      if (_isValidDeepLink(uri)) {
        _handleDeepLink(uri);
      } else {
        debugPrint('🚫 [DeepLink] Rejected invalid link: $uri');
      }
    });
  }

  bool _isValidDeepLink(Uri uri) =>
      uri.scheme == _allowedScheme && uri.host == _allowedHost;

  Future<void> _handleDeepLink(Uri uri) async {
    try {
      debugPrint('🔗 [DeepLink] Auth callback received: $uri');
      debugPrint(
        '🔐 [DeepLink] Letting Supabase auth state listener handle the session.',
      );
    } catch (e) {
      debugPrint('⚠️ [DeepLink] Handle error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LOADING UI — shown only during boot when no cache exists
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildLoadingScreen() {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: R.blockH * 26.667,
              height: R.blockV * 12.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              padding: EdgeInsets.all(R.blockH * 1),
              child: ClipOval(
                child: Image.asset(
                  'assets/logo.png',
                  fit: BoxFit.cover,
                  errorBuilder: (c, o, s) => Container(
                    color: const Color(0xFF1B3D3D),
                    child: Icon(Icons.security, size: 50, color: Colors.white),
                  ),
                ),
              ),
            ),
            SizedBox(height: R.blockV * 4),
            const CircularProgressIndicator(
              color: Color(0xFF1B3D3D),
              strokeWidth: 3,
            ),
            SizedBox(height: R.blockV * 2.5),
            Text(
              'Loading RiskRadar...',
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: R.blockH * 3.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    R.init(context);
    switch (_bootState) {
      case _BootState.loading:
        return _buildLoadingScreen();

      case _BootState.unauthenticated:
        return const LoginScreen();

      case _BootState.noRole:
        return const ProfileSetupScreen();

      case _BootState.cachedSession:
      case _BootState.authenticatedSession:
        switch (_userRole) {
          case 'officer':
            return OfficerHomeScreen(
              currentThemeMode: widget.currentThemeMode,
              onThemeChanged: widget.onThemeChanged,
            );
          case 'worker':
            return WorkerHomeScreen(
              currentThemeMode: widget.currentThemeMode,
              onThemeChanged: widget.onThemeChanged,
            );
          case 'hse_worker':
            return HSEWorkerHomeScreen(
              currentThemeMode: widget.currentThemeMode,
              onThemeChanged: widget.onThemeChanged,
            );
          default:
            return const ProfileSetupScreen();
        }
    }
  }
}
