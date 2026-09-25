import 'dart:async';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'services/app_initializer.dart';
import 'services/error_service.dart';
import 'services/sos_alarm_manager.dart';
import 'services/sync_service.dart';
import 'shared/navigation/app_navigator.dart' as app_navigation;
import 'shared/navigation/app_router.dart';
import 'shared/services/sos_overlay_service.dart';
import 'shared/theme/app_colors.dart';
import 'shared/widgets/emergency_permission_dialog.dart';
import 'shared/widgets/error_boundary.dart';

final navigatorKey = app_navigation.navigatorKey;
final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
Map<String, dynamic>? _pendingInitialSosPayload;

const AndroidNotificationChannel _sosNotificationChannel =
    AndroidNotificationChannel(
      'sos_alerts_critical',
      'SOS Critical Alerts',
      description: 'Critical emergency SOS alerts',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('sos_alarm'),
      audioAttributesUsage: AudioAttributesUsage.alarm,
    );

const AndroidNotificationChannel _hazardNotificationChannel =
    AndroidNotificationChannel(
      'hazard_alerts',
      'Hazard Alerts',
      description: 'Hazard reports, assignments, and nearby hazard alerts',
      importance: Importance.high,
      playSound: true,
    );

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    ErrorService.reportFlutterError(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    ErrorService.report(
      'Uncaught platform error',
      error: error,
      stackTrace: stackTrace,
      fatal: true,
    );
    return true;
  };

  try {
    await AppInitializer.initializeCritical();
    await _initializeForegroundPushNotifications();
    runApp(const ProviderScope(child: MyApp()));
  } catch (e, stackTrace) {
    ErrorService.report(
      'Failed to start app',
      error: e,
      stackTrace: stackTrace,
      fatal: true,
    );
    runApp(_ErrorApp(error: e.toString(), stackTrace: stackTrace.toString()));
  }
}

Future<void> _initializeForegroundPushNotifications() async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: androidSettings,
  );

  await _localNotificationsPlugin.initialize(initializationSettings);

  final androidPlugin = _localNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await androidPlugin?.createNotificationChannel(_sosNotificationChannel);
  await androidPlugin?.createNotificationChannel(_hazardNotificationChannel);

  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(alert: true, badge: true, sound: true);

  final initialToken = await messaging.getToken();
  if (initialToken != null) {
    debugPrint('🔑 [FCM][Startup] Device token obtained.');
    await _saveTokenToSupabase(initialToken);
  }

  messaging.onTokenRefresh.listen((token) {
    debugPrint('🔄 [FCM][Refresh] Device token refreshed.');
    unawaited(_saveTokenToSupabase(token));
  });

  Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
    if (data.event == AuthChangeEvent.signedIn ||
        data.event == AuthChangeEvent.tokenRefreshed ||
        data.event == AuthChangeEvent.initialSession) {
      final token = await messaging.getToken();
      if (token != null) {
        debugPrint('🔑 [FCM][Auth ${data.event.name}] Device token obtained.');
        await _saveTokenToSupabase(token);
      }
    }
  });

  FirebaseMessaging.onMessage.listen(_showForegroundNotification);

  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    if (_isSosMessage(message)) {
      unawaited(
        SosOverlayService.showFromPayload(
          Map<String, dynamic>.from(message.data),
        ),
      );
    }
  });

  final initialMessage = await messaging.getInitialMessage();
  if (initialMessage != null && _isSosMessage(initialMessage)) {
    _pendingInitialSosPayload = Map<String, dynamic>.from(initialMessage.data);
  }
}

Future<void> _showForegroundNotification(RemoteMessage message) async {
  final notification = message.notification;
  final data = message.data;
  if (_isSosMessage(message)) {
    await SosAlarmManager.instance.startAlarm();
    await SosOverlayService.showFromPayload(Map<String, dynamic>.from(data));
    return;
  }
  if (data['notification_type']?.toString() == 'worker_proximity') {
    // The worker notification service owns proximity deduplication and display.
    return;
  }

  final title =
      data['title']?.toString() ?? notification?.title ?? 'RiskRadar Alert';
  final body =
      data['body']?.toString() ??
      data['message']?.toString() ??
      notification?.body ??
      '';

  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'hazard_alerts',
    'Hazard Alerts',
    channelDescription: 'Hazard reports, assignments, and nearby hazard alerts',
    importance: Importance.high,
    priority: Priority.high,
    icon: '@mipmap/ic_launcher',
    playSound: true,
    enableVibration: true,
  );
  const NotificationDetails notificationDetails = NotificationDetails(
    android: androidDetails,
  );

  await _localNotificationsPlugin.show(
    message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
    title,
    body,
    notificationDetails,
    payload: data.isEmpty ? null : data.toString(),
  );
}

bool _isSosMessage(RemoteMessage message) =>
    message.data['type']?.toString() == 'SOS';

Future<void> _saveTokenToSupabase(String token) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    return;
  }

  try {
    debugPrint('🔑 [FCM][Supabase RPC] Registering token for ${user.id}');

    await Supabase.instance.client.rpc(
      'register_fcm_token',
      params: {'p_token': token},
    );

    debugPrint('✅ [FCM] Device token registered.');
  } catch (e) {
    debugPrint('Failed to save FCM token: $e');
  }
}

class _ErrorApp extends StatelessWidget {
  const _ErrorApp({required this.error, required this.stackTrace});

  final String error;
  final String stackTrace;

  @override
  Widget build(BuildContext context) {
    R.init(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.red.shade50,
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(R.blockH * 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 100,
                  color: Colors.red.shade700,
                ),
                SizedBox(height: R.blockV * 3),
                Text(
                  'Failed to Initialize App',
                  style: TextStyle(
                    fontSize: R.blockH * 6,
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade700,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: R.blockV * 2),
                Container(
                  padding: EdgeInsets.all(R.blockH * 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Error Details:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade700,
                        ),
                      ),
                      SizedBox(height: R.blockV * 1),
                      Text(
                        error,
                        style: TextStyle(
                          fontSize: R.blockH * 3.5,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: R.blockV * 3),
                ElevatedButton.icon(
                  onPressed: () => main(),
                  icon: Icon(Icons.refresh),
                  label: Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                SizedBox(height: R.blockV * 2),
                Text(
                  'Common Fixes:',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade700,
                  ),
                ),
                SizedBox(height: R.blockV * 1),
                _buildFixItem('1. Check if .env file exists in root directory'),
                _buildFixItem('2. Verify all API keys in .env are correct'),
                _buildFixItem('3. Run "flutter clean" and "flutter pub get"'),
                _buildFixItem('4. Restart your IDE and try again'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFixItem(String text) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: R.blockV * 0.5),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: Colors.grey.shade600,
          ),
          SizedBox(width: R.blockH * 2.133),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: R.blockH * 3,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    debugPrint('App started');
    _startConnectivitySyncWatcher();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(AppInitializer.initializeDeferred());
      final pendingSosPayload = _pendingInitialSosPayload;
      _pendingInitialSosPayload = null;
      if (pendingSosPayload != null) {
        unawaited(SosOverlayService.showFromPayload(pendingSosPayload));
      }
      final context = navigatorKey.currentContext;
      if (context != null) {
        EmergencyPermissionDialog.showIfNeeded(context);
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startConnectivitySyncWatcher() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasInternet = results.any(
        (result) =>
            result == ConnectivityResult.mobile ||
            result == ConnectivityResult.wifi ||
            result == ConnectivityResult.ethernet ||
            result == ConnectivityResult.vpn,
      );

      if (hasInternet) {
        debugPrint('Connectivity restored. Running sync queue...');
        unawaited(SyncService.instance.run());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        debugPrint('App resumed');
        SyncService.instance.run();
        break;
      case AppLifecycleState.inactive:
        debugPrint('App inactive');
        break;
      case AppLifecycleState.paused:
        debugPrint('App paused');
        break;
      case AppLifecycleState.detached:
        debugPrint('App detached');
        break;
      case AppLifecycleState.hidden:
        debugPrint('App hidden');
        break;
    }
  }

  void _onThemeChanged(ThemeMode mode) {
    if (_themeMode != mode) {
      setState(() => _themeMode = mode);
      debugPrint('Theme changed to: $mode');
    }
  }

  @override
  Widget build(BuildContext context) {
    R.init(context);
    return ScreenUtilInit(
      designSize: const Size(360, 690),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'RiskRadar',
          themeMode: _themeMode,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          initialRoute: '/',
          routes: AppRouter.routes(
            currentThemeMode: _themeMode,
            onThemeChanged: _onThemeChanged,
          ),
          onUnknownRoute: AppRouter.onUnknownRoute,
          builder: (context, child) {
            return ErrorBoundary(child: child ?? const SizedBox.shrink());
          },
        );
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      ),
      appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: R.blockH * 6,
            vertical: R.blockV * 1.75,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.brandTeal,
        contentTextStyle: TextStyle(
          color: Colors.white,
          fontSize: R.blockH * 3.5,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
        actionTextColor: AppColors.accentGold,
        closeIconColor: Colors.white,
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: EdgeInsets.fromLTRB(
          R.blockH * 4,
          R.blockV * 0,
          R.blockH * 4,
          R.blockV * 2.5,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
      ),
    );
  }
}
