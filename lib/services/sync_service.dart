import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'connectivity_service.dart';
import 'logger_service.dart';
import 'repositories/auth_repository.dart';
import 'repositories/sync_repository.dart';
import 'sync_policy.dart';

class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  final SupabaseClient _supabase = Supabase.instance.client;
  final AuthRepository _authRepository = AuthRepository();
  final SyncRepository _syncRepository = SyncRepository();
  final SyncPolicy _syncPolicy = const SyncPolicy();
  Completer<void>? _runningCompleter;
  bool _isRunning = false;

  Future<SyncResult> run() async {
    if (_isRunning) {
      final Completer<void>? runningCompleter = _runningCompleter;
      if (runningCompleter != null) {
        try {
          await runningCompleter.future.timeout(const Duration(seconds: 12));
        } on TimeoutException {
          return const SyncResult.skipped(reason: 'already_running');
        }
      }
    }

    if (!await _isOnline()) return const SyncResult.skipped(reason: 'offline');

    final queue = await _syncRepository.getPendingActions();
    if (queue.isEmpty) return const SyncResult.empty();

    _isRunning = true;
    _runningCompleter = Completer<void>();
    var synced = 0;
    var rejected = 0;
    var failed = 0;
    var skipped = 0;

    try {
      for (final item in List<Map<String, dynamic>>.from(queue)) {
        final itemResult = await _syncItem(item);
        switch (itemResult) {
          case _SyncItemResult.synced:
            synced++;
            break;
          case _SyncItemResult.rejected:
            rejected++;
            break;
          case _SyncItemResult.failed:
            failed++;
            break;
          case _SyncItemResult.skipped:
            skipped++;
            break;
        }
      }
    } finally {
      _isRunning = false;
      _runningCompleter?.complete();
      _runningCompleter = null;
    }

    return SyncResult(
      attempted: queue.length,
      synced: synced,
      rejected: rejected,
      failed: failed,
      skipped: skipped,
      pending: (await _syncRepository.getPendingActions()).length,
    );
  }

  Future<bool> _isOnline() async {
    await ConnectivityService.instance.refresh();
    return ConnectivityService.instance.isOnline;
  }

  Future<_SyncItemResult> _syncItem(Map<String, dynamic> item) async {
    final id = item['id']?.toString();
    final rawPayload = item['payload'];
    final currentUserId = _supabase.auth.currentUser?.id;

    if (currentUserId == null) {
      LoggerService.info('Sync paused because no user is signed in.');
      return _SyncItemResult.skipped;
    }

    if (id == null || rawPayload is! Map) {
      LoggerService.warning('Skipping malformed sync item', item);
      if (id != null) await _syncRepository.removeAction(id);
      return _SyncItemResult.rejected;
    }

    try {
      final payload = Map<String, dynamic>.from(rawPayload);
      if (item['action']?.toString() == 'rpc') {
        final operation = _syncPolicy.validateRpcAction(
          item: item,
          payload: payload,
          role: _authRepository.getRole(),
        );
        await _supabase.rpc(operation.name, params: operation.params);
        await _syncRepository.removeAction(id);
        LoggerService.info('Synced queued RPC $id');
        return _SyncItemResult.synced;
      }

      final operation = _syncPolicy.validateSyncAction(
        item: item,
        payload: payload,
        role: _authRepository.getRole(),
        currentUserId: currentUserId,
      );
      final dbPayload = await _preparePayload(
        operation.table,
        operation.payload,
      );

      switch (operation.action) {
        case 'insert':
          await _supabase.from(operation.table).insert(dbPayload);
          break;
        case 'update':
          final rowId = dbPayload.remove('id') ?? operation.payload['id'];
          if (rowId == null) throw StateError('Missing id for update');
          await _supabase
              .from(operation.table)
              .update(dbPayload)
              .eq('id', rowId);
          break;
        case 'delete':
          final rowId = dbPayload['id'] ?? operation.payload['id'];
          if (rowId == null) throw StateError('Missing id for delete');
          await _supabase.from(operation.table).delete().eq('id', rowId);
          break;
      }

      await _syncRepository.removeAction(id);
      LoggerService.info('Synced queued action $id');
      return _SyncItemResult.synced;
    } on SyncValidationException catch (e) {
      LoggerService.warning('Dropping rejected sync item $id', e.message);
      await _syncRepository.removeAction(id);
      return _SyncItemResult.rejected;
    } catch (e) {
      LoggerService.warning('Sync failed for item $id', e);
      return _SyncItemResult.failed;
    }
  }

  Future<Map<String, dynamic>> _preparePayload(
    String table,
    Map<String, dynamic> payload,
  ) async {
    final dbPayload = Map<String, dynamic>.from(payload);

    final imagePaths = _stringList(dbPayload.remove('image_paths'));
    final voicePaths = _stringList(dbPayload.remove('voice_paths'));
    if (table == 'assign_hazards' && dbPayload.containsKey('report_number')) {
      final int? reportNumber = _reportNumber(dbPayload['report_number']);
      if (reportNumber == null) {
        dbPayload.remove('report_number');
      } else {
        dbPayload['report_number'] = reportNumber;
      }
    }
    final isProfileTable =
        table == 'officers' || table == 'workers' || table == 'hse_workers';

    if (imagePaths.isNotEmpty) {
      final urls = await _uploadFiles(
        paths: imagePaths,
        bucket: isProfileTable
            ? 'profile-images'
            : table == 'assign_hazards'
            ? 'resolutions'
            : 'hazard-images',
        prefix: isProfileTable
            ? _supabase.auth.currentUser?.id
            : null,
      );
      dbPayload[isProfileTable
          ? 'profile_image_url'
          : table == 'assign_hazards'
          ? 'resolution_image_url'
          : 'image_url'] = urls.isNotEmpty
          ? urls.join(',')
          : null;
    }

    if (voicePaths.isNotEmpty) {
      final urls = await _uploadFiles(
        paths: voicePaths,
        bucket: table == 'assign_hazards' ? 'resolutions' : 'voice_notes',
        prefix: table == 'assign_hazards' ? null : 'voice_notes',
      );
      dbPayload[table == 'assign_hazards'
          ? 'resolution_voice_note_url'
          : 'voice_note_url'] = urls.isNotEmpty
          ? urls.join(',')
          : null;
    }

    return dbPayload;
  }

  int? _reportNumber(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }

    final String text = value.toString().trim();
    if (text.isEmpty) {
      return null;
    }

    final int? directNumber = int.tryParse(text);
    if (directNumber != null) {
      return directNumber;
    }

    final RegExpMatch? prefixedMatch = RegExp(
      r'^RR-(\d{4})-(\d+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (prefixedMatch == null) {
      return null;
    }

    final int? year = int.tryParse(prefixedMatch.group(1) ?? '');
    final int? suffix = int.tryParse(prefixedMatch.group(2) ?? '');
    if (year == null || suffix == null) {
      return null;
    }
    return (year * 100000) + suffix;
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => item?.toString())
          .whereType<String>()
          .where((item) => item.trim().isNotEmpty)
          .toList();
    }
    return const [];
  }

  Future<List<String>> _uploadFiles({
    required List<String> paths,
    required String bucket,
    String? prefix,
  }) async {
    final urls = <String>[];
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) continue;

      final fileName = _fileName(path);
      final storagePath = [
        if (prefix != null && prefix.isNotEmpty) prefix,
        '${const Uuid().v4()}_$fileName',
      ].join('/');

      await _supabase.storage.from(bucket).upload(storagePath, file);
      urls.add(_supabase.storage.from(bucket).getPublicUrl(storagePath));
    }
    return urls;
  }

  String _fileName(String path) {
    final normalised = path.replaceAll('\\', '/');
    final name = normalised.split('/').last;
    return name.isEmpty ? 'upload.bin' : name;
  }
}

class SyncResult {
  const SyncResult({
    required this.attempted,
    required this.synced,
    required this.rejected,
    required this.failed,
    required this.skipped,
    required this.pending,
    this.reason,
  });

  const SyncResult.empty()
    : attempted = 0,
      synced = 0,
      rejected = 0,
      failed = 0,
      skipped = 0,
      pending = 0,
      reason = null;

  const SyncResult.skipped({required this.reason})
    : attempted = 0,
      synced = 0,
      rejected = 0,
      failed = 0,
      skipped = 0,
      pending = 0;

  final int attempted;
  final int synced;
  final int rejected;
  final int failed;
  final int skipped;
  final int pending;
  final String? reason;

  bool get hasFailures => failed > 0;
  bool get didWork => synced > 0 || rejected > 0;
}

enum _SyncItemResult { synced, rejected, failed, skipped }
