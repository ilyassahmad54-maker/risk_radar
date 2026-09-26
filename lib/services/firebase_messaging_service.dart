// lib/services/firebase_messaging_service.dart
import 'dart:typed_data';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:riskradar/firebase_options.dart';
import 'package:riskradar/officers/notifications/officer_hazard_notifier.dart';
import 'package:riskradar/services/local_storage_service.dart';
import 'package:riskradar/services/repositories/auth_repository.dart';
import 'package:riskradar/hse_worker/screens/hse_worker_hazard_notifier.dart'
    as hse_notifications;
import 'package:riskradar/workers/settings/worker_hazard_notifier.dart'
    as worker_notifications;

/// CRITICAL: This must be a top-level function for background execution
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureFirebaseInitialized();
  await LocalStorageService.instance.init();
  await FirebaseMessagingService.ensureLocalNotificationsInitialized();

  debugPrint('Background message received: ${message.messageId}');

  await FirebaseMessagingService.showLocalNotificationFromMessage(message);
}

Future<void> _ensureFirebaseInitialized() async {
  if (Firebase.apps.isNotEmpty) {
    return;
  }

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (e) {
    if (e.code != 'duplicate-app') {
      rethrow;
    }

    debugPrint(
      'Firebase default app was initialized concurrently; continuing.',
    );
  }
}

/// Foreground message handler
class FirebaseMessagingService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static bool _localNotificationsInitialized = false;

  /// Initialize FCM and request permissions
  static Future<void> initialize() async {
    await ensureLocalNotificationsInitialized();

    // Request permission for iOS
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    debugPrint('FCM Permission status: ${settings.authorizationStatus}');

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle background messages (app in background but not terminated)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleBackgroundMessage);

    // Check if app was opened from terminated state via notification
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleBackgroundMessage(initialMessage);
    }
  }

  static Future<void> ensureLocalNotificationsInitialized() async {
    if (_localNotificationsInitialized) {
      return;
    }

    await AwesomeNotifications().initialize(
      'resource://drawable/ic_notification',
      [
        NotificationChannel(
          channelKey: 'Hazards Details',
          channelName: 'Hazard Alerts',
          channelDescription: 'Notifications for hazard alerts',
          defaultColor: Colors.orange,
          ledColor: Colors.orange,
          importance: NotificationImportance.High,
          playSound: true,
          enableVibration: true,
        ),
        NotificationChannel(
          channelKey: 'sos_alerts_critical',
          channelName: 'Emergency SOS',
          channelDescription: 'Critical site-wide emergency alerts',
          defaultColor: Colors.red,
          ledColor: Colors.red,
          importance: NotificationImportance.Max,
          playSound: true,
          soundSource: 'resource://raw/sos_alarm',
          defaultRingtoneType: DefaultRingtoneType.Alarm,
          criticalAlerts: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
        ),
      ],
    );

    _localNotificationsInitialized = true;
  }

  static Future<void> showLocalNotificationFromMessage(
    RemoteMessage message,
  ) async {
    await ensureLocalNotificationsInitialized();

    final data = message.data;
    final type = data['type']?.toString();
    if (type == 'SOS') {
      // Android displays killed/background SOS from the FCM notification
      // payload itself. Creating another local SOS notification here causes
      // duplicate tray alerts and repeated siren playback.
      return;
    }

    final hazardId = data['hazard_id']?.toString() ?? '';
    final title =
        data['title']?.toString() ??
        message.notification?.title ??
        'New Hazard Alert';
    final body =
        data['body']?.toString() ??
        message.notification?.body ??
        'A new hazard requires your attention';
    final severity = data['severity']?.toString() ?? 'low';
    final imageUrl = data['image_url']?.toString();
    final sourceTable = data['source_table']?.toString() ?? 'hazards';
    final notificationType = data['notification_type']?.toString();
    final role = AuthRepository().getRole();
    if (notificationType == 'worker_proximity' && role != 'worker') {
      debugPrint('Ignoring worker proximity notification for role: $role');
      return;
    }
    if (sourceTable == 'assign_hazards' && role != 'hse_worker') {
      debugPrint('Ignoring non-HSE assignment local notification: $hazardId');
      return;
    }
    if ((data['title']?.toString() ?? message.notification?.title) ==
        'New Hazard Reported!') {
      debugPrint(
        'Ignoring contractor new-hazard local notification: $hazardId',
      );
      return;
    }

    final notificationId = hazardId.isNotEmpty
        ? hazardId.hashCode
        : message.messageId?.hashCode ?? DateTime.now().hashCode;

    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: notificationId,
        channelKey: 'Hazards Details',
        title: title,
        body: body,
        payload: {
          if (hazardId.isNotEmpty) 'hazardId': hazardId,
          'sourceTable': sourceTable,
          'title': title,
          'body': body,
          'severity': severity,
          if (notificationType != null && notificationType.isNotEmpty)
            'notificationType': notificationType,
        },
        color: _severityColor(severity),
        icon: 'resource://drawable/ic_notification',
        notificationLayout: imageUrl != null && imageUrl.isNotEmpty
            ? NotificationLayout.BigPicture
            : NotificationLayout.Default,
        bigPicture: imageUrl,
        wakeUpScreen: true,
      ),
      actionButtons: hazardId.isEmpty
          ? null
          : [NotificationActionButton(key: 'DETAILS', label: 'VIEW DETAILS')],
    );

    debugPrint('Local notification created for message: ${message.messageId}');
  }

  static Color _severityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'moderate':
        return Colors.orange;
      case 'low':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  /// Handle messages when app is in foreground
  static Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint('Foreground message: ${message.notification?.title}');

    final data = message.data;
    if (data['type']?.toString() == 'SOS') {
      // SOS foreground routing is handled in main.dart so the alarm and
      // acknowledge screen have a single source of truth.
      return;
    }

    final hazardId = data['hazard_id'] ?? '';
    final title = data['title'] ?? message.notification?.title ?? 'New Hazard';
    final body =
        data['body'] ?? message.notification?.body ?? 'Check hazard details';
    final severity = data['severity'] ?? 'low';
    final imageUrl = data['image_url'];
    final sourceTable = data['source_table'] ?? 'hazards';
    final notificationType = data['notification_type']?.toString();
    final distance =
        int.tryParse(data['distance_meters']?.toString() ?? '') ?? 0;

    if (hazardId.isEmpty) return;
    final role = AuthRepository().getRole();
    if (notificationType == 'worker_proximity' && role != 'worker') {
      debugPrint('Ignoring worker proximity FCM for role: $role');
      return;
    }
    if (sourceTable == 'assign_hazards' && role != 'hse_worker') {
      debugPrint('Ignoring non-HSE assignment FCM notification: $hazardId');
      return;
    }
    if (title == 'New Hazard Reported!') {
      debugPrint('Ignoring contractor new-hazard FCM notification: $hazardId');
      return;
    }

    if (role == 'worker') {
      if (worker_notifications.workerHazardNotifier.isAlreadyNotified(
        hazardId,
      )) {
        debugPrint('Skipping duplicate worker FCM notification: $hazardId');
        return;
      }

      worker_notifications.workerHazardNotifier.addNotificationFromFCM(
        worker_notifications.WorkerNotificationItem(
          hazardId: hazardId,
          sourceTable: sourceTable,
          title: title,
          body: body,
          severity: severity,
          distance: distance,
          timestamp: DateTime.now(),
        ),
      );
      if (notificationType == 'worker_proximity') {
        await showLocalNotificationFromMessage(message);
      }
    } else if (role == 'hse_worker') {
      final hseNotificationType =
          notificationType ==
                  hse_notifications
                      .WorkerHazardNotifier
                      .proximityNotificationType ||
              notificationType == 'hse_proximity' ||
              notificationType == 'officer_proximity'
          ? hse_notifications.WorkerHazardNotifier.proximityNotificationType
          : hse_notifications.WorkerHazardNotifier.assignmentNotificationType;

      if (hse_notifications.workerHazardNotifier.isAlreadyNotified(
        hazardId,
        notificationType: hseNotificationType,
      )) {
        debugPrint(
          'Skipping duplicate HSE $hseNotificationType FCM notification: $hazardId',
        );
        return;
      }

      hse_notifications.workerHazardNotifier.addNotificationFromFCM(
        hse_notifications.WorkerNotification(
          hazardId: hazardId,
          sourceTable: sourceTable,
          title: title,
          body: body,
          severity: severity,
          notificationType: hseNotificationType,
          imageUrl: imageUrl,
          distance: 0,
          timestamp: DateTime.now(),
        ),
      );
    } else {
      if (officerHazardNotifier.isAlreadyNotified(hazardId)) {
        debugPrint('Skipping duplicate FCM notification for: $hazardId');
        return;
      }

      final notification = OfficerNotification(
        hazardId: hazardId,
        sourceTable: sourceTable,
        title: title,
        body: body,
        severity: severity,
        imageUrl: imageUrl,
        timestamp: DateTime.now(),
        isRead: false,
      );

      officerHazardNotifier.addNotificationFromFCM(notification);
    }

    // Foreground system display is handled in main.dart by
    // flutter_local_notifications to avoid duplicate notifications.
  }

  /// Handle messages when app opens from background notification tap
  static void _handleBackgroundMessage(RemoteMessage message) {
    debugPrint('Notification tapped: ${message.messageId}');

    if (message.data['type']?.toString() == 'SOS') {
      // SOS background/killed routing is handled in main.dart.
      return;
    }

    final hazardId = message.data['hazard_id'];
    if (hazardId != null) {
      final role = AuthRepository().getRole();
      final notificationType = message.data['notification_type']?.toString();
      if (role == 'worker') {
        worker_notifications.workerHazardNotifier.markAsRead(hazardId);
      } else if (role == 'hse_worker') {
        hse_notifications.workerHazardNotifier.markAsRead(
          hazardId,
          notificationType: notificationType,
        );
      } else {
        officerHazardNotifier.markAsRead(hazardId);
      }
    }
  }
}
