// lib/hse_workers/screens/hse_worker_dashboard.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'hse_worker_notification_screen.dart';
import 'hse_worker_hazard_notifier.dart';
import 'hse_team_members_screen.dart';
import 'HSEWorkerResolvedHazardsScreen.dart';
import 'AssignedTasksScreen.dart';
import 'hse_worker_app_settings_screen.dart';
import 'hse_worker_view_profile_screen.dart';
import '../../shared/settings/about_app_screen.dart';
import '../../shared/screens/shared_emergency_sos_screen.dart';
import '../../shared/widgets/risk_radar_loader.dart';
import '../../shared/widgets/offline_banner.dart';
import '../../shared/widgets/realtime_connection_indicator.dart';
import 'package:riskradar/services/providers/hse_task_provider.dart';
import 'package:riskradar/services/providers/notification_count_provider.dart';
import 'package:riskradar/services/repositories/auth_repository.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';

class HSEWorkerHomeScreen extends StatefulWidget {
  final ThemeMode currentThemeMode;
  final void Function(ThemeMode) onThemeChanged;

  const HSEWorkerHomeScreen({
    super.key,
    required this.currentThemeMode,
    required this.onThemeChanged,
  });

  @override
  State<HSEWorkerHomeScreen> createState() => _HSEWorkerHomeScreenState();
}

class _HSEWorkerHomeScreenState extends State<HSEWorkerHomeScreen>
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

  bool loading = true;
  bool _hasError = false;
  bool _isRefreshing = false;
  DateTime _resolvedTitleDate = DateTime.now();

  String fullName = "";
  String firstNameInitial = "";
  String profileImageUrl = "";
  String designation = "";
  String linkedContractorName = "No contractor linked";
  String? linkedOfficerAuthId;
  String currentSiteName = "No site assigned";
  String? currentSiteId;
  int sitePersonnelCount = 0;

  int activeTasks = 0;
  int queueTasks = 0;
  int totalTasks = 0;
  double completionPercentage = 0.0;
  int teamCount = 0;

  StreamSubscription<Position>? _positionSubscription;
  List<Widget> _screens = [];
  bool _screensInitialized = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _curveAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _bootSequence();
    _startLocationTracking();
    workerHazardNotifier.startChecking();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _animationController.dispose();
    workerHazardNotifier.stopChecking();
    super.dispose();
  }

  Future<void> _bootSequence() async {
    // 1. Read from cache instantly
    await _loadFromCache();
    // 2. Fetch fresh data silently
    await _refreshFromSupabase();
  }

  void _onItemTapped(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
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

  String _capitalize(String text) {
    if (text.isEmpty) return "";
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return "";
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  // ---------------------------------------------------------------------------
  // ✅ 1. CACHE READ (Instant UI Paint)
  // ---------------------------------------------------------------------------
  Future<void> _loadFromCache() async {
    try {
      final profile = _authRepository.getHseProfile();
      final tasks = await _hazardRepository.getHseAssignedTasks();
      final contextData = _authRepository.getHseContext();

      if (profile != null) {
        fullName = _capitalize(
          "${profile['first_name'] ?? ''} ${profile['last_name'] ?? ''}",
        );
        firstNameInitial =
            (profile['first_name']?.toString().isNotEmpty ?? false)
            ? profile['first_name'][0].toUpperCase()
            : "H";
        profileImageUrl = profile['profile_image_url'] ?? "";
        designation = _capitalize(profile['designation'] ?? "");
        currentSiteId = profile['current_site_id']?.toString();

        if (tasks != null) {
          workerHazardNotifier.removeInactiveTaskNotifications(
            tasks
                .map((task) => task['id']?.toString() ?? '')
                .where((id) => id.isNotEmpty)
                .toSet(),
          );
          activeTasks = 0;
          queueTasks = 0;
          for (final task in tasks) {
            final status = (task['status'] ?? 'assigned')
                .toString()
                .toLowerCase();
            if (status != 'resolved' && status != 'resolved by other') {
              if (status == 'in_progress') {
                activeTasks++;
              } else {
                queueTasks++;
              }
            }
          }
          totalTasks = activeTasks + queueTasks;
          completionPercentage = totalTasks == 0
              ? 0.0
              : activeTasks / totalTasks;
        }

        if (contextData != null) {
          currentSiteName = _capitalize(
            contextData['site_name'] ?? "No site assigned",
          );
          sitePersonnelCount = contextData['site_personnel_count'] ?? 0;
          linkedContractorName = _capitalize(
            contextData['officer_name'] ?? "No contractor linked",
          );
          linkedOfficerAuthId = contextData['officer_auth_id'];
          teamCount = contextData['team_count'] ?? 0;
        }

        if (mounted) {
          setState(() {
            _initScreens();
            _screensInitialized = true;
            loading = false;
            _hasError = false;
          });
        }
      }
    } catch (e) {
      debugPrint('⚠️ Cache read error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // ✅ 2. SILENT BACKGROUND REFRESH
  // ---------------------------------------------------------------------------
  Future<void> _refreshFromSupabase() async {
    if (mounted) setState(() => _isRefreshing = true);

    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return;

      final Future<Map<String, dynamic>?> profileFuture = supabase
          .from('hse_workers')
          .select(
            'first_name, last_name, profile_image_url, designation, officer_uid, current_site_id',
          )
          .eq('id', userId)
          .maybeSingle();

      final Future<List<dynamic>> taskFuture = supabase
          .from('assign_hazards')
          .select('''
            *,
            workers:worker_id (
              first_name,
              last_name,
              work_type,
              profile_image_url
            )
          ''')
          .eq('assigned_to', userId);

      final results = await Future.wait([
        profileFuture,
        taskFuture,
      ]).timeout(const Duration(seconds: 15));

      final profile = results[0] as Map<String, dynamic>?;
      final taskResponse = results[1] as List<dynamic>;

      if (profile != null) {
        await _authRepository.saveHseProfile(profile);
        await _hazardRepository.saveHseAssignedTasks(taskResponse);

        final siteId = profile['current_site_id']?.toString();
        final officerUid = profile['officer_uid'];

        if (siteId != null || officerUid != null) {
          final Future<Map<String, dynamic>?> siteFuture = siteId != null
              ? supabase
                    .from('sites')
                    .select('name')
                    .eq('id', siteId)
                    .maybeSingle()
              : Future.value(null);

          final Future<dynamic> workerCountFuture = siteId != null
              ? supabase
                    .from('workers')
                    .count(CountOption.exact)
                    .eq('current_site_id', siteId)
              : Future.value(0);

          final Future<dynamic> hseCountFuture = siteId != null
              ? supabase
                    .from('hse_workers')
                    .count(CountOption.exact)
                    .eq('current_site_id', siteId)
              : Future.value(0);

          final Future<Map<String, dynamic>?> officerFuture = officerUid != null
              ? supabase
                    .from('officers')
                    .select('id, first_name, last_name')
                    .eq('id', officerUid)
                    .maybeSingle()
              : Future.value(null);

          final secondBatch = await Future.wait([
            siteFuture,
            workerCountFuture,
            hseCountFuture,
            officerFuture,
          ]).timeout(const Duration(seconds: 15));

          final site = secondBatch[0] as Map<String, dynamic>?;
          final workerCount = (secondBatch[1] as int?) ?? 0;
          final hseCount = (secondBatch[2] as int?) ?? 0;
          final personnelCount = workerCount + hseCount;
          final officer = secondBatch[3] as Map<String, dynamic>?;

          int resolvedTeamCount = 0;
          if (officer != null) {
            final Future<dynamic> teamFuture = siteId != null
                ? supabase
                      .from('workers')
                      .count(CountOption.exact)
                      .eq('officer_uid', officerUid)
                      .eq('current_site_id', siteId)
                : Future.value(0);

            resolvedTeamCount = (await teamFuture) as int? ?? 0;
          }

          await _authRepository.saveHseContext({
            'site_id': siteId,
            'site_name': site?['name'],
            'site_personnel_count': personnelCount,
            'officer_uid': officerUid,
            'officer_name': officer != null
                ? "${officer['first_name']} ${officer['last_name']}"
                : null,
            'officer_auth_id': officer?['id'],
            'team_count': resolvedTeamCount,
          });
        }
      }

      // Re-read from cache strictly to update UI
      await _loadFromCache();
    } catch (e) {
      debugPrint('⚠️ Silent refresh error (Offline mode active): $e');
      if (!_screensInitialized) {
        if (mounted) setState(() => _hasError = true);
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  void _initScreens() {
    _screens = [
      _dashboardBody(),
      const AssignedTasksScreen(),
      HSEWorkerResolvedHazardsScreen(
        onSelectedDateChanged: _updateResolvedTitleDate,
      ),
      HSEWorkerAppSettingsScreen(
        onAboutTap: (ctx) => Navigator.push(
          ctx,
          MaterialPageRoute(builder: (_) => const AboutAppScreen()),
        ),
        onThemeChanged: widget.onThemeChanged,
        currentThemeMode: widget.currentThemeMode,
      ),
    ];
  }

  void _updateResolvedTitleDate(DateTime date) {
    final selectedMonth = DateTime(date.year, date.month);
    if (mounted) {
      setState(() => _resolvedTitleDate = selectedMonth);
    }
  }

  // ---------------------------------------------------------------------------
  // LOCATION TRACKING
  // ---------------------------------------------------------------------------
  Future<void> _startLocationTracking() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 20,
            ),
          ).listen((pos) async {
            final user = supabase.auth.currentUser;
            if (user == null) return;
            try {
              await supabase.from('user_locations').upsert({
                'user_id': user.id,
                'latitude': pos.latitude,
                'longitude': pos.longitude,
                'updated_at': DateTime.now().toIso8601String(),
              }, onConflict: 'user_id');
            } catch (e) {
              debugPrint('⚠️ Location upsert error: $e'); // Graceful fail
            }
          });
    } catch (e) {
      debugPrint('⚠️ Location tracking setup error: $e');
    }
  }

  void _navigateToSOS() {
    if (currentSiteId == null) {
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
          linkedContractorId: linkedOfficerAuthId,
          currentSiteId: currentSiteId,
          isWorker: false,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DRAWER
  // ---------------------------------------------------------------------------
  Widget _buildSpotifyDrawer() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;

    return Drawer(
      backgroundColor: _brandTeal,
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF142E2E)),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Colors.purple.shade200,
              backgroundImage: profileImageUrl.isNotEmpty
                  ? NetworkImage(profileImageUrl)
                  : null,
              child: profileImageUrl.isEmpty
                  ? Text(
                      firstNameInitial,
                      style: TextStyle(
                        fontSize: R.blockH * 6,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    )
                  : null,
            ),
            accountName: Text(
              fullName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: R.blockH * 4.5,
                color: Colors.white,
              ),
            ),
            accountEmail: Text(
              designation,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: R.blockH * 3.5,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: size.width * 0.041,
              vertical: visibleHeight * 0.010,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "CURRENT SITE CONTEXT",
                  style: TextStyle(
                    color: _accentGold.withValues(alpha: 0.8),
                    fontSize: R.blockH * 2.75,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(height: R.blockV * 1.875),
                _drawerInfoTile(
                  Icons.location_city,
                  "Site Name",
                  currentSiteName,
                ),
                _drawerInfoTile(
                  Icons.groups_outlined,
                  "Total Personnel",
                  "$sitePersonnelCount Active",
                ),
                _drawerInfoTile(
                  Icons.person_pin_rounded,
                  "Contractor",
                  linkedContractorName,
                ),
              ],
            ),
          ),
          Divider(color: Colors.white10),
          _drawerTile(Icons.account_circle_outlined, "Profile Details", () {
            Navigator.pop(context);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const HSEWorkerEditProfileScreen(),
              ),
            );
          }),
          _drawerTile(Icons.settings_outlined, "Settings", () {
            Navigator.pop(context);
            _onItemTapped(3);
          }),
          Spacer(),
          Padding(
            padding: EdgeInsets.all(R.blockH * 4),
            child: Text(
              "RiskRadar v1.0.2",
              style: TextStyle(
                color: Colors.white24,
                fontSize: R.blockH * 2.75,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawerTile(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(
        title,
        style: TextStyle(
          fontSize: R.blockH * 3.75,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
      onTap: onTap,
    );
  }

  Widget _drawerInfoTile(IconData icon, String label, String value) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: visibleHeight * 0.019),
      child: Row(
        children: [
          Icon(icon, size: size.width * 0.051, color: _accentGold),
          SizedBox(width: R.blockH * 4),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: R.blockH * 2.5,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: R.blockH * 3.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // DASHBOARD BODY
  // ---------------------------------------------------------------------------
  Widget _dashboardBody() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: size.width * 0.164,
              color: Colors.grey.shade400,
            ),
            SizedBox(height: R.blockV * 2),
            Text(
              'Failed to load dashboard',
              style: TextStyle(
                fontSize: R.blockH * 4,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade600,
              ),
            ),
            SizedBox(height: R.blockV * 1),
            Text(
              'Check your connection and try again',
              style: TextStyle(
                fontSize: R.blockH * 3.25,
                color: Colors.grey.shade500,
              ),
            ),
            SizedBox(height: R.blockV * 3),
            ElevatedButton.icon(
              onPressed: _bootSequence,
              icon: Icon(Icons.refresh_rounded),
              label: Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _brandTeal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(size.width * 0.031),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Consumer(
      builder: (context, ref, child) {
        final activeTaskCount = ref
            .watch(hseTaskProvider)
            .when(
              data: (hazards) => hazards.length,
              error: (error, stackTrace) => activeTasks,
              loading: () => activeTasks,
            );

        return RefreshIndicator(
          onRefresh: () async {
            await Future.wait([
              _refreshFromSupabase(),
              ref.read(hseTaskProvider.notifier).refresh(bypassCache: true),
            ]);
          },
          color: _accentGold,
          backgroundColor: _brandTeal,
          child: Stack(
            children: [
              SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(R.blockH * 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Let's become",
                      style: TextStyle(
                        fontSize: R.blockH * 5.5,
                        color: isDark
                            ? Colors.grey.shade400
                            : Colors.grey.shade600,
                      ),
                    ),
                    Text(
                      "more Productive",
                      style: TextStyle(
                        fontSize: R.blockH * 6.5,
                        fontWeight: FontWeight.bold,
                        color: _accentGold,
                      ),
                    ),
                    SizedBox(height: R.blockV * 3.125),

                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _buildThemedCard(
                              icon: Icons.assignment_turned_in,
                              title: "$activeTaskCount Active",
                              subtitle: "Tasks in progress",
                              buttonText: "View All",
                              onTap: () => _onItemTapped(1),
                              showProgress: true,
                            ),
                          ),
                          SizedBox(width: R.blockH * 4.267),
                          Expanded(
                            child: _buildThemedCard(
                              icon: Icons.engineering,
                              title: "$teamCount",
                              subtitle: "Total Workforce",
                              buttonText: "View Workforce",
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => HSETeamMembersScreen(
                                    currentSiteId: currentSiteId,
                                  ),
                                ),
                              ),
                              showProgress: false,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Bottom padding for FAB + nav bar
                    SizedBox(height: R.blockV * 20),
                  ],
                ),
              ),
              if (_isRefreshing)
                Positioned(
                  top: visibleHeight * 0.013,
                  right: size.width * 0.051,
                  child: SizedBox(
                    width: R.blockH * 4.267,
                    height: R.blockV * 2,
                    child: CircularProgressIndicator(
                      strokeWidth: size.width * 0.005,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _brandTeal.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildThemedCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String buttonText,
    required VoidCallback onTap,
    bool showProgress = false,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;

    return Container(
      constraints: BoxConstraints(
        minHeight: math.max(visibleHeight * 0.225, 174),
      ),
      padding: EdgeInsets.all(size.width * 0.050),
      decoration: BoxDecoration(
        color: _brandTeal,
        borderRadius: BorderRadius.circular(size.width * 0.071),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: Colors.white70, size: size.width * 0.071),
              if (showProgress)
                SizedBox(
                  width: size.width * 0.107,
                  height: visibleHeight * 0.050,
                  child: CircularProgressIndicator(
                    value: completionPercentage,
                    strokeWidth: size.width * 0.010,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation(_accentGold),
                  ),
                )
              else
                Icon(
                  Icons.arrow_forward,
                  color: Colors.white24,
                  size: size.width * 0.051,
                ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: R.blockH * 5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(color: Colors.white54, fontSize: R.blockH * 3),
              ),
            ],
          ),
          ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accentGold,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(size.width * 0.031),
              ),
              padding: EdgeInsets.symmetric(horizontal: size.width * 0.040),
              minimumSize: Size(double.infinity, visibleHeight * 0.045),
              elevation: size.width * 0.0,
            ),
            child: Text(
              buttonText,
              style: TextStyle(
                color: Colors.white,
                fontSize: R.blockH * 3,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    R.init(context);
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;

    if (loading) {
      return const RiskRadarLoadingScreen(message: 'Loading your dashboard...');
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF121212)
        : Colors.grey.shade50;

    final String title = [
      "Dashboard",
      "My Tasks",
      DateFormat('MMMM yyyy').format(_resolvedTitleDate),
      "Settings",
    ][_selectedIndex];

    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_selectedIndex != 0) _onItemTapped(0);
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildSpotifyDrawer(),
        backgroundColor: backgroundColor,
        extendBody: true,
        resizeToAvoidBottomInset: false,

        appBar: AppBar(
          backgroundColor: _brandTeal,
          centerTitle: true,
          elevation: size.width * 0.0,
          scrolledUnderElevation: size.width * 0.0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          iconTheme: const IconThemeData(color: Colors.white),
          leading: (_selectedIndex == 0)
              ? GestureDetector(
                  onTap: () => _scaffoldKey.currentState?.openDrawer(),
                  child: Padding(
                    padding: EdgeInsets.all(size.width * 0.025),
                    child: CircleAvatar(
                      backgroundColor: Colors.purple.shade200,
                      backgroundImage: profileImageUrl.isNotEmpty
                          ? NetworkImage(profileImageUrl)
                          : null,
                      child: profileImageUrl.isEmpty
                          ? Text(
                              firstNameInitial,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                                fontSize: size.width * 0.040,
                              ),
                            )
                          : null,
                    ),
                  ),
                )
              : null,
          title: Text(
            title,
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          actions: [
            const RealtimeConnectionIndicator(),
            Consumer(
              builder: (context, ref, child) {
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
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) =>
                              const HSEWorkerNotificationScreen(),
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
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: R.blockH * 2.5,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
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
            Expanded(
              child: _screensInitialized
                  ? IndexedStack(index: _selectedIndex, children: _screens)
                  : const RiskRadarLoadingScreen(
                      message: 'Preparing screens...',
                    ),
            ),
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
      ),
    );
  }

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
                    itemsCount: 4,
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
                _buildNavItem(1, Icons.assignment_rounded, "Tasks"),
                _buildNavItem(2, Icons.check_circle_rounded, "Resolved"),
                _buildNavItem(3, Icons.settings_rounded, "Settings"),
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
    return GestureDetector(
      onTap: () => _onItemTapped(index),
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
                      : Colors.white.withValues(alpha: 0.5),
                  size: size.width * 0.067,
                ),
              ),
            ),
            Positioned(
              bottom: visibleHeight * 0.005,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: 1.0,
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? _accentGold : Colors.white70,
                    fontSize: size.width * 0.025,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

    canvas.drawShadow(
      path,
      Colors.black.withValues(alpha: 0.15),
      size.width * 0.010,
      true,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant ConcaveNavPainter oldDelegate) {
    return oldDelegate.selectedIndex != selectedIndex;
  }
}
