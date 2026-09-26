// lib/officers/hazards/officer_hazard_notifier.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:riskradar/shared/hazards/hazard_details_screen.dart';
import 'package:riskradar/shared/navigation/app_navigator.dart';
import 'package:riskradar/services/app_config.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';

final HazardRepository _hazardRepository = HazardRepository();

// Notification Model for internal storage
class OfficerNotification {
  final String hazardId;
  final String sourceTable;
  final String title;
  final String body;
  final String severity;
  final String? imageUrl;
  final DateTime timestamp;
  bool isRead;

  OfficerNotification({
    required this.hazardId,
    required this.sourceTable,
    required this.title,
    required this.body,
    required this.severity,
    this.imageUrl,
    required this.timestamp,
    this.isRead = false,
  });
}

// Global notifier instance
final OfficerHazardNotifier officerHazardNotifier = OfficerHazardNotifier();

/// Handles notification taps (background / terminated)
@pragma('vm:entry-point')
Future<void> onActionReceivedMethod(ReceivedAction receivedAction) async {
  try {
    AppConfig.validateClientConfig();
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
    );
  } catch (e) {
    debugPrint('Supabase init failed in background: $e');
  }

  final hazardId = receivedAction.payload?['hazardId'];
  final sourceTable = receivedAction.payload?['sourceTable'] ?? 'hazards';
  if (hazardId == null) return;

  officerHazardNotifier.markAsRead(hazardId);

  if (receivedAction.buttonKeyPressed == 'DETAILS') {
    final hazardData = await fetchFullHazardData(
      hazardId,
      sourceTable: sourceTable,
    );
    if (hazardData != null) {
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => HazardDetailsScreen(hazardData: hazardData),
          ),
        );
      });
    }
  }
}

// Helper to capitalize names
String _capitalizeName(String name) {
  if (name.isEmpty) return name;
  return name
      .split(' ')
      .map((word) {
        if (word.isEmpty) return '';
        return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
      })
      .join(' ');
}

// ✅ FIX: Uses the SQL View & perfectly matches the robust parsing from the worker screens!
Future<Map<String, dynamic>?> fetchFullHazardData(
  String hazardId, {
  required String sourceTable,
}) async {
  final supabase = Supabase.instance.client;

  try {
    Map<String, dynamic>? rawHazard;

    // 1. FETCH DATA
    if (sourceTable == 'assign_hazards') {
      // Query the View to get the aggregated officers and reporter info!
      rawHazard = await supabase
          .from('worker_active_hazards_view')
          .select()
          .eq('id', hazardId)
          .maybeSingle();
    } else {
      // Unassigned hazard, query base table
      rawHazard = await supabase
          .from('hazards')
          .select('*, workers!hazards_worker_id_fkey (*)')
          .eq('id', hazardId)
          .maybeSingle();
    }

    rawHazard ??= await _findCachedOfficerHazard(hazardId);
    if (rawHazard == null) return null;

    return _normaliseOfficerHazard(rawHazard);
  } catch (e) {
    debugPrint('Error fetching hazard details: $e');
    final cachedHazard = await _findCachedOfficerHazard(hazardId);
    return cachedHazard == null ? null : _normaliseOfficerHazard(cachedHazard);
  }
}

Future<Map<String, dynamic>?> _findCachedOfficerHazard(String hazardId) async {
  final cachedLists = [
    await _hazardRepository.getOfficerActiveHazards() ?? [],
    await _hazardRepository.getOfficerResolvedHazards() ?? [],
  ];

  for (final list in cachedLists) {
    for (final hazard in list) {
      if (hazard['id']?.toString() == hazardId) {
        return Map<String, dynamic>.from(hazard);
      }
    }
  }
  return null;
}

Map<String, dynamic> _normaliseOfficerHazard(Map<String, dynamic> rawHazard) {
  final reporter = rawHazard['workers'] ?? rawHazard['reporter'];
  final String reporterId =
      rawHazard['worker_id'] ?? (reporter != null ? reporter['id'] : '');

  String rawName = '';
  String? reporterImageUrl;

  if (reporter != null) {
    rawName = '${reporter['first_name']} ${reporter['last_name']}';
    reporterImageUrl = reporter['profile_image_url'];
  } else if (rawHazard['reporter_first_name'] != null) {
    rawName =
        '${rawHazard['reporter_first_name']} ${rawHazard['reporter_last_name']}';
    reporterImageUrl = rawHazard['reporter_image'];
  } else {
    rawName = rawHazard['reporter_name'] ?? 'Unknown User';
    reporterImageUrl = rawHazard['reporter_image'];
  }

  final reporterWorkType =
      reporter?['work_type'] ?? rawHazard['reporter_work_type'] ?? 'Worker';

  final nameParts = rawName.split(' ');
  final Map<String, dynamic> passedWorkerInfo =
      reporter ??
      {
        'id': reporterId,
        'first_name': rawHazard['reporter_first_name'] ?? nameParts.first,
        'last_name':
            rawHazard['reporter_last_name'] ??
            (nameParts.length > 1 ? nameParts.last : ''),
        'work_type': reporterWorkType,
        'profile_image_url': reporterImageUrl,
      };

  final List officersList =
      rawHazard['all_assigned_officers'] ?? rawHazard['assign_hazards'] ?? [];
  String assignedName = '';

  if (officersList.isNotEmpty) {
    final firstAssignment = officersList.first;
    final firstHse = firstAssignment is Map
        ? firstAssignment['hse_worker']
        : null;
    if (firstHse is Map) {
      assignedName =
          '${firstHse['first_name'] ?? ''} ${firstHse['last_name'] ?? ''}'
              .trim();
    }
  } else if (rawHazard['hse_worker'] != null) {
    final assignedWorker = rawHazard['hse_worker'];
    assignedName =
        '${assignedWorker['first_name']} ${assignedWorker['last_name']}';
  } else if (rawHazard['hse_first_name'] != null) {
    assignedName =
        '${rawHazard['hse_first_name']} ${rawHazard['hse_last_name']}';
  }
  if (assignedName.isEmpty) {
    assignedName = rawHazard['assigned_to_name'] ?? 'Not Assigned';
  }

  final images =
      (rawHazard['image_url'] != null &&
          rawHazard['image_url'].toString().isNotEmpty)
      ? rawHazard['image_url']
            .toString()
            .split(',')
            .map((e) => e.trim())
            .toList()
      : <String>[];

  final title = rawHazard['hazard_type'] ?? 'No Type';
  final description = rawHazard['description'] ?? 'No description provided.';
  final severity = rawHazard['severity'] ?? 'Unknown';
  final status = rawHazard['status'] ?? 'Unknown';

  return {
    ...rawHazard,
    'workers': passedWorkerInfo,
    'assign_hazards': officersList.isNotEmpty
        ? officersList
        : (rawHazard['hse_worker'] != null ? [rawHazard] : []),
    'hazard_type': title,
    'description': description,
    'images': images,
    'reporter_name': '${_capitalizeName(rawName)} ($reporterWorkType)',
    'assigned_name': assignedName,
    'severity': severity,
    'status': status,
    'created_at': rawHazard['created_at'] ?? rawHazard['assigned_at'],
    'assigned_at': rawHazard['assigned_at'],
    'latitude': rawHazard['latitude'],
    'longitude': rawHazard['longitude'],
    'voice_note_url': rawHazard['voice_note_url'] ?? '',
  };
}

// Main Notifier Class
class OfficerHazardNotifier extends ChangeNotifier {
  static const String _notifiedHazardsKeyPrefix =
      'officer_proximity_notified_hazard_ids_v2_';
  static const int _maxPersistedHazardIds = 1000;
  static const double _proximityRadiusMeters = 25.0;
  static const Duration _liveScanInterval = Duration(seconds: 15);
  static const Duration _locationUploadInterval = Duration(seconds: 5);

  final supabase = Supabase.instance.client;

  StreamSubscription<Position>? _posSub;
  Timer? _liveScanTimer;
  DateTime? _lastLocationUpload;

  // Separate tracking for shown notifications vs the visible notification log.
  // This set is also saved locally so an app restart does not re-alert old
  // active hazards during the officer proximity scan.
  final Set<String> _permanentlyNotified = {};
  final Set<String> _processingQueue = {}; // Prevent duplicate processing

  String? _currentOfficerAuthId;
  String? _customOfficerUid;

  // Persistent Notification Log
  final List<OfficerNotification> _notifications = [];
  List<OfficerNotification> get notifications => _notifications;

  int get unreadCount => _notifications.where((n) => !n.isRead).length;

  void clearNotifications() {
    _notifications.clear();
    // DO NOT clear _permanentlyNotified - this prevents re-notification loop
    notifyListeners();
    debugPrint(
      '✅ Cleared notification log (${_permanentlyNotified.length} hazards still tracked)',
    );
  }

  void markAllAsRead() {
    for (var n in _notifications) {
      n.isRead = true;
    }
    notifyListeners();
  }

  void markAsRead(String hazardId) {
    final index = _notifications.indexWhere(
      (n) => n.hazardId == hazardId && !n.isRead,
    );
    if (index != -1) {
      _notifications[index].isRead = true;
      notifyListeners();
    }
  }

  // Remove from both tracking and notifications
  void removeNotification(String hazardId) {
    _notifications.removeWhere((n) => n.hazardId == hazardId);
    // Keep in _permanentlyNotified to prevent re-notification
    notifyListeners();
  }

  // Public method for FCM to add notifications
  void addNotificationFromFCM(OfficerNotification notification) {
    final hazardId = notification.hazardId.trim();
    if (hazardId.isEmpty ||
        _permanentlyNotified.contains(hazardId) ||
        _notifications.any((n) => n.hazardId == hazardId)) {
      debugPrint('⏭️ Skipping duplicate FCM notification: $hazardId');
      return;
    }

    _permanentlyNotified.add(hazardId);
    unawaited(_persistNotifiedHazards());
    _notifications.add(notification);
    notifyListeners();
  }

  // Public method to check if hazard already notified
  bool isAlreadyNotified(String hazardId) {
    return _permanentlyNotified.contains(hazardId.trim());
  }

  String? get _notifiedHazardsStorageKey {
    final officerAuthId = _currentOfficerAuthId;
    if (officerAuthId == null || officerAuthId.isEmpty) return null;
    return '$_notifiedHazardsKeyPrefix$officerAuthId';
  }

  Future<void> _loadPersistedNotifiedHazards() async {
    final key = _notifiedHazardsStorageKey;
    if (key == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIds = prefs.getStringList(key) ?? const <String>[];
      _permanentlyNotified
        ..clear()
        ..addAll(savedIds.map((id) => id.trim()).where((id) => id.isNotEmpty));
      debugPrint(
        '✅ Restored ${_permanentlyNotified.length} officer notification IDs.',
      );
    } catch (e) {
      debugPrint('⚠️ Could not restore officer notification IDs: $e');
    }
  }

  Future<void> _rememberNotifiedHazard(String hazardId) async {
    final normalizedId = hazardId.trim();
    if (normalizedId.isEmpty) return;
    _permanentlyNotified.add(normalizedId);
    await _persistNotifiedHazards();
  }

  Future<void> _persistNotifiedHazards() async {
    final key = _notifiedHazardsStorageKey;
    if (key == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = _permanentlyNotified.toList(growable: false);
      final retainedIds = ids.length <= _maxPersistedHazardIds
          ? ids
          : ids.sublist(ids.length - _maxPersistedHazardIds);
      await prefs.setStringList(key, retainedIds);
    } catch (e) {
      debugPrint('⚠️ Could not persist officer notification IDs: $e');
    }
  }

  String _toTitleCase(String input) {
    if (input.trim().isEmpty) return 'Hazard';
    return input
        .trim()
        .split(RegExp(r'\s+'))
        .map(
          (w) => w.isEmpty
              ? w
              : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}',
        )
        .join(' ');
  }

  String _buildNearbyTitle(Map<String, dynamic> hazard) {
    return _toTitleCase(hazard['hazard_type']?.toString() ?? 'Hazard');
  }

  String _buildNearbyBody(Map<String, dynamic> hazard) {
    return 'A hazard is nearby. Stay safe!\nWithin ${_proximityRadiusMeters.round()} m.';
  }

  /// Start realtime & location-based monitoring
  Future<void> startChecking() async {
    final officerAuthId = supabase.auth.currentUser?.id;
    if (officerAuthId == null) {
      debugPrint('❌ No logged-in officer.');
      return;
    }

    _currentOfficerAuthId = officerAuthId;
    await _loadPersistedNotifiedHazards();

    // Related hazard records store officers.id in their officer_uid column.
    // officers.id is the authenticated contractor UUID.
    _customOfficerUid = officerAuthId;

    debugPrint('✅ Using officer id for hazard monitoring: $_customOfficerUid');

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        debugPrint('⚠️ Location permission denied.');
        return;
      }
    }

    _posSub?.cancel();
    _liveScanTimer?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 2,
      ),
    ).listen((pos) async {
      await _publishOfficerLocation(pos);
      await _checkNearbyHazards(pos, _customOfficerUid!);
    });

    _liveScanTimer = Timer.periodic(_liveScanInterval, (_) {
      unawaited(_triggerImmediateProximityCheck());
    });

    await _triggerImmediateProximityCheck();

    debugPrint('✅ Officer monitoring started.');
  }

  Future<void> _triggerImmediateProximityCheck() async {
    final officerUid = _customOfficerUid;
    if (officerUid == null) return;

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );
      await _publishOfficerLocation(pos);
      await _checkNearbyHazards(pos, officerUid);
    } catch (e) {
      debugPrint('⚠️ Officer immediate proximity check failed: $e');
    }
  }

  Future<void> _publishOfficerLocation(Position pos) async {
    final officerAuthId =
        _currentOfficerAuthId ?? supabase.auth.currentUser?.id;
    if (officerAuthId == null || officerAuthId.isEmpty) return;

    final now = DateTime.now();
    if (_lastLocationUpload != null &&
        now.difference(_lastLocationUpload!) < _locationUploadInterval) {
      return;
    }

    _lastLocationUpload = now;
    try {
      await supabase.from('user_locations').upsert({
        'user_id': officerAuthId,
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'updated_at': now.toUtc().toIso8601String(),
      }, onConflict: 'user_id');
    } catch (e) {
      debugPrint('âš ï¸ Could not publish officer location: $e');
    }
  }

  void stopChecking() {
    _posSub?.cancel();
    _liveScanTimer?.cancel();
    _posSub = null;
    _liveScanTimer = null;
    _lastLocationUpload = null;
    _currentOfficerAuthId = null;
    _customOfficerUid = null;
    _processingQueue.clear();
    debugPrint('🛑 Officer monitoring stopped.');
  }

  // Proximity-based hazard check
  Future<void> _checkNearbyHazards(
    Position pos,
    String customOfficerUid,
  ) async {
    try {
      final lat = pos.latitude;
      final lng = pos.longitude;

      final hazards = await supabase
          .from('hazards')
          .select()
          .neq('status', 'resolved')
          .eq('officer_uid', customOfficerUid);

      // ✅ THE FIX: Query the SQL view to perfectly collapse duplicates!
      final assigned = await supabase
          .from('worker_active_hazards_view')
          .select()
          .eq('officer_uid', customOfficerUid);

      final allHazards = [...hazards, ...assigned];

      for (final h in allHazards) {
        final id = h['id'].toString();

        if (_permanentlyNotified.contains(id)) continue;
        if (_processingQueue.contains(id)) continue;

        final hazardLat = h['latitude'];
        final hazardLng = h['longitude'];
        if (hazardLat == null || hazardLng == null) continue;

        final dist = Geolocator.distanceBetween(
          lat,
          lng,
          (hazardLat as num).toDouble(),
          (hazardLng as num).toDouble(),
        );

        if (dist <= _proximityRadiusMeters) {
          _processingQueue.add(id);
          try {
            await _rememberNotifiedHazard(id);

            // Track the correct table origin so the click-through goes to the right place
            final src = h.containsKey('assigned_at')
                ? 'assign_hazards'
                : 'hazards';

            await _createNotification(
              hazardId: id,
              sourceTable: src,
              title: _buildNearbyTitle(h),
              body: '${_buildNearbyBody(h)}\n${dist.round()} m away.',
              severity: h['severity'] ?? 'low',
              imageUrl: h['image_url'],
            );
          } finally {
            _processingQueue.remove(id);
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error in proximity check: $e');
    }
  }

  // Create a local notification
  Future<void> _createNotification({
    required String hazardId,
    required String sourceTable,
    required String title,
    required String body,
    required String severity,
    String? imageUrl,
  }) async {
    if (_notifications.any((n) => n.hazardId == hazardId)) {
      debugPrint('⏭️ Skipping duplicate notification for hazard $hazardId');
      return;
    }

    Color color = Colors.grey;
    switch (severity.toLowerCase()) {
      case 'high':
        color = Colors.red;
        break;
      case 'moderate':
        color = Colors.orange;
        break;
      case 'low':
        color = Colors.green;
        break;
    }
    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: hazardId.hashCode,
          channelKey: 'Hazards Details',
          title: title,
          body: body,
          payload: {'hazardId': hazardId, 'sourceTable': sourceTable},
          color: color,
          icon: 'resource://drawable/ic_notification',
          notificationLayout: (imageUrl != null && imageUrl.isNotEmpty)
              ? NotificationLayout.BigPicture
              : NotificationLayout.Default,
          bigPicture: imageUrl,
        ),
        actionButtons: [
          NotificationActionButton(key: 'DETAILS', label: 'VIEW DETAILS'),
        ],
      );

      await Future.delayed(const Duration(milliseconds: 100));

      _notifications.add(
        OfficerNotification(
          hazardId: hazardId,
          sourceTable: sourceTable,
          title: title,
          body: body,
          severity: severity,
          imageUrl: imageUrl,
          timestamp: DateTime.now(),
          isRead: false,
        ),
      );

      notifyListeners();
      debugPrint('✅ Notification created for hazard: $hazardId');
    } catch (e) {
      debugPrint('❌ Error creating notification: $e');
    }
  }
}
