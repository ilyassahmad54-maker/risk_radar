import '../database/database_helper.dart';
import '../logger_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sqlite_cache_store.dart';

class HazardRepository {
  HazardRepository({
    DatabaseHelper? databaseHelper,
    SqliteCacheStore? cacheStore,
  }) : _databaseHelper = databaseHelper ?? DatabaseHelper.instance,
       _cacheStore = cacheStore ?? SqliteCacheStore.instance;

  static const _hazardsKey = 'rr_hazards';
  static const _assignHazardsKey = 'rr_assign_hazards';
  static const _ongoingHazardsKey = 'rr_ongoing_hazards';
  static const _resolvedHazardsKey = 'rr_resolved_hazards';
  static const _hseAssignedTasksKey = 'rr_hse_assigned_tasks';
  static const _hseLocallyResolvedTaskIdsKey =
      'rr_hse_locally_resolved_task_ids';
  static const _hseSiteHazardsKey = 'rr_hse_site_hazards';
  static const _hseResolvedHazardsKey = 'rr_hse_resolved_hazards';
  static const _officerActiveHazardsKey = 'rr_officer_active_hazards';
  static const _officerResolvedHazardsKey = 'rr_officer_resolved_hazards';

  final DatabaseHelper _databaseHelper;
  final SqliteCacheStore _cacheStore;
  final SupabaseClient _supabase = Supabase.instance.client;

  Future<List<Map<String, dynamic>>> fetchActiveHazardsForCurrentUser({
    required String role,
    bool allowCacheFallback = true,
  }) async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      return const <Map<String, dynamic>>[];
    }

    try {
      switch (role) {
        case 'officer':
          return _fetchOfficerActiveHazards(userId);
        case 'worker':
          return _fetchWorkerActiveHazards(userId);
        case 'hse_worker':
          return _fetchHseActiveHazards(userId);
        default:
          return const <Map<String, dynamic>>[];
      }
    } catch (e, s) {
      LoggerService.error('Failed to fetch active hazards for provider', e, s);
      if (!allowCacheFallback) {
        rethrow;
      }
      return getCachedActiveHazardsForRole(role);
    }
  }

  Future<List<Map<String, dynamic>>> getCachedActiveHazardsForRole(
    String? role,
  ) async {
    switch (role) {
      case 'officer':
        return await getOfficerActiveHazards() ??
            const <Map<String, dynamic>>[];
      case 'worker':
        return getOngoingHazards();
      case 'hse_worker':
        return _filterHseLocallyResolvedRows(
          await getHseAssignedTasks() ?? const <Map<String, dynamic>>[],
        );
      default:
        return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchOfficerActiveHazards(
    String userId,
  ) async {
    // Related hazard records use officers.id as their officer_uid
    // foreign key. The authenticated officer UUID is therefore the
    // contractor identifier used by hazards and assign_hazards.
    final String officerUid = userId;

    final List<Map<String, dynamic>> reported = await _mapResponseRows(
      _supabase
          .from('hazards')
          .select()
          .eq('officer_uid', officerUid)
          .not('status', 'in', '(resolved,"resolved by other")'),
    );
    final List<Map<String, dynamic>> assigned = await _mapResponseRows(
      _supabase
          .from('assign_hazards')
          .select()
          .eq('officer_uid', officerUid)
          .not('status', 'in', '(resolved,"resolved by other")'),
    );
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      ...reported,
      ...assigned,
    ];
    await saveOfficerActiveHazards(rows);
    return rows;
  }

  Future<List<Map<String, dynamic>>> _fetchWorkerActiveHazards(
    String userId,
  ) async {
    final List<Map<String, dynamic>> reported = await _mapResponseRows(
      _supabase
          .from('hazards')
          .select()
          .eq('worker_id', userId)
          .not('status', 'in', '(resolved,"resolved by other")'),
    );
    final List<Map<String, dynamic>> assigned = await _mapResponseRows(
      _supabase
          .from('assign_hazards')
          .select()
          .eq('worker_id', userId)
          .not('status', 'in', '(resolved,"resolved by other")'),
    );
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      ...reported,
      ...assigned,
    ];
    await saveOngoingHazards(rows);
    return rows;
  }

  Future<List<Map<String, dynamic>>> _fetchHseActiveHazards(
    String userId,
  ) async {
    final List<Map<String, dynamic>> rows = await _mapResponseRows(
      _supabase
          .from('assign_hazards')
          .select()
          .eq('assigned_to', userId)
          .not('status', 'in', '(resolved,"resolved by other")'),
    );
    final List<Map<String, dynamic>> activeRows =
        await _filterHseLocallyResolvedRows(rows);
    await saveHseAssignedTasks(activeRows);
    return activeRows;
  }

  Future<List<Map<String, dynamic>>> _mapResponseRows(
    Future<List<Map<String, dynamic>>> query,
  ) async {
    final List<Map<String, dynamic>> rows = await query;
    return rows
        .map((Map<String, dynamic> row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Future<void> saveHazards(List<Map<String, dynamic>> rows) async {
    for (final row in rows) {
      await _upsert(row, sourceTable: DatabaseHelper.hazardsTable);
    }
  }

  Future<List<Map<String, dynamic>>> getHazards() {
    return _getOrMigrate(
      sourceTable: DatabaseHelper.hazardsTable,
      legacyCacheKey: _hazardsKey,
      legacyDefault: const [],
    );
  }

  Future<void> appendHazard(Map<String, dynamic> row) async {
    await _upsert(row, sourceTable: DatabaseHelper.hazardsTable);
  }

  Future<void> updateHazard(Map<String, dynamic> updated) async {
    await _upsert(updated, sourceTable: DatabaseHelper.hazardsTable);
  }

  Future<void> saveAssignHazards(List<Map<String, dynamic>> rows) async {
    for (final row in rows) {
      await _upsert(row, sourceTable: 'assign_hazards');
    }
  }

  Future<List<Map<String, dynamic>>> getAssignHazards() {
    return _getOrMigrate(
      sourceTable: 'assign_hazards',
      legacyCacheKey: _assignHazardsKey,
      legacyDefault: const [],
    );
  }

  Future<void> updateAssignHazard(Map<String, dynamic> updated) async {
    await _upsert(updated, sourceTable: 'assign_hazards');
  }

  Future<void> saveOngoingHazards(List<Map<String, dynamic>> rows) async {
    for (final row in rows) {
      await _upsert(row, sourceTable: 'ongoing_hazards');
    }
  }

  Future<void> replaceOngoingHazards(List<Map<String, dynamic>> rows) async {
    await _replaceAllRows(rows, sourceTable: 'ongoing_hazards');
  }

  Future<List<Map<String, dynamic>>> getOngoingHazards() {
    return _getOrMigrate(
      sourceTable: 'ongoing_hazards',
      legacyCacheKey: _ongoingHazardsKey,
      legacyDefault: const [],
    );
  }

  Future<void> saveResolvedHazards(List<Map<String, dynamic>> rows) async {
    for (final row in rows) {
      await _upsert(row, sourceTable: 'resolved_hazards');
    }
  }

  Future<List<Map<String, dynamic>>> getResolvedHazards() {
    return _getOrMigrate(
      sourceTable: 'resolved_hazards',
      legacyCacheKey: _resolvedHazardsKey,
      legacyDefault: const [],
    );
  }

  Future<void> saveHseAssignedTasks(List<Object?> rows) async {
    final List<Map<String, Object?>> activeRows =
        await _filterHseLocallyResolvedObjectRows(_objectRows(rows));
    await _replaceAllRows(activeRows, sourceTable: 'hse_assigned_tasks');
    await _cacheStore.writeJson(_hseAssignedTasksKey, activeRows);
  }

  Future<List<Map<String, dynamic>>?> getHseAssignedTasks() {
    return _getOrMigrateNullable(
      sourceTable: 'hse_assigned_tasks',
      legacyCacheKey: _hseAssignedTasksKey,
      emptyLegacyMeansEmpty: true,
    );
  }

  Future<List<Map<String, dynamic>>> _filterHseLocallyResolvedRows(
    List<Map<String, dynamic>> rows,
  ) async {
    final Set<String> resolvedIds = await getHseLocallyResolvedTaskIds();
    if (resolvedIds.isEmpty) {
      return rows;
    }

    return rows
        .where(
          (Map<String, dynamic> row) => !_rowIdentifiers(
            Map<String, Object?>.from(row),
          ).any(resolvedIds.contains),
        )
        .toList(growable: false);
  }

  Set<String> _rowIdentifiers(Map<String, Object?> row) {
    return <String>{
      ?row['id']?.toString(),
      ?row['assignment_id']?.toString(),
      ?row['hazard_id']?.toString(),
    }.where((String value) => value.trim().isNotEmpty).toSet();
  }

  Future<List<Map<String, Object?>>> _filterHseLocallyResolvedObjectRows(
    List<Map<String, Object?>> rows,
  ) async {
    final Set<String> resolvedIds = await getHseLocallyResolvedTaskIds();
    if (resolvedIds.isEmpty) {
      return rows;
    }

    return rows
        .where(
          (Map<String, Object?> row) =>
              !_rowIdentifiers(row).any(resolvedIds.contains),
        )
        .toList(growable: false);
  }

  List<Map<String, Object?>> _objectRows(List<Object?> rows) {
    final List<Map<String, Object?>> mappedRows = <Map<String, Object?>>[];
    for (final Object? row in rows) {
      if (row is Map<String, Object?>) {
        mappedRows.add(row);
      } else if (row is Map) {
        mappedRows.add(Map<String, Object?>.from(row));
      }
    }
    return mappedRows;
  }

  Future<void> markHseTasksResolvedLocally(Iterable<String> taskIds) async {
    final Set<String> resolvedIds = await getHseLocallyResolvedTaskIds();
    resolvedIds.addAll(
      taskIds.where((String taskId) => taskId.trim().isNotEmpty),
    );
    await _cacheStore.writeJson(
      _hseLocallyResolvedTaskIdsKey,
      resolvedIds.toList(growable: false),
    );
  }

  Future<Set<String>> getHseLocallyResolvedTaskIds() async {
    final String? rawIds = _cacheStore.readString(
      _hseLocallyResolvedTaskIdsKey,
    );
    if (rawIds == null || rawIds.trim().isEmpty) {
      return <String>{};
    }

    try {
      final Object? decoded = _cacheStore.readJson(
        _hseLocallyResolvedTaskIdsKey,
      );
      if (decoded is List) {
        return decoded
            .map((Object? taskId) {
              if (taskId is Map) {
                return taskId['id']?.toString();
              }
              return taskId?.toString();
            })
            .whereType<String>()
            .where((String taskId) => taskId.trim().isNotEmpty)
            .toSet();
      }
    } catch (_) {
      return <String>{};
    }

    return <String>{};
  }

  Future<void> saveHseSiteHazards(List<dynamic> rows) async {
    await _upsertAllDynamic(rows, sourceTable: 'hse_site_hazards');
  }

  Future<List<Map<String, dynamic>>?> getHseSiteHazards() {
    return _getOrMigrateNullable(
      sourceTable: 'hse_site_hazards',
      legacyCacheKey: _hseSiteHazardsKey,
    );
  }

  Future<void> saveHseResolvedHazards(List<dynamic> rows) async {
    await _upsertAllDynamic(rows, sourceTable: 'hse_resolved_hazards');
  }

  Future<List<Map<String, dynamic>>?> getHseResolvedHazards() {
    return _getOrMigrateNullable(
      sourceTable: 'hse_resolved_hazards',
      legacyCacheKey: _hseResolvedHazardsKey,
    );
  }

  Future<void> saveOfficerActiveHazards(List<dynamic> rows) async {
    await _upsertAllDynamic(rows, sourceTable: 'officer_active_hazards');
  }

  Future<List<Map<String, dynamic>>?> getOfficerActiveHazards() {
    return _getOrMigrateNullable(
      sourceTable: 'officer_active_hazards',
      legacyCacheKey: _officerActiveHazardsKey,
    );
  }

  Future<void> saveOfficerResolvedHazards(List<dynamic> rows) async {
    await _upsertAllDynamic(rows, sourceTable: 'officer_resolved_hazards');
  }

  Future<List<Map<String, dynamic>>?> getOfficerResolvedHazards() {
    return _getOrMigrateNullable(
      sourceTable: 'officer_resolved_hazards',
      legacyCacheKey: _officerResolvedHazardsKey,
    );
  }

  Future<List<Map<String, dynamic>>> _getOrMigrate({
    required String sourceTable,
    required String legacyCacheKey,
    required List<Map<String, dynamic>> legacyDefault,
  }) async {
    final sqliteRows = await _databaseHelper.getHazards(
      sourceTable: sourceTable,
    );
    if (sqliteRows.isNotEmpty) return sqliteRows;

    final rows = _cacheStore.readMapList(legacyCacheKey) ?? legacyDefault;
    if (rows.isNotEmpty) {
      await _upsertAllDynamic(rows, sourceTable: sourceTable);
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>?> _getOrMigrateNullable({
    required String sourceTable,
    required String legacyCacheKey,
    bool emptyLegacyMeansEmpty = false,
  }) async {
    final sqliteRows = await _databaseHelper.getHazards(
      sourceTable: sourceTable,
    );
    if (sqliteRows.isNotEmpty) return sqliteRows;

    final rows = _cacheStore.readMapList(legacyCacheKey);
    if (rows != null && rows.isNotEmpty) {
      await _upsertAllDynamic(rows, sourceTable: sourceTable);
    }
    if (rows != null && rows.isEmpty && emptyLegacyMeansEmpty) {
      return const <Map<String, dynamic>>[];
    }
    return rows;
  }

  Future<void> _upsertAllDynamic(
    List<dynamic> rows, {
    required String sourceTable,
  }) async {
    for (final row in rows) {
      if (row is Map<String, dynamic>) {
        await _upsert(row, sourceTable: sourceTable);
      } else if (row is Map) {
        await _upsert(Map<String, dynamic>.from(row), sourceTable: sourceTable);
      }
    }
  }

  Future<void> _replaceAllRows(
    List<Object?> rows, {
    required String sourceTable,
  }) async {
    await _databaseHelper.replaceHazardsForSource(
      sourceTable: sourceTable,
      rows: _objectRows(rows),
    );
  }

  Future<void> _upsert(
    Map<String, dynamic> row, {
    required String sourceTable,
  }) async {
    final id = row['id']?.toString();
    if (id == null || id.isEmpty) return;

    await _databaseHelper.upsertHazard(
      id: id,
      sourceTable: sourceTable,
      payload: row,
    );
  }
}
