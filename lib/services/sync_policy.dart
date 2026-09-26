import '../shared/models/hazard.dart';

class SyncPolicy {
  const SyncPolicy();

  static const _allowedStatusValues = {
    'reported',
    'assigned',
    'in_progress',
    'resolved',
    'resolved by other',
  };

  static const _profileTables = {'officers', 'workers', 'hse_workers'};

  ValidatedRpcAction validateRpcAction({
    required Map<String, dynamic> item,
    required Map<String, dynamic> payload,
    required String? role,
  }) {
    if (role == null) {
      throw const SyncValidationException('Missing cached user role.');
    }

    final rawName = item['rpc']?.toString() ?? item['table']?.toString();
    if (rawName == null) {
      throw const SyncValidationException('Missing RPC name.');
    }

    switch (rawName) {
      case 'assign_hazard_to_hse':
        _requireRole(role, {'officer'});

        _rejectUnknownColumns(rawName, payload, {
          'hazard_id',
          'assigned_to',
          'assigned_at',
        });
        _requireAll(payload, {'hazard_id', 'assigned_to'});

        return ValidatedRpcAction(
          name: rawName,
          params: {
            'p_hazard_id': payload['hazard_id'],
            'p_assigned_to': payload['assigned_to'],
            if (payload['assigned_at'] != null)
              'p_assigned_at': payload['assigned_at'],
          },
        );

      case 'update_hse_hazard_lifecycle':
        _requireRole(role, {'hse_worker'});

        _rejectUnknownColumns(rawName, payload, {
          'hazard_id',
          'new_status',
          'resolution_notes',
          'resolution_image_url',
          'resolution_voice_note_url',
          'image_paths',
          'voice_paths',
        });

        _requireAll(payload, {'hazard_id', 'new_status'});

        final status = payload['new_status']?.toString();

        if (!{'in_progress', 'resolved'}.contains(status)) {
          throw SyncValidationException(
            'Unsupported HSE lifecycle status: $status.',
          );
        }

        if (status == 'resolved') {
          final notes = payload['resolution_notes']?.toString().trim() ?? '';

          if (notes.isEmpty) {
            throw const SyncValidationException(
              'Resolution notes are required.',
            );
          }
        }

        return ValidatedRpcAction(
          name: rawName,
          params: {
            'p_hazard_id': payload['hazard_id'],
            'p_new_status': status,
            'p_resolution_notes': payload['resolution_notes'],
            'p_resolution_image_url': payload['resolution_image_url'],
            'p_resolution_voice_note_url': payload['resolution_voice_note_url'],
          },
        );

      default:
        throw SyncValidationException('Unsupported RPC: $rawName.');
    }
  }

  ValidatedSyncAction validateSyncAction({
    required Map<String, dynamic> item,
    required Map<String, dynamic> payload,
    required String? role,
    required String currentUserId,
  }) {
    final table = item['table']?.toString();
    final action = item['action']?.toString();
    if (table == null || action == null) {
      throw const SyncValidationException('Missing table or action.');
    }
    if (!{'insert', 'update', 'delete'}.contains(action)) {
      throw SyncValidationException('Unsupported action: $action.');
    }

    final allowedColumns = allowedColumnsFor(table, action);
    if (allowedColumns == null) {
      throw SyncValidationException(
        'Unsupported operation: $action on $table.',
      );
    }

    _rejectUnknownColumns(table, payload, allowedColumns);
    _validateRoleForOperation(table, action, role, currentUserId, payload);
    _validateRequiredFields(table, action, payload);
    _validateStatus(table, payload);

    final dbPayload = <String, dynamic>{
      for (final entry in payload.entries)
        if (allowedColumns.contains(entry.key)) entry.key: entry.value,
    };

    return ValidatedSyncAction(
      table: table,
      action: action,
      payload: dbPayload,
    );
  }

  Set<String>? allowedColumnsFor(String table, String action) {
    const localUploadColumns = Hazard.localUploadColumns;
    const siteColumns = {'id', 'name', 'description', 'officer_uid'};
    const officerColumns = {
      'id',
      'first_name',
      'last_name',
      'email',
      'dob',
      'profile_image_url',
      ...localUploadColumns,
    };
    const workerColumns = {
      'id',
      'current_site_id',
      'profile_image_url',
      ...localUploadColumns,
    };
    const hseWorkerColumns = {
      'id',
      'current_site_id',
      'is_available',
      'profile_image_url',
      ...localUploadColumns,
    };
    const emergencyColumns = {
      'id',
      'officer_id',
      'officer_uid',
      'contact_name',
      'relationship',
      'personal',
      'blood_type',
      'chronic_conditions',
      'ambulance',
      'fire_brigade',
      'supervisor',
      'emergency_contact_name',
      'emergency_contact_phone',
      'emergency_contact_relation',
      'blood_group',
      'medical_conditions',
      'allergies',
      'medications',
      'home_address',
    };

    switch (table) {
      case 'hazards':
        if (action == 'insert') return Hazard.hazardInsertColumns;
        if (action == 'update') return Hazard.hazardStatusUpdateColumns;
        if (action == 'delete') return {'id'};
        break;
      case 'assign_hazards':
        if (action == 'insert') return Hazard.assignHazardInsertColumns;
        if (action == 'update') return Hazard.assignHazardUpdateColumns;
        if (action == 'delete') return {'id'};
        break;
      case 'resolved_hazards':
        if (action == 'insert') return Hazard.assignHazardInsertColumns;
        break;
      case 'sites':
        if ({'insert', 'update'}.contains(action)) return siteColumns;
        if (action == 'delete') return {'id'};
        break;
      case 'officers':
        if (action == 'update') return officerColumns;
        break;
      case 'workers':
        if (action == 'update') return workerColumns;
        if (action == 'delete') return {'id'};
        break;
      case 'hse_workers':
        if (action == 'update') return hseWorkerColumns;
        if (action == 'delete') return {'id'};
        break;
      case 'officer_emergency_contacts':
        if ({'insert', 'update'}.contains(action)) return emergencyColumns;
        break;
    }
    return null;
  }

  void _rejectUnknownColumns(
    String table,
    Map<String, dynamic> payload,
    Set<String> allowedColumns,
  ) {
    final unknown = payload.keys.where((key) => !allowedColumns.contains(key));
    if (unknown.isNotEmpty) {
      throw SyncValidationException(
        'Unknown column(s) for $table: ${unknown.join(', ')}.',
      );
    }
  }

  void _validateRoleForOperation(
    String table,
    String action,
    String? role,
    String currentUserId,
    Map<String, dynamic> payload,
  ) {
    if (role == null) {
      throw const SyncValidationException('Missing cached user role.');
    }

    if (table == 'hazards' && action == 'insert') {
      _requireRole(role, {'worker'});
      _requirePayloadOwner(payload, 'worker_id', currentUserId);
      return;
    }

    if (table == 'officers') {
      _requireRole(role, {'officer'});
      _requirePayloadOwner(payload, 'id', currentUserId);
      return;
    }

    if (table == 'hse_workers' && action == 'update' && role == 'hse_worker') {
      _requirePayloadOwner(payload, 'id', currentUserId);
      return;
    }

    if (table == 'workers' && action == 'update' && role == 'worker') {
      _requirePayloadOwner(payload, 'id', currentUserId);
      final disallowed = payload.keys.where(
        (key) => !{
          'id',
          'profile_image_url',
          ...Hazard.localUploadColumns,
        }.contains(key),
      );
      if (disallowed.isNotEmpty) {
        throw SyncValidationException(
          'Workers can only update their profile photo. Disallowed: ${disallowed.join(', ')}.',
        );
      }
      return;
    }

    if (table == 'assign_hazards' && action == 'update') {
      _requireRole(role, {'hse_worker', 'officer'});
      return;
    }

    if (_profileTables.contains(table) && action == 'delete') {
      _requireRole(role, {'officer'});
      return;
    }

    if (table == 'workers' && action == 'update') {
      _requireRole(role, {'officer'});
      return;
    }

    if (table == 'hse_workers' && action == 'update') {
      _requireRole(role, {'officer'});
      return;
    }

    if ({
      'sites',
      'resolved_hazards',
      'officer_emergency_contacts',
    }.contains(table)) {
      _requireRole(role, {'officer'});
      return;
    }

    if (table == 'hazards' && {'update', 'delete'}.contains(action)) {
      _requireRole(role, {'officer'});
      return;
    }

    if (table == 'assign_hazards' && {'insert', 'delete'}.contains(action)) {
      _requireRole(role, {'officer'});
      return;
    }

    throw SyncValidationException('Role $role cannot run $action on $table.');
  }

  void _validateRequiredFields(
    String table,
    String action,
    Map<String, dynamic> payload,
  ) {
    if ({'update', 'delete'}.contains(action)) {
      _requireNonEmpty(payload, 'id');
    }

    if (action == 'insert') {
      switch (table) {
        case 'hazards':
          _requireAll(payload, {
            'id',
            'worker_id',
            'hazard_type',
            'severity',
            'latitude',
            'longitude',
            'status',
          });
          break;
        case 'assign_hazards':
          _requireAll(payload, {'id', 'assigned_to', 'status'});
          break;
        case 'resolved_hazards':
          _requireAll(payload, {'id', 'status', 'resolved_at'});
          break;
        case 'sites':
          _requireAll(payload, {'id', 'name'});
          break;
        case 'officer_emergency_contacts':
          _requireAll(payload, {'id'});
          break;
      }
    }
  }

  void _validateStatus(String table, Map<String, dynamic> payload) {
    final status = payload['status']?.toString();
    if (status == null) return;
    if (!_allowedStatusValues.contains(status)) {
      throw SyncValidationException('Unsupported $table status: $status.');
    }
  }

  void _requireRole(String role, Set<String> allowedRoles) {
    if (!allowedRoles.contains(role)) {
      throw SyncValidationException(
        'Role $role is not allowed. Expected: ${allowedRoles.join(', ')}.',
      );
    }
  }

  void _requirePayloadOwner(
    Map<String, dynamic> payload,
    String field,
    String currentUserId,
  ) {
    final owner = payload[field]?.toString();
    if (owner == null || owner != currentUserId) {
      throw SyncValidationException(
        'Payload $field does not match signed-in user.',
      );
    }
  }

  void _requireAll(Map<String, dynamic> payload, Set<String> keys) {
    for (final key in keys) {
      _requireNonEmpty(payload, key);
    }
  }

  void _requireNonEmpty(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value == null || value.toString().trim().isEmpty) {
      throw SyncValidationException('Missing required field: $key.');
    }
  }
}

class ValidatedSyncAction {
  const ValidatedSyncAction({
    required this.table,
    required this.action,
    required this.payload,
  });

  final String table;
  final String action;
  final Map<String, dynamic> payload;
}

class ValidatedRpcAction {
  const ValidatedRpcAction({required this.name, required this.params});

  final String name;
  final Map<String, dynamic> params;
}

class SyncValidationException implements Exception {
  const SyncValidationException(this.message);

  final String message;
}
