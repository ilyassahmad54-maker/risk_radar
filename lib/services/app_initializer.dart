import 'dart:typed_data';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../firebase_options.dart';
import 'app_config.dart';
import 'firebase_messaging_service.dart';
import 'logger_service.dart';
import 'local_storage_service.dart';
import 'notifications/notification_handlers.dart';

class AppInitializer {
  const AppInitializer._();

  static Future<void> initializeCritical() async {
    try {
      LoggerService.info('Initializing local storage...');
      await LocalStorageService.instance.init();
      LoggerService.info('Local storage initialized');

      LoggerService.info('Initializing Supabase...');
      AppConfig.validateClientConfig();
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
      );
      LoggerService.info('Supabase initialized');

      LoggerService.info('Initializing Firebase...');

      if (Firebase.apps.isEmpty) {
        try {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
          LoggerService.info('Firebase initialized');
        } on FirebaseException catch (e) {
          if (e.code != 'duplicate-app') {
            rethrow;
          }

          LoggerService.info(
            'Firebase default app was initialized concurrently; continuing.',
          );
        }
      } else {
        LoggerService.info('Firebase already initialized');
      }

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      LoggerService.info('Background message handler set');
    } catch (e, stackTrace) {
      LoggerService.error(
        'Critical error during initialization',
        e,
        stackTrace,
      );
      rethrow;
    }
  }

  static Future<void> initializeDeferred() async {
    try {
      LoggerService.info('Initializing notifications...');
      await AwesomeNotifications().initialize(
        'resource://drawable/ic_notification',
        [
          NotificationChannel(
            channelKey: 'Hazards Details',
            channelName: 'Hazard Alerts',
            channelDescription: 'Notifications for hazards near you',
            defaultColor: Colors.red,
            ledColor: Colors.red,
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
      LoggerService.info('Notifications initialized');

      AwesomeNotifications().setListeners(
        onActionReceivedMethod: NotificationHandlers.onActionReceivedMethod,
      );
      LoggerService.info('Notification listeners set');

      LoggerService.info('Initializing Firebase Messaging Service...');
      await FirebaseMessagingService.initialize();
      LoggerService.info('Firebase Messaging Service initialized');

      LoggerService.info('App initialization complete!');
    } catch (e, stackTrace) {
      LoggerService.error('Non-critical initialization failed', e, stackTrace);
    }
  }
}
