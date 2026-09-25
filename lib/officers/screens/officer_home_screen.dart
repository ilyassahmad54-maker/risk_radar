// lib/officers/screens/officer_home_screen.dart
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:riskradar/services/providers/hazard_provider.dart';
import 'package:riskradar/services/providers/notification_count_provider.dart';
import 'package:riskradar/services/repositories/officer_repository.dart';
import 'package:riskradar/officers/notifications/officer_hazard_notifier.dart';

// Screens
import 'package:riskradar/officers/screens/resolved_hazards_screen.dart';
import 'package:riskradar/officers/screens/active_task.dart';
import 'package:riskradar/officers/screens/team_overview.dart';
import 'package:riskradar/officers/sites/officer_sites_screen.dart';
import 'package:riskradar/officers/screens/officer_analytics_screen.dart'; // NEW SCREEN IMPORT
import 'package:riskradar/officers/screens/officer_hazard_map_screen.dart';
import '../settings/app_settings_screen.dart';
import '../../shared/settings/about_app_screen.dart';
import 'package:riskradar/shared/screens/shared_emergency_sos_screen.dart';
import 'package:riskradar/shared/widgets/offline_banner.dart';
import 'package:riskradar/shared/widgets/realtime_connection_indicator.dart';

import 'package:riskradar/officers/notifications/notification_screen.dart';

// BRAND COLORS
import 'package:riskradar/shared/theme/app_colors.dart';

class OfficerDashboardCache {
  static final OfficerDashboardCache _instance =
      OfficerDashboardCache._internal();
  factory OfficerDashboardCache() => _instance;
  OfficerDashboardCache._internal();

  int resolvedHazardCount = 0;
  int totalSitesCount = 0;
  String officerName = "Officer";
  String? officerProfileImageUrl;
  dynamic officerUid;
  bool isLoaded = false;
}

class OfficerHomeScreen extends StatefulWidget {
  final ThemeMode currentThemeMode;
  final void Function(ThemeMode) onThemeChanged;

  const OfficerHomeScreen({
    super.key,
    required this.currentThemeMode,
    required this.onThemeChanged,
  });

  @override
  State<OfficerHomeScreen> createState() => _OfficerHomeScreenState();
}

class _OfficerHomeScreenState extends State<OfficerHomeScreen>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final SupabaseClient supabase = Supabase.instance.client;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  late AnimationController _animationController;
  late Animation<double> _curveAnimation;

  bool isLoading = true;
  int _selectedIndex = 0;
  final cache = OfficerDashboardCache();

  final GlobalKey<OfficerSitesScreenState> _sitesKey =
      GlobalKey<OfficerSitesScreenState>();

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
    officerHazardNotifier.startChecking();
    _loadDashboardCacheFirst();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onItemTapped(int index) {
    if (_selectedIndex == index) {
      if (index == 2) {
        _sitesKey.currentState?.refresh();
      }
      return;
    }

    setState(() => _selectedIndex = index);

    if (index == 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _sitesKey.currentState?.refresh();
      });
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

  Future<void> _loadDashboardCacheFirst() async {
    final cached = OfficerRepository.instance.getOfficerDashboard();
    if (cached != null) {
      cache.officerName = cached['officer_name'] ?? "Officer";
      cache.officerProfileImageUrl = cached['profile_image_url'];
      cache.officerUid = cached['officer_uid'];
      cache.resolvedHazardCount = cached['resolved_hazard_count'] ?? 0;
      cache.totalSitesCount = cached['total_sites_count'] ?? 0;
      cache.isLoaded = true;
      if (mounted) setState(() => isLoading = false);
    }

    await _fetchData(showBlockingLoader: cached == null);
  }

  Future<void> _fetchData({bool showBlockingLoader = true}) async {
    final isInitialLoad = !cache.isLoaded;
    if (isInitialLoad && showBlockingLoader && mounted) {
      setState(() => isLoading = true);
    }

    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/');
      return;
    }

    try {
      final officerProfile = await supabase
          .from('officers')
          .select('first_name, last_name, profile_image_url')
          .eq('id', currentUserId)
          .maybeSingle();

      if (officerProfile != null) {
        cache.officerName =
            "${_capitalize(officerProfile['first_name'])} ${_capitalize(officerProfile['last_name'])}"
                .trim();
        cache.officerProfileImageUrl = officerProfile['profile_image_url'];

        // Related tables use officers.id as their officer_uid foreign key.
        cache.officerUid = currentUserId;

        final results = await Future.wait([
          fetchResolvedHazardsCount(currentUserId),
          fetchTotalSitesCount(currentUserId),
        ]);

        cache.resolvedHazardCount = results[0];
        cache.totalSitesCount = results[1];
      }
      cache.isLoaded = true;
      await OfficerRepository.instance.saveOfficerDashboard({
        'officer_name': cache.officerName,
        'profile_image_url': cache.officerProfileImageUrl,
        'officer_uid': cache.officerUid,
        'resolved_hazard_count': cache.resolvedHazardCount,
        'total_sites_count': cache.totalSitesCount,
      });
    } on SocketException {
      debugPrint('Officer dashboard offline - using cached data.');
    } catch (e) {
      debugPrint('Error in _fetchData: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  String _capitalize(String? s) {
    if (s == null || s.isEmpty) return '';
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  void _onAboutTap(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AboutAppScreen()),
    );
  }

  void _onProfileTap() {
    Navigator.of(context).pushNamed('/officer-view-profile');
  }

  Future<int> fetchResolvedHazardsCount(dynamic officerUid) async {
    try {
      final response = await supabase
          .from('resolved_hazards')
          .select()
          .eq('officer_uid', officerUid)
          .count();
      return response.count;
    } catch (e) {
      return 0;
    }
  }

  Future<int> fetchTotalSitesCount(dynamic officerUid) async {
    try {
      final response = await supabase
          .from('sites')
          .select()
          .eq('officer_uid', officerUid)
          .count();
      return response.count;
    } catch (e) {
      return 0;
    }
  }

  void _navigateToSOS() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SharedEmergencySOSScreen(
          currentSiteId: null,
          linkedContractorId: supabase.auth.currentUser!.id,
          isWorker: false,
          isOfficer: true,
        ),
      ),
    );
  }

  // --- UI BUILDERS ---

  Widget _buildOfficerDrawer() {
    return Drawer(
      backgroundColor: AppColors.brandTeal,
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF142E2E)),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Colors.white,
              backgroundImage: cache.officerProfileImageUrl != null
                  ? NetworkImage(cache.officerProfileImageUrl!)
                  : null,
              child: cache.officerProfileImageUrl == null
                  ? Text(
                      cache.officerName.isNotEmpty
                          ? cache.officerName[0].toUpperCase()
                          : "O",
                      style: TextStyle(
                        fontSize: R.blockH * 6,
                        fontWeight: FontWeight.bold,
                        color: AppColors.brandTeal,
                      ),
                    )
                  : null,
            ),
            accountName: Text(
              cache.officerName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: R.blockH * 4.5,
                color: Colors.white,
              ),
            ),
            accountEmail: Text(
              "UID: ${cache.officerUid ?? '-'}",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: R.blockH * 3.5,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "OFFICER CONTEXT",
                  style: TextStyle(
                    color: AppColors.accentGold.withValues(alpha: 0.8),
                    fontSize: R.blockH * 2.75,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(height: R.blockV * 1.875),
                _drawerInfoTile(
                  Icons.business_rounded,
                  "Total Sites",
                  "${cache.totalSitesCount} Sites",
                ),
                _drawerInfoTile(Icons.security, "Role", "Contractor"),
              ],
            ),
          ),
          Divider(color: Colors.white10),
          _drawerTile(Icons.account_circle_outlined, "Profile Details", () {
            Navigator.pop(context);
            _onProfileTap();
          }),
          _drawerTile(Icons.settings_outlined, "Settings", () {
            Navigator.pop(context);
            _onItemTapped(4);
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
    return Padding(
      padding: EdgeInsets.only(bottom: R.blockV * 1.875),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.accentGold),
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

  Widget _dashboardBody() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Consumer(
      builder: (context, ref, child) {
        final hazardState = ref.watch(hazardProvider);
        final activeHazardCount = hazardState.when(
          data: (hazards) => hazards.length,
          error: (error, stackTrace) => 0,
          loading: () => 0,
        );

        return RefreshIndicator(
          onRefresh: () async {
            await Future.wait([
              _fetchData(showBlockingLoader: false),
              ref.read(hazardProvider.notifier).refresh(bypassCache: true),
            ]);
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              size.width * 0.060,
              visibleHeight * 0.030,
              size.width * 0.060,
              visibleHeight * 0.190,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Let's manage",
                  style: TextStyle(
                    fontSize: size.width * 0.055,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
                Text(
                  "Site Safety",
                  style: TextStyle(
                    fontSize: size.width * 0.065,
                    fontWeight: FontWeight.bold,
                    color: AppColors.accentGold,
                  ),
                ),
                SizedBox(height: visibleHeight * 0.036),

                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        title: "System\nAnalytics",
                        count: "Logs",
                        icon: Icons.insights_rounded,
                        color: const Color(0xFF2563EB),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const OfficerAnalyticsScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    SizedBox(width: size.width * 0.043),
                    Expanded(
                      child: _buildStatCard(
                        title: "Resolved\nHazards",
                        count: cache.resolvedHazardCount.toString(),
                        icon: Icons.verified_user_rounded,
                        color: const Color(0xFF10B981),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ResolvedHazardsScreen(),
                            ),
                          );
                          if (mounted) {
                            _fetchData();
                          }
                        },
                      ),
                    ),
                  ],
                ),
                SizedBox(height: visibleHeight * 0.022),
                Row(
                  children: [
                    Expanded(
                      child: _buildStatCard(
                        title: "Active\nHazards",
                        count: activeHazardCount.toString(),
                        icon: Icons.map_rounded,
                        color: const Color(0xFF22D3EE),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const OfficerHazardMapScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    SizedBox(width: size.width * 0.043),
                    Expanded(child: SizedBox()),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatCard({
    required String title,
    required String count,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: visibleHeight * 0.170,
        padding: EdgeInsets.all(size.width * 0.045),
        decoration: BoxDecoration(
          color: AppColors.brandTeal,
          borderRadius: BorderRadius.circular(size.width * 0.055),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  icon,
                  color: color,
                  size: size.width * 0.070,
                ), // Updated icon color to use passed variable slightly
                Icon(
                  Icons.arrow_forward,
                  color: Colors.white24,
                  size: size.width * 0.050,
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count,
                  style: TextStyle(
                    fontSize: size.width * 0.060,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: visibleHeight * 0.004),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: size.width * 0.030,
                    color: Colors.white54,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> get _screens => [
    _dashboardBody(),
    const WorkersListScreen(),
    OfficerSitesScreen(key: _sitesKey),
    const ViewAssignedHazardsScreen(),
    AppSettingsScreen(
      onAboutTap: _onAboutTap,
      onThemeChanged: widget.onThemeChanged,
      currentThemeMode: widget.currentThemeMode,
      onProfileTap: _onProfileTap,
    ),
  ];

  final List<String> _titles = [
    'Dashboard',
    'Team',
    'Sites',
    'Active Tasks',
    'Settings',
  ];

  @override
  Widget build(BuildContext context) {
    R.init(context);
    super.build(context);
    if (isLoading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.brandTeal),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF121212)
        : Colors.grey.shade50;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;

    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, dynamic result) {
        if (didPop) return;
        if (_selectedIndex != 0) {
          _onItemTapped(0);
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildOfficerDrawer(),
        backgroundColor: backgroundColor,
        extendBody: true,
        resizeToAvoidBottomInset: false,

        appBar: AppBar(
          title: Text(
            _titles[_selectedIndex],
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          backgroundColor: AppColors.brandTeal,
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          iconTheme: const IconThemeData(color: Colors.white),

          leading: (_selectedIndex == 0)
              ? GestureDetector(
                  onTap: () => _scaffoldKey.currentState?.openDrawer(),
                  child: Padding(
                    padding: EdgeInsets.all(size.width * 0.025),
                    child: CircleAvatar(
                      backgroundColor: Colors.white,
                      backgroundImage: cache.officerProfileImageUrl != null
                          ? NetworkImage(cache.officerProfileImageUrl!)
                          : null,
                      child: cache.officerProfileImageUrl == null
                          ? Text(
                              cache.officerName.isNotEmpty
                                  ? cache.officerName[0].toUpperCase()
                                  : "O",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.brandTeal,
                              ),
                            )
                          : null,
                    ),
                  ),
                )
              : null,

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
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const NotificationScreen(),
                          ),
                        );
                      },
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
                              color: AppColors.brandTeal,
                              width: size.width * 0.004,
                            ),
                          ),
                          constraints: BoxConstraints(
                            minWidth: size.width * 0.048,
                            minHeight: size.width * 0.048,
                          ),
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: size.width * 0.025,
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
              child: IndexedStack(index: _selectedIndex, children: _screens),
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
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: _curveAnimation,
              builder: (context, child) {
                return CustomPaint(
                  size: Size(size.width, navHeight),
                  painter: ConcaveNavPainter(
                    selectedIndex: _curveAnimation.value,
                    itemsCount: 5,
                    color: AppColors.brandTeal,
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
                _buildNavItem(1, Icons.group_rounded, "Team"),
                _buildNavItem(2, Icons.business_rounded, "Sites"),
                _buildNavItem(3, Icons.task_alt_rounded, "Tasks"),
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
                  color: isSelected ? AppColors.accentGold : Colors.transparent,
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
                    color: isSelected ? AppColors.accentGold : Colors.white70,
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

  @override
  bool get wantKeepAlive => true;
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
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant ConcaveNavPainter oldDelegate) {
    return oldDelegate.selectedIndex != selectedIndex;
  }
}
