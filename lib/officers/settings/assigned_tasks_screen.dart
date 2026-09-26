// lib/officers/settings/assigned_tasks_screen.dart
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:riskradar/services/repositories/officer_repository.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';
import 'package:riskradar/services/repositories/sync_repository.dart';

class AssignTaskScreen extends StatefulWidget {
  // CORRECTED: Changed hazardId and siteId from int to String to match UUID type.
  final String hazardId;
  final String siteId;
  final bool isReassigning;

  const AssignTaskScreen({
    super.key,
    required this.hazardId,
    required this.siteId,
    this.isReassigning = false,
  });

  @override
  State<AssignTaskScreen> createState() => _AssignTaskScreenState();
}

class _AssignTaskScreenState extends State<AssignTaskScreen> {
  final SupabaseClient supabase = Supabase.instance.client;
  final HazardRepository _hazardRepository = HazardRepository();
  final SyncRepository _syncRepository = SyncRepository();

  bool _isLoading = true;
  bool _isSubmitting = false;
  List<Map<String, dynamic>> _workers = [];
  final Map<String, int> _hazardCounts = {};
  String? _selectedWorkerId;

  @override
  void initState() {
    super.initState();
    _loadWorkersCacheFirst();
  }

  Future<void> _loadWorkersCacheFirst() async {
    final cachedWorkers = OfficerRepository.instance.getOfficerHseWorkers();
    final cachedHazards = await _hazardRepository.getOfficerActiveHazards();

    if (cachedWorkers != null) {
      _applyWorkerRows(cachedWorkers, cachedHazards ?? []);
      if (mounted) {
        setState(() => _isLoading = false);
      } else {
        _isLoading = false;
      }
    }

    _fetchWorkersInZone(showBlockingLoader: cachedWorkers == null);
  }

  void _applyWorkerRows(
    List<Map<String, dynamic>> workers,
    List<Map<String, dynamic>> hazards,
  ) {
    final workerList = workers
        .where(
          (worker) => worker['current_site_id']?.toString() == widget.siteId,
        )
        .toList();

    _hazardCounts.clear();
    for (final hazard in hazards) {
      final status = hazard['status']?.toString();
      if (status != 'assigned' && status != 'in_progress') continue;

      final assignments = hazard['assign_hazards'];
      if (assignments is List && assignments.isNotEmpty) {
        for (final assignment in assignments) {
          if (assignment is! Map) continue;
          final hseWorker = assignment['hse_worker'];
          final workerId = hseWorker is Map
              ? hseWorker['id'] ?? assignment['assigned_to']
              : assignment['assigned_to'];
          if (workerId != null) {
            final key = workerId.toString();
            _hazardCounts[key] = (_hazardCounts[key] ?? 0) + 1;
          }
        }
      } else {
        final workerId = hazard['assigned_to'];
        if (workerId != null) {
          final key = workerId.toString();
          _hazardCounts[key] = (_hazardCounts[key] ?? 0) + 1;
        }
      }
    }

    if (mounted) {
      setState(() => _workers = workerList);
    }
  }

  Future<void> _fetchWorkersInZone({bool showBlockingLoader = true}) async {
    if (showBlockingLoader && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      // This query is now correct because widget.siteId is a String.
      final workersResponse = await supabase
          .from('hse_workers')
          .select('id, first_name, last_name, profile_image_url, designation')
          .eq('current_site_id', widget.siteId)
          .eq('role', 'hse_worker')
          .eq('is_active', true)
          .eq('is_available', true);

      final workerList = List<Map<String, dynamic>>.from(workersResponse);
      if (workerList.isEmpty) {
        if (mounted) {
          setState(() {
            _workers = [];
            _isLoading = false;
          });
        }
        return;
      }

      final workerIds = workerList.map((w) => w['id'] as String).toList();

      final hazardsResponse = await supabase
          .from('assign_hazards')
          .select('assigned_to')
          .inFilter('assigned_to', workerIds)
          .inFilter('status', ['assigned', 'in_progress']);

      final cachedHazards =
          await _hazardRepository.getOfficerActiveHazards() ?? [];
      _applyWorkerRows(workerList, cachedHazards);
      _hazardCounts.clear();
      for (final hazard in hazardsResponse) {
        final workerId = hazard['assigned_to'] as String?;
        if (workerId != null) {
          _hazardCounts[workerId] = (_hazardCounts[workerId] ?? 0) + 1;
        }
      }
      await _mergeOfficerHseWorkers(workerList);
      if (mounted) {
        setState(() => _workers = workerList);
      }
    } on SocketException {
      final cachedWorkers =
          OfficerRepository.instance.getOfficerHseWorkers() ?? [];
      final cachedHazards =
          await _hazardRepository.getOfficerActiveHazards() ?? [];
      _applyWorkerRows(cachedWorkers, cachedHazards);
    } catch (e) {
      debugPrint("Error fetching workers: $e");
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to load workers')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _mergeOfficerHseWorkers(
    List<Map<String, dynamic>> freshSiteWorkers,
  ) async {
    final merged = OfficerRepository.instance.getOfficerHseWorkers() ?? [];
    final byId = {
      for (final worker in merged)
        if (worker['id'] != null) worker['id'].toString(): worker,
    };
    for (final worker in freshSiteWorkers) {
      final id = worker['id']?.toString();
      if (id != null) byId[id] = worker;
    }
    await OfficerRepository.instance.saveOfficerHseWorkers(
      byId.values.toList(),
    );
  }

  Future<void> _submitAssignment() async {
    if (_selectedWorkerId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a worker')));
      return;
    }
    setState(() => _isSubmitting = true);

    try {
      final assignedAt = DateTime.now().toIso8601String();
      await supabase.rpc(
        'assign_hazard_to_hse',
        params: {
          'p_hazard_id': widget.hazardId,
          'p_assigned_to': _selectedWorkerId,
          'p_assigned_at': assignedAt,
        },
      );
      await _updateCachedAssignment(assignedAt);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isReassigning
                  ? 'Task reassigned successfully!'
                  : 'Task assigned successfully!',
            ),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } on SocketException {
      try {
        await _queueAssignmentOffline();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Assignment saved offline - will sync when online'),
              backgroundColor: Colors.orange,
            ),
          );
          Navigator.pop(context, true);
        }
      } catch (e) {
        debugPrint("Error queueing assignment offline: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Cannot save assignment offline: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Error assigning task: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to assign task: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _queueAssignmentOffline() async {
    final now = DateTime.now().toIso8601String();

    if (widget.isReassigning) {
      await _syncRepository.enqueueAction(
        id: 'officer_reassign_${widget.hazardId}_${DateTime.now().millisecondsSinceEpoch}',
        table: 'assign_hazards',
        action: 'update',
        payload: {
          'id': widget.hazardId,
          'assigned_to': _selectedWorkerId,
          'assigned_at': now,
          'status': 'assigned',
        },
      );
      await _updateCachedAssignment(now);
      return;
    }

    final active = await _hazardRepository.getOfficerActiveHazards() ?? [];
    final hazard = active.firstWhere(
      (item) => item['id']?.toString() == widget.hazardId,
      orElse: () => {},
    );
    if (hazard.isEmpty) {
      throw StateError('Hazard details are not cached for offline assignment.');
    }

    await _syncRepository.enqueueAction(
      id: 'officer_assign_${widget.hazardId}_${DateTime.now().millisecondsSinceEpoch}',
      table: 'assign_hazard_to_hse',
      action: 'rpc',
      payload: {
        'hazard_id': widget.hazardId,
        'assigned_to': _selectedWorkerId,
        'assigned_at': now,
      },
    );

    await _updateCachedAssignment(now, cachedHazards: active);
  }

  Future<void> _updateCachedAssignment(
    String assignedAt, {
    List<Map<String, dynamic>>? cachedHazards,
  }) async {
    final active =
        cachedHazards ??
        (await _hazardRepository.getOfficerActiveHazards()) ??
        [];
    final hazard = active.firstWhere(
      (item) => item['id']?.toString() == widget.hazardId,
      orElse: () => {},
    );
    if (hazard.isEmpty) return;

    final selectedWorker = _workers.firstWhere(
      (worker) => worker['id']?.toString() == _selectedWorkerId,
      orElse: () => {},
    );

    hazard['status'] = 'assigned';
    hazard['assigned_to'] = _selectedWorkerId;
    hazard['assigned_at'] = assignedAt;
    hazard['assign_hazards'] = [
      {
        'id': hazard['id'],
        'status': 'assigned',
        'assigned_at': assignedAt,
        'assigned_to': _selectedWorkerId,
        if (selectedWorker.isNotEmpty) 'hse_worker': selectedWorker,
      },
    ];
    await _hazardRepository.saveOfficerActiveHazards(active);
  }

  String _capitalize(String text) {
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    R.init(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isReassigning ? 'Reassign Hazard' : 'Assign Hazard'),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : Padding(
              padding: EdgeInsets.all(R.blockH * 4),
              child: Column(
                children: [
                  Expanded(
                    child: _workers.isEmpty
                        ? Center(
                            child: Text(
                              "No HSE workers found in this zone.",
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: R.blockH * 4,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _workers.length,
                            itemBuilder: (context, index) {
                              final worker = _workers[index];
                              final workerId = worker['id'] as String;
                              final workerName =
                                  "${_capitalize(worker['first_name'] ?? '')} ${_capitalize(worker['last_name'] ?? '')}"
                                      .trim();
                              final profileImage = worker['profile_image_url'];
                              final isSelected = _selectedWorkerId == workerId;
                              final hazardCount = _hazardCounts[workerId] ?? 0;

                              return GestureDetector(
                                onTap: () => setState(
                                  () => _selectedWorkerId = workerId,
                                ),
                                child: Card(
                                  color: Theme.of(context).colorScheme.surface,
                                  margin: EdgeInsets.symmetric(
                                    vertical: R.blockV * 1,
                                  ),
                                  elevation: isSelected ? 8 : 4,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15),
                                    side: isSelected
                                        ? BorderSide(
                                            color: Theme.of(
                                              context,
                                            ).primaryColor,
                                            width: 2,
                                          )
                                        : BorderSide.none,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 16,
                                    ),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 28,
                                          backgroundColor: Theme.of(
                                            context,
                                          ).primaryColorLight,
                                          backgroundImage: profileImage != null
                                              ? CachedNetworkImageProvider(
                                                  profileImage,
                                                )
                                              : null,
                                          child: profileImage == null
                                              ? Text(
                                                  workerName.isNotEmpty
                                                      ? workerName[0]
                                                      : '?',
                                                  style: TextStyle(
                                                    fontSize: R.blockH * 6,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                )
                                              : null,
                                        ),
                                        SizedBox(width: R.blockH * 4.267),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                workerName.isNotEmpty
                                                    ? workerName
                                                    : 'Unnamed Worker',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: R.blockH * 4,
                                                ),
                                              ),
                                              Text(
                                                worker['designation'] ?? 'N/A',
                                                style: TextStyle(
                                                  fontSize: R.blockH * 3.25,
                                                  color: Colors.grey.shade400,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Chip(
                                          label: Text(
                                            hazardCount == 0
                                                ? "Free"
                                                : "$hazardCount Active",
                                            style: TextStyle(
                                              fontSize: R.blockH * 2.75,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                          backgroundColor: hazardCount == 0
                                              ? Colors.green.shade600
                                              : Colors.orange.shade800,
                                        ),
                                        Radio<String>(
                                          value: workerId,
                                          // ignore: deprecated_member_use
                                          groupValue: _selectedWorkerId,
                                          // ignore: deprecated_member_use
                                          onChanged: (String? value) {
                                            setState(() {
                                              _selectedWorkerId = value;
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  SizedBox(height: R.blockV * 2), // Added for spacing
                  ElevatedButton.icon(
                    icon: _isSubmitting
                        ? Container(
                            width: R.blockH * 6.4,
                            height: R.blockV * 3,
                            padding: EdgeInsets.all(R.blockH * 0.5),
                            child: const CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          )
                        : Icon(Icons.assignment_turned_in_rounded),
                    label: Text(
                      widget.isReassigning ? 'Reassign Task' : 'Assign Task',
                    ),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _isSubmitting || _workers.isEmpty
                        ? null
                        : _submitAssignment,
                  ),
                ],
              ),
            ),
    );
  }
}
