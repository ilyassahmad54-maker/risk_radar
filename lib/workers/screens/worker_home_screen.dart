import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:riskradar/services/providers/notification_count_provider.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';

// --- Imports ---
import 'worker_hazard_report_screen.dart';
import 'worker_resolved_hazards_screen.dart';
import 'worker_ongoing_hazards_screen.dart';
import 'worker_app_settings_screen.dart';
import '../settings/worker_notification_screen.dart';
import '../settings/worker_view_profile_screen.dart';
import '../../shared/settings/about_app_screen.dart';
import '../../shared/screens/shared_emergency_sos_screen.dart';
import '../../shared/widgets/offline_banner.dart';
import '../../shared/widgets/realtime_connection_indicator.dart';
import '../settings/worker_hazard_notifier.dart';
import '../tabs/ai_image.dart';
import '../../shared/widgets/risk_radar_loader.dart';
import 'package:riskradar/services/repositories/auth_repository.dart';

class WorkerHomeScreen extends StatefulWidget {
  final ThemeMode currentThemeMode;
  final void Function(ThemeMode) onThemeChanged;

  const WorkerHomeScreen({
    super.key,
    required this.currentThemeMode,
    required this.onThemeChanged,
  });

  @override
  State<WorkerHomeScreen> createState() => _WorkerHomeScreenState();
}

class _WorkerHomeScreenState extends State<WorkerHomeScreen>
    with SingleTickerProviderStateMixin {
  final SupabaseClient supabase = Supabase.instance.client;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final AuthRepository _authRepository = AuthRepository();
  final HazardRepository _hazardRepository = HazardRepository();

  late AnimationController _animationController;
  late Animation<double> _curveAnimation;
  int _selectedIndex = 0;

  static const Color _brandTeal = Color(0xFF1B3D3D);
  static const Color _accentGold = Color(0xFFE6A050);

  // ── Loading state ──────────────────────────────────────────────────────────
  // loading = true only on first boot with zero cache.
  // Once cache data is painted, this stays false even during bg refresh.
  bool loading = true;

  // ── Profile display state ──────────────────────────────────────────────────
  String _firstNameInitial = "W";
  String _fullName = "Loading...";
  String _workType = "";
  String _profileImageUrl = "";

  // ── Drawer context state ───────────────────────────────────────────────────
  String _currentSiteName = "No site assigned";
  List<String> _safetyOfficersList = [];
  List<String> _contractorsList = [];
  int _activeHazardCount = 0;

  // ── SOS / location IDs ────────────────────────────────────────────────────
  String? _currentWorkerId;
  String? _currentSiteId;
  String? _linkedOfficerUid;
  DateTime _resolvedTitleDate = DateTime.now();

  final List<String> _screenTitles = [
    "Dashboard",
    "Ongoing Hazards",
    "Report Hazard",
    "Resolved Hazards",
    "Settings",
  ];

  String get _currentScreenTitle {
    if (_selectedIndex == 3) {
      return DateFormat('MMMM yyyy').format(_resolvedTitleDate);
    }
    return _screenTitles[_selectedIndex];
  }

  void _updateResolvedTitleDate(DateTime date) {
    if (_resolvedTitleDate.year == date.year &&
        _resolvedTitleDate.month == date.month) {
      return;
    }
    setState(() {
      _resolvedTitleDate = DateTime(date.year, date.month);
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _curveAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _loadAllData();
    workerHazardNotifier.startChecking();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NAV HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  void _onItemTapped(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
    if (index == 0) {
      unawaited(_loadActiveHazardCountFromCache());
    }
    _curveAnimation =
        Tween<double>(
          begin: _curveAnimation.value,
          end: index.toDouble(),
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        );
    _animationController.forward(from: 0);
  }

  String _capitalize(String? text) {
    if (text == null || text.isEmpty) return '';
    return text
        .split(' ')
        .map(
          (word) => word.isNotEmpty
              ? word[0].toUpperCase() + word.substring(1).toLowerCase()
              : '',
        )
        .join(' ');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DATA LOADING — cache first, Supabase second
  //
  // Boot sequence:
  //   1. Read cached worker profile → paint UI instantly (loading = false)
  //   2. Read cached worker context → paint drawer instantly
  //   3. Attempt Supabase refresh in background
  //      → On success: update cache + setState (UI refreshes silently)
  //      → On SocketException / any error: silently skip, cached data stays
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadAllData() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    _currentWorkerId = userId;

    // ── Step 1: Paint from cache immediately ──────────────────────────────
    final cachedProfile = _authRepository.getWorkerProfile();
    final cachedContext = _authRepository.getWorkerContext();

    if (cachedProfile != null) {
      _applyProfile(cachedProfile);
    }

    if (cachedContext != null) {
      _applyContext(cachedContext);
    }

    await _loadActiveHazardCountFromCache();

    // If we had anything from cache, stop the loading spinner immediately.
    // The user sees real data in < 1 frame.
    if (cachedProfile != null) {
      if (mounted) setState(() => loading = false);
    }

    // ── Step 2: Background Supabase refresh ───────────────────────────────
    _refreshFromSupabase(userId);
  }

  // ── Apply cached / fresh profile row to display state ─────────────────────
  void _applyProfile(Map<String, dynamic> profile) {
    final fName = profile['first_name'] ?? '';
    final lName = profile['last_name'] ?? '';
    _firstNameInitial = fName.isNotEmpty ? fName[0].toUpperCase() : 'W';
    _fullName = _capitalize('$fName $lName');
    _workType = _capitalize(profile['work_type'] ?? 'Site Worker');
    _profileImageUrl = profile['profile_image_url'] ?? '';
    _currentSiteId = profile['current_site_id']?.toString();
    _linkedOfficerUid = profile['officer_uid']?.toString();
  }

  // ── Apply cached / fresh context map to drawer display state ──────────────
  void _applyContext(Map<String, dynamic> ctx) {
    _currentSiteName = (ctx['site_name'] as String?)?.isNotEmpty == true
        ? ctx['site_name'] as String
        : 'No site assigned';
    final cachedSiteId = ctx['site_id']?.toString();
    final cachedOfficerUid = ctx['officer_uid']?.toString();

    if (cachedSiteId != null && cachedSiteId.isNotEmpty) {
      _currentSiteId = cachedSiteId;
    }
    if (cachedOfficerUid != null && cachedOfficerUid.isNotEmpty) {
      _linkedOfficerUid = cachedOfficerUid;
    }
    _contractorsList =
        (ctx['contractors'] as List<dynamic>?)?.cast<String>() ?? [];
    _safetyOfficersList =
        (ctx['safety_officers'] as List<dynamic>?)?.cast<String>() ?? [];
  }

  bool _isActiveHazardRow(Map<String, dynamic> row) {
    final status = row['status']?.toString().trim().toLowerCase() ?? '';
    return status != 'resolved' && status != 'resolved by other';
  }

  Future<void> _loadActiveHazardCountFromCache() async {
    final cachedRows = await _hazardRepository.getOngoingHazards();
    final count = cachedRows.where(_isActiveHazardRow).length;
    if (!mounted) return;
    setState(() => _activeHazardCount = count);
  }

  Future<void> _refreshActiveHazardCountFromSupabase() async {
    final officerUid = _linkedOfficerUid;
    final siteId = _currentSiteId;
    if (officerUid == null ||
        officerUid.isEmpty ||
        siteId == null ||
        siteId.isEmpty) {
      await _loadActiveHazardCountFromCache();
      return;
    }

    final results = await Future.wait([
      supabase
          .from('hazards')
          .select('*, workers!hazards_worker_id_fkey (*)')
          .eq('officer_uid', officerUid)
          .eq('current_site_id', siteId)
          .eq('status', 'reported')
          .order('created_at', ascending: false),
      supabase
          .from('worker_active_hazards_view')
          .select()
          .eq('officer_uid', officerUid)
          .eq('current_site_id', siteId)
          .inFilter('status', [
            'assigned',
            'Assigned',
            'in_progress',
            'In Progress',
          ])
          .order('created_at', ascending: false),
    ]);

    final rows = <Map<String, dynamic>>[
      ...(results[0] as List<dynamic>).cast<Map<String, dynamic>>(),
      ...(results[1] as List<dynamic>).cast<Map<String, dynamic>>(),
    ];

    await _hazardRepository.replaceOngoingHazards(rows);
    if (!mounted) return;
    setState(() => _activeHazardCount = rows.where(_isActiveHazardRow).length);
  }

  // ── Silent Supabase refresh — never blocks the UI ─────────────────────────
  Future<void> _refreshFromSupabase(String userId) async {
    try {
      // Fetch worker profile
      final profile = await supabase
          .from('workers')
          .select()
          .eq('id', userId)
          .maybeSingle();

      if (profile == null) {
        // No profile row yet — just stop loading spinner if still showing
        if (mounted) setState(() => loading = false);
        return;
      }

      // Persist fresh profile to cache
      await _authRepository.saveWorkerProfile(
        Map<String, dynamic>.from(profile),
      );

      // Update in-memory state
      _applyProfile(profile);

      // Fetch worker site context through the secure server-side RPC.
      // The RPC derives the worker from auth.uid(), avoiding cross-table
      // RLS recursion between workers, sites, and hse_workers.
      final contextResponse = await supabase.rpc('get_my_worker_site_context');

      String fetchedSiteName = 'No site assigned';
      List<String> fetchedContractors = [];
      List<String> fetchedSafetyOfficers = [];

      String? siteId = profile['current_site_id']?.toString();
      String? officerUid = profile['officer_uid']?.toString();

      final contextRows = contextResponse is List
          ? contextResponse
          : <dynamic>[];

      if (contextRows.isNotEmpty) {
        final context = Map<String, dynamic>.from(contextRows.first as Map);

        siteId = context['site_id']?.toString() ?? siteId;
        officerUid = context['officer_uid']?.toString() ?? officerUid;

        final siteName = context['site_name']?.toString();
        if (siteName != null && siteName.trim().isNotEmpty) {
          fetchedSiteName = _capitalize(siteName);
        }

        final contractorName = context['contractor_name']?.toString();
        if (contractorName != null && contractorName.trim().isNotEmpty) {
          fetchedContractors = [_capitalize(contractorName)];
        }

        final safetyOfficers = context['safety_officers'];
        if (safetyOfficers is List) {
          fetchedSafetyOfficers = safetyOfficers
              .where(
                (name) => name != null && name.toString().trim().isNotEmpty,
              )
              .map((name) => _capitalize(name.toString()))
              .toList();
        }
      }

      debugPrint(
        '🔎 [WorkerHome] RPC context loaded: '
        'site=${fetchedSiteName == 'No site assigned' ? 'none' : 'assigned'}, '
        'contractors=${fetchedContractors.length}, '
        'HSE=${fetchedSafetyOfficers.length}',
      );

      // Persist fresh context to cache
      await _authRepository.saveWorkerContext(
        siteId: siteId,
        siteName: fetchedSiteName,
        officerUid: officerUid,
        contractors: fetchedContractors,
        safetyOfficers: fetchedSafetyOfficers,
      );

      // Update drawer display state
      if (mounted) {
        setState(() {
          _currentSiteName = fetchedSiteName;
          _contractorsList = fetchedContractors;
          _safetyOfficersList = fetchedSafetyOfficers;
          loading = false; // Covers the case where there was no cache at all
        });
      }
    } on SocketException {
      // Offline — cached data already painted, nothing to do
      debugPrint('ℹ️ [WorkerHome] Offline — showing cached data.');
      if (mounted) setState(() => loading = false);
    } catch (e) {
      // Any other error — log, don't crash, cached data stays visible
      debugPrint('⚠️ [WorkerHome] Supabase refresh failed: $e');
      if (mounted) setState(() => loading = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LOCATION TRACKING — fire and forget, offline-safe
  // ══════════════════════════════════════════════════════════════════════════

  // ══════════════════════════════════════════════════════════════════════════
  // SOS NAVIGATION
  // ══════════════════════════════════════════════════════════════════════════

  void _navigateToSOS() {
    if (_currentSiteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("No site assigned."),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SharedEmergencySOSScreen(
          linkedContractorId: _linkedOfficerUid,
          currentSiteId: _currentSiteId,
          isWorker: true,
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DRAWER
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildWorkerDrawer() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Drawer(
      backgroundColor: _brandTeal,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.fromLTRB(
                    size.width * 0.060,
                    visibleHeight * 0.075,
                    size.width * 0.060,
                    visibleHeight * 0.025,
                  ),
                  color: const Color(0xFF142E2E),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: size.width * 0.097,
                        backgroundColor: Colors.purple.shade200,
                        backgroundImage: _profileImageUrl.isNotEmpty
                            ? CachedNetworkImageProvider(_profileImageUrl)
                            : null,
                        child: _profileImageUrl.isEmpty
                            ? Text(
                                _firstNameInitial,
                                style: TextStyle(
                                  fontSize: size.width * 0.070,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                ),
                              )
                            : null,
                      ),
                      SizedBox(height: visibleHeight * 0.015),
                      Text(
                        _fullName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: size.width * 0.045,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: visibleHeight * 0.003),
                      Text(
                        _workType,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: size.width * 0.033,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    size.width * 0.060,
                    visibleHeight * 0.025,
                    size.width * 0.060,
                    visibleHeight * 0.025,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "CURRENT SITE CONTEXT",
                        style: TextStyle(
                          color: _accentGold,
                          fontSize: size.width * 0.025,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      SizedBox(height: visibleHeight * 0.025),
                      _buildContextGroup(
                        icon: Icons.business_center,
                        label: "Contractor",
                        names: _contractorsList,
                        emptyMsg: "No contractor linked",
                      ),
                      SizedBox(height: visibleHeight * 0.020),
                      _drawerInfoTile(
                        Icons.location_city,
                        "Site Name",
                        _currentSiteName,
                      ),
                      SizedBox(height: visibleHeight * 0.020),
                      _buildContextGroup(
                        icon: Icons.security,
                        label: "Safety Inspector",
                        names: _safetyOfficersList,
                        emptyMsg: "No inspector on site",
                      ),
                    ],
                  ),
                ),
                Divider(color: Colors.white10),
                _drawerTile(
                  Icons.account_circle_outlined,
                  "Profile Details",
                  () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const WorkerEditProfileScreen(),
                      ),
                    );
                  },
                ),
                _drawerTile(Icons.settings_outlined, "Settings", () {
                  Navigator.pop(context);
                  _onItemTapped(4);
                }),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.all(size.width * 0.060),
            child: Text(
              "RiskRadar v1.1.0",
              style: TextStyle(
                color: Colors.white24,
                fontSize: size.width * 0.028,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextGroup({
    required IconData icon,
    required String label,
    required List<String> names,
    required String emptyMsg,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: size.width * 0.051, color: _accentGold),
        SizedBox(width: size.width * 0.040),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: size.width * 0.023,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              SizedBox(height: visibleHeight * 0.003),
              if (names.isEmpty)
                Text(
                  emptyMsg,
                  style: TextStyle(
                    fontSize: size.width * 0.035,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                )
              else
                ...names.map(
                  (name) => Padding(
                    padding: EdgeInsets.only(bottom: visibleHeight * 0.003),
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: size.width * 0.035,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _drawerTile(IconData icon, String title, VoidCallback onTap) {
    final size = MediaQuery.of(context).size;
    return ListTile(
      leading: Icon(icon, color: Colors.white70, size: size.width * 0.056),
      title: Text(
        title,
        style: TextStyle(
          fontSize: size.width * 0.035,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
      onTap: onTap,
    );
  }

  Widget _drawerInfoTile(IconData icon, String label, String value) {
    final size = MediaQuery.of(context).size;
    return Row(
      children: [
        Icon(icon, size: size.width * 0.051, color: _accentGold),
        SizedBox(width: size.width * 0.040),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: size.width * 0.023,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: size.width * 0.035,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DASHBOARD BODY
  // ══════════════════════════════════════════════════════════════════════════

  Widget _dashboardBody() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return RefreshIndicator(
      onRefresh: () async {
        final userId = supabase.auth.currentUser?.id;
        if (userId != null) {
          await _refreshFromSupabase(userId);
        }
        await _refreshActiveHazardCountFromSupabase();
      },
      color: _brandTeal,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(size.width * 0.060),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Stay safe and",
              style: TextStyle(
                fontSize: size.width * 0.055,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
            Text(
              "remain Vigilant",
              style: TextStyle(
                fontSize: size.width * 0.065,
                fontWeight: FontWeight.bold,
                color: _accentGold,
              ),
            ),
            SizedBox(height: visibleHeight * 0.031),
            Row(
              children: [
                Expanded(
                  child: _buildDashboardCard(
                    size: size,
                    visibleHeight: visibleHeight,
                    title: "AI Scanner",
                    subtitle: "Detect hazards instantly",
                    icon: Icons.auto_awesome,
                    buttonText: "Scan Now",
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const HazardScreen()),
                    ),
                  ),
                ),
                SizedBox(width: size.width * 0.043),
                Expanded(
                  child: _buildDashboardCard(
                    size: size,
                    visibleHeight: visibleHeight,
                    title: "Hazards",
                    subtitle: "$_activeHazardCount active risks",
                    icon: Icons.warning_rounded,
                    buttonText: "View",
                    onTap: () => _onItemTapped(1),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardCard({
    required Size size,
    required double visibleHeight,
    required String title,
    required String subtitle,
    required IconData icon,
    required String buttonText,
    required VoidCallback onTap,
  }) {
    return Container(
      height: visibleHeight * 0.225,
      padding: EdgeInsets.all(size.width * 0.050),
      decoration: BoxDecoration(
        color: _brandTeal,
        borderRadius: BorderRadius.circular(size.width * 0.071),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: Colors.white70, size: size.width * 0.071),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size.width * 0.045,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: visibleHeight * 0.005),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: size.width * 0.028,
                ),
              ),
            ],
          ),
          SizedBox(
            width: double.infinity,
            height: visibleHeight * 0.045,
            child: ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accentGold,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(size.width * 0.031),
                ),
                padding: EdgeInsets.zero,
                elevation: 0,
              ),
              child: Text(
                buttonText,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size.width * 0.030,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    if (loading) {
      return Scaffold(body: RiskRadarLoader(size: size.width * 0.128));
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF121212)
        : Colors.grey.shade50;

    final screens = [
      _dashboardBody(),
      const WorkerOngoingHazardsScreen(),
      Container(),
      WorkerResolvedHazardsScreen(
        onSelectedDateChanged: _updateResolvedTitleDate,
      ),
      WorkerAppSettingsScreen(
        onAboutTap: (ctx) => Navigator.push(
          ctx,
          MaterialPageRoute(builder: (_) => const AboutAppScreen()),
        ),
        onProfileTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WorkerEditProfileScreen()),
        ),
        onThemeChanged: widget.onThemeChanged,
        currentThemeMode: widget.currentThemeMode,
      ),
    ];

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildWorkerDrawer(),
      backgroundColor: backgroundColor,
      extendBody: true,
      appBar: AppBar(
        backgroundColor: _brandTeal,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          _currentScreenTitle,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        leading: _selectedIndex == 0
            ? GestureDetector(
                onTap: () => _scaffoldKey.currentState?.openDrawer(),
                child: Container(
                  margin: EdgeInsets.all(size.width * 0.025),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade200,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _firstNameInitial,
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: size.width * 0.040,
                    ),
                  ),
                ),
              )
            : IconButton(
                icon: Icon(Icons.menu, color: Colors.white),
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
        actions: [
          const RealtimeConnectionIndicator(),
          Consumer(
            builder: (context, ref, _) {
              final count = ref
                  .watch(notificationCountProvider)
                  .when(
                    data: (value) => value,
                    error: (error, stackTrace) => 0,
                    loading: () => 0,
                  );
              return Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.notifications_none_rounded,
                      color: Colors.white,
                      size: size.width * 0.071,
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const WorkerNotificationScreen(),
                      ),
                    ),
                  ),
                  if (count > 0)
                    Positioned(
                      right: size.width * 0.020,
                      top: visibleHeight * 0.010,
                      child: Container(
                        padding: EdgeInsets.all(size.width * 0.005),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _brandTeal,
                            width: size.width * 0.004,
                          ),
                        ),
                        constraints: BoxConstraints(
                          minWidth: size.width * 0.046,
                          minHeight: visibleHeight * 0.023,
                        ),
                        child: Center(
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: size.width * 0.025,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          SizedBox(width: size.width * 0.021),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(child: screens[_selectedIndex]),
        ],
      ),
      floatingActionButton: _selectedIndex == 0
          ? Padding(
              padding: EdgeInsets.only(bottom: visibleHeight * 0.113),
              child: FloatingActionButton.extended(
                backgroundColor: Colors.red.shade600,
                onPressed: _navigateToSOS,
                elevation: size.width * 0.010,
                icon: Icon(
                  Icons.sos_rounded,
                  color: Colors.white,
                  size: size.width * 0.056,
                ),
                label: Text(
                  "EMERGENCY",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontSize: size.width * 0.034,
                  ),
                ),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: _buildConcaveNavBar(),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BOTTOM NAV BAR
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildConcaveNavBar() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final navHeight = visibleHeight * 0.106;
    return SizedBox(
      height: navHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: size.width * 0.0,
            right: size.width * 0.0,
            bottom: visibleHeight * 0.0,
            child: AnimatedBuilder(
              animation: _curveAnimation,
              builder: (context, child) {
                return CustomPaint(
                  size: Size(size.width, navHeight),
                  painter: ConcaveNavPainter(
                    selectedIndex: _curveAnimation.value,
                    itemsCount: 5,
                    color: _brandTeal,
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _buildNavItem(0, Icons.grid_view_rounded, "Home"),
                _buildNavItem(1, Icons.warning_rounded, "Hazards"),
                _buildNavItem(2, Icons.add_circle, "Report"),
                _buildNavItem(3, Icons.check_circle_rounded, "Resolved"),
                _buildNavItem(4, Icons.settings_rounded, "Settings"),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final navHeight = visibleHeight * 0.106;
    final bool isSelected = _selectedIndex == index;
    final bool isReportButton = index == 2;

    return GestureDetector(
      onTap: () {
        if (index == 2) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WorkerReportHazardScreen()),
          );
        } else {
          _onItemTapped(index);
        }
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: size.width * 0.160,
        height: navHeight,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              top: isSelected ? visibleHeight * 0.0 : visibleHeight * 0.025,
              child: Container(
                width: size.width * 0.133,
                height: visibleHeight * 0.063,
                decoration: BoxDecoration(
                  color: isSelected ? _accentGold : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: isSelected
                      ? Colors.white
                      : (isReportButton
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.5)),
                  size: size.width * 0.067,
                ),
              ),
            ),
            Positioned(
              bottom: visibleHeight * 0.005,
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? _accentGold
                      : (isReportButton
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.7)),
                  fontSize: size.width * 0.025,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CONCAVE NAV PAINTER — unchanged
// ══════════════════════════════════════════════════════════════════════════════

class ConcaveNavPainter extends CustomPainter {
  final double selectedIndex;
  final int itemsCount;
  final Color color;

  ConcaveNavPainter({
    required this.selectedIndex,
    required this.itemsCount,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    Path path = Path();
    double barHeight = size.height * 0.765;
    double topOffset = size.height - barHeight;
    double sectionWidth = size.width / itemsCount;
    double currentCenter =
        (selectedIndex * sectionWidth) + (sectionWidth * 0.5);
    double notchRadius = size.width * 0.097;
    double notchPadding = size.width * 0.013;
    double notchDepth = size.height * 0.471;
    path.moveTo(size.width * 0.0, topOffset);
    path.lineTo(currentCenter - notchRadius - notchPadding, topOffset);
    path.cubicTo(
      currentCenter - notchRadius,
      topOffset,
      currentCenter - notchRadius + notchPadding,
      topOffset + notchDepth,
      currentCenter,
      topOffset + notchDepth,
    );
    path.cubicTo(
      currentCenter + notchRadius - notchPadding,
      topOffset + notchDepth,
      currentCenter + notchRadius,
      topOffset,
      currentCenter + notchRadius + notchPadding,
      topOffset,
    );
    path.lineTo(size.width, topOffset);
    path.lineTo(size.width, size.height);
    path.lineTo(size.width * 0.0, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant ConcaveNavPainter oldDelegate) =>
      oldDelegate.selectedIndex != selectedIndex;
}
