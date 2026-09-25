// lib/officers/sites/officer_sites_screen.dart
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:riskradar/officers/sites/site_personnel_screen.dart';
import 'package:riskradar/services/connectivity_service.dart';
import 'package:riskradar/services/repositories/officer_repository.dart';
import 'package:riskradar/services/repositories/sync_repository.dart';
import 'package:riskradar/shared/security/input_sanitizer.dart';
import 'package:riskradar/shared/theme/app_colors.dart';
import 'package:uuid/uuid.dart';

class OfficerSitesScreen extends StatefulWidget {
  const OfficerSitesScreen({super.key});

  @override
  State<OfficerSitesScreen> createState() => OfficerSitesScreenState();
}

class OfficerSitesScreenState extends State<OfficerSitesScreen> {
  final supabase = Supabase.instance.client;
  final SyncRepository _syncRepository = SyncRepository();
  late Future<List<Map<String, dynamic>>> _sitesFuture;
  String? _officerId;

  @override
  void initState() {
    super.initState();
    _sitesFuture = Future.value(
      OfficerRepository.instance.getOfficerSites() ?? [],
    );
    _initializeAndFetchData();
  }

  Future<void> _initializeAndFetchData() async {
    _officerId = supabase.auth.currentUser?.id;
    await _fetchSites();
  }

  Future<void> refresh() async {
    _officerId ??= supabase.auth.currentUser?.id;
    await _fetchSites(bypassCache: true);
  }

  Future<void> _fetchSites({bool bypassCache = false}) async {
    if (bypassCache) {
      await ConnectivityService.instance.refresh();
    }
    final bool liveOnly = bypassCache && ConnectivityService.instance.isOnline;

    if (_officerId == null) {
      final cached = liveOnly
          ? <Map<String, dynamic>>[]
          : OfficerRepository.instance.getOfficerSites() ?? [];
      if (mounted) {
        setState(() {
          _sitesFuture = Future.value(cached);
        });
      }
      return;
    }

    final future = supabase
        .from('sites')
        .select(
          '*, workers!current_site_id(count), hse_workers!current_site_id(count)',
        )
        .eq('officer_uid', _officerId!)
        .order('name', ascending: true)
        .then((data) async {
          final rows = List<Map<String, dynamic>>.from(data);
          await OfficerRepository.instance.saveOfficerSites(rows);
          return rows;
        })
        .catchError((error) {
          if (liveOnly) {
            throw error;
          }
          debugPrint('Officer sites offline/error - using cached data: $error');
          return OfficerRepository.instance.getOfficerSites() ??
              <Map<String, dynamic>>[];
        });

    if (mounted) {
      setState(() {
        _sitesFuture = future;
      });
    } else {
      _sitesFuture = future;
    }
    await future.catchError((_) => <Map<String, dynamic>>[]);
  }

  Future<void> _addOrEditSite({Map<String, dynamic>? site}) async {
    final nameController = TextEditingController(text: site?['name'] ?? '');
    final descController = TextEditingController(
      text: site?['description'] ?? '',
    );
    final isEditing = site != null;
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final size = mediaQuery.size;
        final visibleHeight =
            size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
        const dialogBg = Color(0xFF123636);
        const fieldBg = Color(0x33FFFFFF);
        const textColor = Colors.white;

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size.width * 0.056),
          ),
          backgroundColor: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: dialogBg,
              borderRadius: BorderRadius.circular(size.width * 0.056),
              border: Border.all(
                color: AppColors.surfaceTeal.withValues(alpha: 0.8),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: size.width * 0.046,
                  offset: Offset(size.width * 0.0, visibleHeight * 0.010),
                ),
              ],
            ),
            padding: EdgeInsets.fromLTRB(
              size.width * 0.051,
              visibleHeight * 0.020,
              size.width * 0.051,
              visibleHeight * 0.015,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(size.width * 0.020),
                      decoration: BoxDecoration(
                        color: AppColors.brandTeal.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(size.width * 0.026),
                      ),
                      child: Icon(
                        isEditing
                            ? Icons.edit_location_alt_rounded
                            : Icons.add_location_alt_rounded,
                        color: AppColors.accentGold,
                      ),
                    ),
                    SizedBox(width: size.width * 0.032),
                    Text(
                      isEditing ? 'Edit Site' : 'Add New Site',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: textColor,
                        fontSize: size.width * 0.050,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: visibleHeight * 0.017),
                Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: nameController,
                        inputFormatters: const [SanitizingTextInputFormatter()],
                        style: TextStyle(color: textColor),
                        decoration: InputDecoration(
                          labelText: 'Site Name',
                          labelStyle: TextStyle(
                            color: textColor.withValues(alpha: 0.8),
                          ),
                          prefixIcon: Icon(
                            Icons.domain_rounded,
                            color: AppColors.accentGold,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              size.width * 0.031,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              size.width * 0.031,
                            ),
                            borderSide: BorderSide(
                              color: textColor.withValues(alpha: 0.25),
                            ),
                          ),
                          filled: true,
                          fillColor: fieldBg,
                        ),
                        validator: (value) => value!.trim().isEmpty
                            ? 'Site name is required'
                            : InputSanitizer.validateShortText(
                                value,
                                maxLength: 80,
                              ),
                      ),
                      SizedBox(height: visibleHeight * 0.018),
                      TextFormField(
                        controller: descController,
                        maxLines: 3,
                        inputFormatters: const [SanitizingTextInputFormatter()],
                        style: TextStyle(color: textColor),
                        decoration: InputDecoration(
                          labelText: 'Description (Optional)',
                          labelStyle: TextStyle(
                            color: textColor.withValues(alpha: 0.8),
                          ),
                          prefixIcon: Icon(
                            Icons.description_outlined,
                            color: AppColors.accentGold,
                          ),
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              size.width * 0.031,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              size.width * 0.031,
                            ),
                            borderSide: BorderSide(
                              color: textColor.withValues(alpha: 0.25),
                            ),
                          ),
                          filled: true,
                          fillColor: fieldBg,
                        ),
                        validator: (value) => InputSanitizer.validateLongText(
                          value,
                          required: false,
                          maxLength: 300,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: visibleHeight * 0.010),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                    SizedBox(width: size.width * 0.021),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandTeal,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.061,
                          vertical: visibleHeight * 0.012,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            size.width * 0.026,
                          ),
                        ),
                      ),
                      onPressed: () async {
                        if (!formKey.currentState!.validate()) return;
                        final navigator = Navigator.of(context);
                        final messenger = ScaffoldMessenger.of(this.context);
                        final siteName = InputSanitizer.cleanText(
                          nameController.text,
                          maxLength: 80,
                        );
                        final siteDescription = InputSanitizer.cleanText(
                          descController.text,
                          maxLength: 300,
                        );
                        try {
                          if (isEditing) {
                            await supabase
                                .from('sites')
                                .update({
                                  'name': siteName,
                                  'description': siteDescription,
                                })
                                .eq('id', site['id']);
                            await _upsertSiteLocally({
                              ...site,
                              'name': siteName,
                              'description': siteDescription,
                            });
                          } else {
                            if (_officerId == null) {
                              throw Exception(
                                "Cannot create site: Officer identifier is missing.",
                              );
                            }
                            final payload = {
                              'name': siteName,
                              'description': siteDescription,
                              'officer_uid': _officerId!,
                            };
                            final inserted = await supabase
                                .from('sites')
                                .insert(payload)
                                .select()
                                .single();
                            await _upsertSiteLocally(
                              Map<String, dynamic>.from(inserted),
                            );
                          }
                          if (mounted) {
                            navigator.pop();
                            await _fetchSites(bypassCache: true);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  isEditing
                                      ? 'Site updated successfully'
                                      : 'Site added successfully',
                                ),
                                backgroundColor: Colors.green,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } on SocketException {
                          final localId =
                              site?['id']?.toString() ?? const Uuid().v4();
                          final payload = {
                            'id': localId,
                            'name': siteName,
                            'description': siteDescription,
                            ...?(_officerId == null
                                ? null
                                : {'officer_uid': _officerId}),
                          };
                          await _syncRepository.enqueueAction(
                            id: 'officer_site_${isEditing ? 'update' : 'insert'}_${localId}_${DateTime.now().millisecondsSinceEpoch}',
                            table: 'sites',
                            action: isEditing ? 'update' : 'insert',
                            payload: payload,
                          );
                          await _upsertSiteLocally(payload);
                          if (mounted) {
                            navigator.pop();
                            await _fetchSites();
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Saved offline - site change will sync when online',
                                ),
                                backgroundColor: Colors.orange,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not save site. Please try again.',
                                ),
                                backgroundColor: Colors.red,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      },
                      child: Text(isEditing ? 'Update' : 'Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _deleteSite(Map<String, dynamic> site) async {
    final String id = site['id'];
    final String name = site['name'];
    final workersData = site['workers'] as List? ?? [];
    final workerCount = workersData.isNotEmpty ? workersData[0]['count'] : 0;
    final hseWorkersData = site['hse_workers'] as List? ?? [];
    final hseWorkerCount = hseWorkersData.isNotEmpty
        ? hseWorkersData[0]['count']
        : 0;
    final totalWorkers = workerCount + hseWorkerCount;
    final bool hasWorkers = totalWorkers > 0;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) {
        final mediaQuery = MediaQuery.of(context);
        final size = mediaQuery.size;
        final visibleHeight =
            size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
        const dialogBg = Color(0xFF123636);
        const textColor = Colors.white;

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size.width * 0.056),
          ),
          backgroundColor: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: dialogBg,
              borderRadius: BorderRadius.circular(size.width * 0.056),
              border: Border.all(
                color: AppColors.surfaceTeal.withValues(alpha: 0.8),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              size.width * 0.051,
              visibleHeight * 0.020,
              size.width * 0.051,
              visibleHeight * 0.015,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      hasWorkers
                          ? Icons.warning_amber_rounded
                          : Icons.delete_forever_rounded,
                      color: Colors.redAccent,
                    ),
                    SizedBox(width: size.width * 0.032),
                    Expanded(
                      child: Text(
                        hasWorkers ? 'Warning: Site in Use' : 'Delete Site',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: textColor,
                          fontSize: size.width * 0.050,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: visibleHeight * 0.015),
                Text(
                  hasWorkers
                      ? '"$name" is currently assigned to $totalWorkers worker(s) and may be linked to other records like resolved hazards.\n\nDeleting the site will automatically un-link it from all associated records. Are you sure you want to proceed?'
                      : 'Are you sure you want to delete "$name"? This action cannot be undone.',
                  style: TextStyle(color: textColor.withValues(alpha: 0.9)),
                ),
                SizedBox(height: visibleHeight * 0.010),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                    SizedBox(width: size.width * 0.021),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.061,
                          vertical: visibleHeight * 0.012,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            size.width * 0.026,
                          ),
                        ),
                      ),
                      child: Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (confirm == true && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await supabase.from('sites').delete().eq('id', id);
        await _removeSiteLocally(id);

        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text('"$name" deleted successfully.'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _fetchSites(bypassCache: true);
      } on SocketException {
        await _syncRepository.enqueueAction(
          id: 'officer_site_delete_${id}_${DateTime.now().millisecondsSinceEpoch}',
          table: 'sites',
          action: 'delete',
          payload: {'id': id},
        );
        await _removeSiteLocally(id);
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text('Deleted "$name" offline - will sync when online.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _fetchSites();
      } catch (e) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error deleting site: ${e.toString()}'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _upsertSiteLocally(Map<String, dynamic> site) async {
    final sites = OfficerRepository.instance.getOfficerSites() ?? [];
    final index = sites.indexWhere((item) => item['id'] == site['id']);
    final normalised = {
      'workers': const [
        {'count': 0},
      ],
      'hse_workers': const [
        {'count': 0},
      ],
      ...site,
    };
    if (index == -1) {
      sites.insert(0, normalised);
    } else {
      sites[index] = {...sites[index], ...normalised};
    }
    await OfficerRepository.instance.saveOfficerSites(sites);
  }

  Future<void> _removeSiteLocally(String id) async {
    final sites = OfficerRepository.instance.getOfficerSites() ?? [];
    sites.removeWhere((site) => site['id'] == id);
    await OfficerRepository.instance.saveOfficerSites(sites);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: RefreshIndicator(
        onRefresh: () => _fetchSites(bypassCache: true),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _sitesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: EdgeInsets.all(size.width * 0.040),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: size.width * 0.160,
                        color: Colors.red.shade400,
                      ),
                      SizedBox(height: visibleHeight * 0.018),
                      Text(
                        'Error: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: size.width * 0.039),
                      ),
                    ],
                  ),
                ),
              );
            }

            final sites = snapshot.data ?? [];

            if (sites.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(size.width * 0.070),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).primaryColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.maps_home_work_rounded,
                        size: size.width * 0.180,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                    SizedBox(height: visibleHeight * 0.025),
                    Text(
                      'No sites found',
                      style: TextStyle(
                        fontSize: size.width * 0.052,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: visibleHeight * 0.008),
                    Text(
                      'Create your first site to get started',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: size.width * 0.036,
                      ),
                    ),
                    SizedBox(height: visibleHeight * 0.030),
                    ElevatedButton.icon(
                      onPressed: () => _addOrEditSite(),
                      icon: Icon(Icons.add),
                      label: Text('Add Site'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.080,
                          vertical: visibleHeight * 0.015,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            size.width * 0.031,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                // Header Section
                Container(
                  margin: EdgeInsets.fromLTRB(
                    size.width * 0.045,
                    visibleHeight * 0.015,
                    size.width * 0.045,
                    visibleHeight * 0.008,
                  ),
                  padding: EdgeInsets.fromLTRB(
                    size.width * 0.035,
                    visibleHeight * 0.008,
                    size.width * 0.020,
                    visibleHeight * 0.008,
                  ),
                  constraints: BoxConstraints(
                    minHeight: visibleHeight * 0.065,
                    maxHeight: visibleHeight * 0.065,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Color.lerp(AppColors.brandTeal, Colors.black, 0.35)!
                        : Color.lerp(AppColors.brandTeal, Colors.white, 0.78)!,
                    borderRadius: BorderRadius.circular(size.width * 0.031),
                    border: Border.all(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppColors.surfaceTeal.withValues(alpha: 0.8)
                          : AppColors.brandTeal.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            "${sites.length} ${sites.length == 1 ? 'Site' : 'Sites'}",
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                          ),
                        ),
                      ),
                      IconButton.filled(
                        icon: Icon(Icons.add, size: size.width * 0.051),
                        onPressed: () => _addOrEditSite(),
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.accentGold,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),

                // Sites List
                Expanded(
                  child: ListView.builder(
                    // ADDED BOTTOM PADDING HERE TO CLEAR THE NAV BAR
                    padding: EdgeInsets.only(
                      left: size.width * 0.030,
                      right: size.width * 0.030,
                      top: visibleHeight * 0.012,
                      bottom: visibleHeight * 0.125,
                    ),
                    itemCount: sites.length,
                    itemBuilder: (context, index) {
                      final site = sites[index];
                      return _SiteCard(
                        site: site,
                        index: index,
                        onEdit: () => _addOrEditSite(site: site),
                        onDelete: () => _deleteSite(site),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SiteCard extends StatelessWidget {
  const _SiteCard({
    required this.site,
    required this.index,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> site;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final description = site['description'];
    final workersData = site['workers'] as List? ?? [];
    final workerCount = workersData.isNotEmpty ? workersData[0]['count'] : 0;
    final hseWorkersData = site['hse_workers'] as List? ?? [];
    final hseWorkerCount = hseWorkersData.isNotEmpty
        ? hseWorkersData[0]['count']
        : 0;
    final totalWorkers = workerCount + hseWorkerCount;

    // Color gradient based on index
    final colors = [
      [const Color(0xFF6366F1), const Color(0xFF8B5CF6)], // Indigo to Purple
      [const Color(0xFF0EA5E9), const Color(0xFF06B6D4)], // Sky to Cyan
      [const Color(0xFFF59E0B), const Color(0xFFF97316)], // Amber to Orange
      [const Color(0xFF10B981), const Color(0xFF059669)], // Emerald to Green
      [const Color(0xFFEC4899), const Color(0xFFDB2777)], // Pink to Rose
    ];
    final colorPair = colors[index % colors.length];

    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 300 + (index * 50)),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(
            size.width * 0.0,
            visibleHeight * 0.025 * (1 - value),
          ),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: visibleHeight * 0.014),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorPair[0].withValues(alpha: 0.95),
              colorPair[1].withValues(alpha: 0.95),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(size.width * 0.041),
          boxShadow: [
            BoxShadow(
              color: colorPair[0].withValues(alpha: 0.4),
              blurRadius: size.width * 0.038,
              offset: Offset(size.width * 0.0, visibleHeight * 0.010),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(size.width * 0.041),
            onTap: () {
              // Navigates to the new personnel screen
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SitePersonnelScreen(
                    siteId: site['id'],
                    siteName: site['name'] ?? 'Unnamed Site',
                  ),
                ),
              );
            },
            child: Padding(
              padding: EdgeInsets.all(size.width * 0.040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header Row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: size.width * 0.125,
                        height: size.width * 0.125,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(
                            size.width * 0.031,
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.domain_rounded,
                            size: size.width * 0.068,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      SizedBox(width: size.width * 0.032),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              site['name'] ?? 'Unnamed Site',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: size.width * 0.047,
                                color: Colors.white,
                              ),
                            ),
                            if (description != null && description.isNotEmpty)
                              Padding(
                                padding: EdgeInsets.only(
                                  top: visibleHeight * 0.005,
                                ),
                                child: Text(
                                  description,
                                  style: TextStyle(
                                    fontSize: size.width * 0.032,
                                    color: Colors.white.withValues(alpha: 0.9),
                                    height: 1.4,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: visibleHeight * 0.014),

                  // Divider
                  Divider(
                    color: Colors.white.withValues(alpha: 0.3),
                    height: visibleHeight * 0.001,
                  ),

                  SizedBox(height: visibleHeight * 0.014),

                  // Worker Stats
                  Row(
                    children: [
                      Expanded(
                        child: _StatBox(
                          icon: Icons.people_alt_rounded,
                          label: 'Workers',
                          count: workerCount.toString(),
                        ),
                      ),
                      SizedBox(width: size.width * 0.024),
                      Expanded(
                        child: _StatBox(
                          icon: Icons.health_and_safety_rounded,
                          label: 'Site Inspector',
                          count: hseWorkerCount.toString(),
                        ),
                      ),
                      SizedBox(width: size.width * 0.024),
                      Expanded(
                        child: _StatBox(
                          icon: Icons.groups_rounded,
                          label: 'Total',
                          count: totalWorkers.toString(),
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: visibleHeight * 0.014),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: onEdit,
                          icon: Icon(
                            Icons.edit_rounded,
                            size: size.width * 0.046,
                          ),
                          label: Text('Edit'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.25,
                            ),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: EdgeInsets.symmetric(
                              vertical: visibleHeight * 0.011,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                size.width * 0.031,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: size.width * 0.032),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: onDelete,
                          icon: Icon(
                            Icons.delete_forever_rounded,
                            size: size.width * 0.046,
                          ),
                          label: Text('Delete'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.25,
                            ),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: EdgeInsets.symmetric(
                              vertical: visibleHeight * 0.011,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                size.width * 0.031,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.icon,
    required this.label,
    required this.count,
  });

  final IconData icon;
  final String label;
  final String count;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: visibleHeight * 0.010,
        horizontal: size.width * 0.014,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(size.width * 0.026),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: size.width * 0.055),
          SizedBox(height: visibleHeight * 0.004),
          Text(
            count,
            style: TextStyle(
              color: Colors.white,
              fontSize: size.width * 0.039,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: size.width * 0.025,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
