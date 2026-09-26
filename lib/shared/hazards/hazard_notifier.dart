import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/material.dart';
import 'package:riskradar/shared/hazards/hazard_details_screen.dart';
import 'package:riskradar/shared/navigation/app_navigator.dart';
import 'package:riskradar/services/app_config.dart';

/// Global instance
final HazardNotifier hazardNotifier = HazardNotifier();

// =========================================================================
//                        TOP-LEVEL FUNCTIONS (BACKGROUND ISOLATE)
// =========================================================================

@pragma("vm:entry-point")
Future<void> onActionReceivedMethod(ReceivedAction receivedAction) async {
  try {
    // Initialize Supabase in the background isolate
    AppConfig.validateClientConfig();
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
    );
  } catch (e) {
    debugPrint(
      '⚠️ Supabase initialization failed in background: $e. Proceeding...',
    );
  }

  final String? hazardId = receivedAction.payload?['hazardId'];
  final String sourceTable =
      receivedAction.payload?['sourceTable'] ?? 'hazards';
  if (hazardId == null) return;

  debugPrint(
    'ℹ️ Action received: ${receivedAction.buttonKeyPressed} for ID: $hazardId from table: $sourceTable',
  );

  if (receivedAction.buttonKeyPressed == 'DETAILS') {
    final hazardData = await fetchFullHazardData(
      hazardId,
      sourceTable: sourceTable,
    );

    if (hazardData != null) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (navigatorKey.currentState != null) {
          navigatorKey.currentState!.push(
            MaterialPageRoute(
              builder: (context) => HazardDetailsScreen(hazardData: hazardData),
            ),
          );
        } else {
          debugPrint('❌ Navigator not ready. Cannot open hazard details.');
        }
      });
    } else {
      debugPrint('❌ Could not fetch hazard details for ID: $hazardId');
    }
  }
}

// --- REPORTER INFO HELPER ---

/// Helper to get reporter name and role from the joined nested object ('workers' in the original code, 'reporter' here)
String _getReporterInfo(Map<String, dynamic>? reporterData) {
  if (reporterData == null) {
    debugPrint(
      '🐛 DEBUG REPORTER: reporterData is NULL. Returning "Unknown Reporter".',
    );
    return 'Unknown Reporter';
  }

  final firstName = reporterData['first_name'] ?? '';
  final lastName = reporterData['last_name'] ?? '';
  // Assuming 'work_type' or 'role' is the relevant designation key
  final workType =
      reporterData['work_type'] ?? reporterData['role'] ?? 'Worker';

  final String fullName = '$firstName $lastName'.trim();

  debugPrint(
    '🐛 DEBUG REPORTER: Raw names (F/L/Type): $firstName/$lastName/$workType',
  );

  if (fullName.isEmpty) {
    // Fallback if first/last name are missing, use 'name' if available.
    final name = reporterData['name'] ?? 'Unknown';
    debugPrint(
      '🐛 DEBUG REPORTER: Full name empty. Falling back to $name ($workType)',
    );
    return '$name ($workType)';
  }

  debugPrint('🐛 DEBUG REPORTER: Formatted name: $fullName ($workType)');
  return '$fullName ($workType)';
}

/// Helper to get assigned worker name from the joined nested object ('hse_worker' here)
String _getAssignedToInfo(Map<String, dynamic>? workerData) {
  if (workerData == null) return 'Not Assigned';
  final firstName = workerData['first_name'] ?? '';
  final lastName = workerData['last_name'] ?? '';
  final designation =
      workerData['designation'] ?? workerData['role'] ?? 'Worker';

  final String name = '$firstName $lastName'.trim();

  if (name.isEmpty) {
    final nameFallback = workerData['name'] ?? 'Not Assigned';
    return nameFallback.contains('Not Assigned')
        ? nameFallback
        : '$nameFallback ($designation)';
  }

  return '$name ($designation)';
}

// =========================================================================
//                           MAIN FETCH FUNCTION
// =========================================================================

/// Fetch full hazard data with proper worker joins from a single query
Future<Map<String, dynamic>?> fetchFullHazardData(
  String hazardId, {
  required String sourceTable,
}) async {
  final SupabaseClient supabase = Supabase.instance.client;
  final String fallbackTable = sourceTable == 'hazards'
      ? 'assign_hazards'
      : 'hazards';
  Map<String, dynamic>? hazard;

  const String selectQuery = '''
    *,
    reporter:worker_id (
      first_name,
      last_name,
      work_type
    ),
    hse_worker:assigned_to (
      first_name,
      last_name,
      designation,
      role
    )
  ''';

  // 1. Try primary table
  try {
    final response1 = await supabase
        .from(sourceTable)
        .select(selectQuery)
        .eq('id', hazardId)
        .single();
    hazard = response1;
    debugPrint(
      '✅ Hazard found in primary table: $sourceTable with worker joins.',
    );
    debugPrint(
      '🐛 DEBUG FETCH 1: Raw joined reporter object: ${hazard['reporter']}',
    ); // **CRITICAL DEBUG POINT 1**
  } on PostgrestException catch (_) {
    // Not found in primary table, proceed to fallback.
  } catch (e) {
    debugPrint('⚠️ Error querying primary table $sourceTable: $e');
  }

  // 2. Try fallback table
  if (hazard == null) {
    debugPrint(
      'ℹ️ Hazard not found in $sourceTable. Checking fallback table: $fallbackTable...',
    );
    try {
      final response2 = await supabase
          .from(fallbackTable)
          .select(selectQuery)
          .eq('id', hazardId)
          .single();
      hazard = response2;
      debugPrint(
        '✅ Hazard found in fallback table: $fallbackTable with worker joins.',
      );
      debugPrint(
        '🐛 DEBUG FETCH 2: Raw joined reporter object: ${hazard['reporter']}',
      ); // **CRITICAL DEBUG POINT 1**
    } on PostgrestException catch (_) {
      // Not found in fallback table either.
    } catch (e) {
      debugPrint('⚠️ Error querying fallback table $fallbackTable: $e');
    }
  }

  if (hazard == null) {
    debugPrint('❌ Hazard not found in any table for ID: $hazardId.');
    return null;
  }

  // 3. Process the nested joined data into flattened keys for HazardDetailsScreen
  final String reporterInfo = _getReporterInfo(hazard['reporter']);
  final String assignedToInfo = _getAssignedToInfo(hazard['hse_worker']);

  // Handle images
  List<String> images = [];
  if (hazard['image_url'] != null &&
      hazard['image_url'].toString().isNotEmpty) {
    final imageUrls = hazard['image_url'].toString().split(',');
    images = imageUrls
        .where((url) => url.trim().isNotEmpty)
        .map((url) => url.trim())
        .toList();
  }

  debugPrint(
    '📊 Final result - Reporter: $reporterInfo, Assigned: $assignedToInfo',
  );
  debugPrint(
    '🐛 DEBUG FINAL MAP: reporter_name set to: $reporterInfo',
  ); // **CRITICAL DEBUG POINT 3**
  debugPrint(
    '🐛 DEBUG FINAL MAP: Original worker_id: ${hazard['worker_id']}',
  ); // For RLS check

  return {
    'id': hazard['id'],
    'hazard_type': hazard['hazard_type'],
    'description': hazard['description'],
    'status': hazard['status'],
    'severity': hazard['severity'],
    'assigned_at': hazard['assigned_at'],
    'created_at': hazard['created_at'],
    'latitude': hazard['latitude'],
    'longitude': hazard['longitude'],
    'voice_note_url': hazard['voice_note_url'],

    // Keys expected by HazardDetailsScreen
    'reporter_name': reporterInfo,
    'assigned_to': assignedToInfo,
    'images': images,
    'image_url': hazard['image_url'], // Keep original for compatibility
  };
}

// =========================================================================
//                           HAZARD NOTIFIER CLASS
// =========================================================================

class HazardNotifier {
  final SupabaseClient supabase = Supabase.instance.client;
  StreamSubscription<Position>? _positionStreamSubscription;
  final Set<String> _notifiedHazards = {};

  void removeNotifiedHazard(String hazardId) =>
      _notifiedHazards.remove(hazardId);

  void startChecking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        return;
    }

    _positionStreamSubscription?.cancel();
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 10,
    );

    _positionStreamSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) => _checkHazardsForPosition(position),
          onError: (e) => debugPrint('❌ Error in location stream: $e'),
        );
    debugPrint('✅ Location stream started.');
  }

  void stopChecking() => _positionStreamSubscription?.cancel();

  Future<void> _checkHazardsForPosition(Position position) async {
    try {
      final double userLat = position.latitude;
      final double userLng = position.longitude;

      final List hazards = await supabase
          .from('hazards')
          .select()
          .neq('status', 'resolved');
      final List assignedHazards = await supabase
          .from('assign_hazards')
          .select()
          .neq('status', 'resolved');
      final List allHazards = [...hazards, ...assignedHazards];

      for (var hazard in allHazards) {
        final String hazardId = hazard['id'];
        if (_notifiedHazards.contains(hazardId)) continue;

        final double hazardLat = hazard['latitude'];
        final double hazardLng = hazard['longitude'];
        final double distance = Geolocator.distanceBetween(
          userLat,
          userLng,
          hazardLat,
          hazardLng,
        );

        if (distance <= 500) {
          final String sourceTable = hazard.containsKey('assigned_at')
              ? 'assign_hazards'
              : 'hazards';
          _notifiedHazards.add(hazardId);

          _createHazardNotification(
            hazardId: hazardId,
            sourceTable: sourceTable,
            title: 'Nearby Hazard!',
            body: hazard['description'] ?? 'A hazard is nearby!',
            severity: hazard['severity'] ?? 'low',
            imageUrl: hazard['image_url'],
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Error checking hazards: $e');
    }
  }

  void _createHazardNotification({
    required String hazardId,
    required String sourceTable,
    required String title,
    required String body,
    required String severity,
    String? imageUrl,
  }) {
    Color notificationColor = Colors.grey;
    switch (severity.toLowerCase()) {
      case 'high':
        notificationColor = Colors.red;
        break;
      case 'moderate':
        notificationColor = Colors.yellow;
        break;
      case 'low':
        notificationColor = Colors.green;
        break;
    }

    AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: hazardId.hashCode,
        channelKey: 'Hazards Details',
        title: title,
        body: body,
        payload: {'hazardId': hazardId, 'sourceTable': sourceTable},
        icon: 'resource://drawable/ic_notification',
        color: notificationColor,
        notificationLayout: (imageUrl != null && imageUrl.isNotEmpty)
            ? NotificationLayout.BigPicture
            : NotificationLayout.Default,
        bigPicture: imageUrl,
      ),
      actionButtons: [
        NotificationActionButton(
          key: 'DETAILS',
          label: 'Details',
          actionType: ActionType.Default,
          autoDismissible: true,
        ),
        NotificationActionButton(
          key: 'NOTED',
          label: 'Noted',
          actionType: ActionType.DismissAction,
        ),
      ],
    );
  }
}
