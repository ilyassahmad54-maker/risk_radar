// lib/workers/screens/worker_resolved_hazards_screen.dart
// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../shared/hazards/resolved_hazard_report_screen.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';

class WorkerResolvedHazardsScreen extends StatefulWidget {
  final ValueChanged<DateTime>? onSelectedDateChanged;

  const WorkerResolvedHazardsScreen({super.key, this.onSelectedDateChanged});

  @override
  State<WorkerResolvedHazardsScreen> createState() =>
      _WorkerResolvedHazardsScreenState();
}

class _WorkerResolvedHazardsScreenState
    extends State<WorkerResolvedHazardsScreen> {
  final SupabaseClient supabase = Supabase.instance.client;
  final HazardRepository _hazardRepository = HazardRepository();
  final ScrollController _scrollController = ScrollController();

  static const int _pageSize = 20;
  static const double _loadMoreScrollThreshold = 0.8;

  List<Map<String, dynamic>> _allHazards = [];
  List<Map<String, dynamic>> _filteredHazards = [];

  // loading = true only when there is zero cache to show
  bool loading = true;
  bool _isLoadingMore = false;
  bool _hasMoreHazards = true;
  int _currentPage = 0;

  DateTime _selectedDate = DateTime.now();
  late FixedExtentScrollController _calendarController;

  // ── Constants ──────────────────────────────────────────────────────────────
  static const Color _headerTeal = Color(0xFF1B3D3D);
  static const Color _selectedDateColor = Color(0xFFD1F0B1);
  static const Color _successPrimary = Color(0xFF10B981);
  static const Color _successSecondary = Color(0xFF34D399);
  static const Color _warningPrimary = Color(0xFFF59E0B);
  static const Color _warningSecondary = Color(0xFFFBBF24);
  static const Color _errorPrimary = Color(0xFFEF4444);
  static const Color _errorSecondary = Color(0xFFF87171);

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _calendarController = FixedExtentScrollController(initialItem: 30);
    _scrollController.addListener(_handleScroll);
    _loadResolvedHazards();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _calendarController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _isLoadingMore ||
        !_hasMoreHazards ||
        loading) {
      return;
    }

    final ScrollPosition position = _scrollController.position;
    if (position.maxScrollExtent <= 0) {
      return;
    }

    final double triggerOffset =
        position.maxScrollExtent * _loadMoreScrollThreshold;
    if (position.pixels >= triggerOffset) {
      _loadNextPage();
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DATA LOADING — cache first, Supabase second
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _loadResolvedHazards() async {
    // ── Step 1: Paint from cache immediately ──────────────────────────────
    final cached = await _hazardRepository.getResolvedHazards();
    if (cached.isNotEmpty) {
      setState(() {
        _allHazards = cached;
        _filterHazardsByDate(_selectedDate);
        loading = false;
      });
    } else {
      setState(() => loading = true);
    }

    // ── Step 2: Silent background refresh ────────────────────────────────
    await _refreshFromSupabase(resetPagination: true);
  }

  Future<void> _loadNextPage() async {
    if (!_hasMoreHazards || _isLoadingMore) {
      return;
    }

    setState(() => _isLoadingMore = true);
    _currentPage++;
    await _refreshFromSupabase(resetPagination: false);
  }

  Future<void> _refreshFromSupabase({required bool resetPagination}) async {
    if (!mounted) return;
    if (resetPagination) {
      _currentPage = 0;
      _hasMoreHazards = true;
    }

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) {
        setState(() {
          loading = false;
          _isLoadingMore = false;
        });
      }
      return;
    }

    try {
      final int pageStart = _currentPage * _pageSize;
      final int pageEnd = pageStart + _pageSize - 1;
      final data = await supabase
          .from('resolved_hazards')
          .select('*, hse_worker:assigned_to(*), workers:worker_id(*)')
          .eq('worker_id', userId)
          .order('resolved_at', ascending: false)
          .range(pageStart, pageEnd);

      final rows = List<Map<String, dynamic>>.from(data);
      final List<Map<String, dynamic>> updatedRows = resetPagination
          ? rows
          : <Map<String, dynamic>>[..._allHazards, ...rows];

      // Persist to cache and keep all loaded pages available offline.
      await _hazardRepository.saveResolvedHazards(updatedRows);

      if (mounted) {
        setState(() {
          _allHazards = updatedRows;
          _hasMoreHazards = rows.length == _pageSize;
          _filterHazardsByDate(_selectedDate);
          loading = false;
          _isLoadingMore = false;
        });
      }
    } on SocketException {
      debugPrint('ℹ️ [ResolvedHazards] Offline — showing cached data.');
      if (mounted) {
        setState(() {
          loading = false;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ [ResolvedHazards] Refresh error: $e');
      if (mounted) {
        setState(() {
          loading = false;
          _isLoadingMore = false;
        });
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FILTERING — unchanged logic
  // ══════════════════════════════════════════════════════════════════════════

  void _filterHazardsByDate(DateTime date) {
    setState(() {
      _selectedDate = date;
      _filteredHazards = _allHazards.where((hazard) {
        final dateStr = hazard['resolved_at'] ?? hazard['created_at'];
        if (dateStr == null) return false;

        DateTime hazardDate;
        if (dateStr.toString().endsWith('Z')) {
          hazardDate = DateTime.parse(dateStr).toLocal();
        } else {
          hazardDate = DateTime.parse(dateStr).toUtc().toLocal();
        }

        return hazardDate.year == date.year &&
            hazardDate.month == date.month &&
            hazardDate.day == date.day;
      }).toList();
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HELPERS — unchanged
  // ══════════════════════════════════════════════════════════════════════════

  List<Color> _getGradientColors(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'low':
        return [_successPrimary, _successSecondary];
      case 'moderate':
      case 'medium':
        return [_warningPrimary, _warningSecondary];
      case 'high':
        return [_errorPrimary, _errorSecondary];
      default:
        return [_successPrimary, _successSecondary];
    }
  }

  String _getHazardIconPath(String? type) {
    if (type == null) return 'assets/hazards/fire_warning.svg';
    final normalized = type.toLowerCase().trim();
    if (normalized.contains('slip') || normalized.contains('wet'))
      return 'assets/hazards/slip_falling.svg';
    if (normalized.contains('stair')) return 'assets/hazards/stairs_fall.svg';
    if (normalized.contains('fall') && !normalized.contains('slip'))
      return 'assets/hazards/falling_objects.svg';
    if (normalized.contains('electric') || normalized.contains('shock'))
      return 'assets/hazards/electric_shock.svg';
    if (normalized.contains('explosion')) return 'assets/hazards/explosion.svg';
    if (normalized.contains('freeze') || normalized.contains('ice'))
      return 'assets/hazards/freeze.svg';
    if (normalized.contains('high heat') || normalized.contains('heat'))
      return 'assets/hazards/high_heat.svg';
    if (normalized.contains('temperature'))
      return 'assets/hazards/high_temperature.svg';
    if (normalized.contains('lift') || normalized.contains('load'))
      return 'assets/hazards/load_lifting.svg';
    if (normalized.contains('machine') || normalized.contains('crush'))
      return 'assets/hazards/machine_crush.svg';
    if (normalized.contains('magnet'))
      return 'assets/hazards/magnetic_field.svg';
    if (normalized.contains('radio') && normalized.contains('active'))
      return 'assets/hazards/radio_active.svg';
    if (normalized.contains('radio') || normalized.contains('wave'))
      return 'assets/hazards/radio_waves.svg';
    if (normalized.contains('fire')) return 'assets/hazards/fire_warning.svg';
    return 'assets/hazards/fire_warning.svg';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD — unchanged structure, added refresh indicator in header
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF121212)
        : const Color(0xFFF9FAFB);
    final timeTextColor = isDark ? Colors.white54 : Colors.black54;
    final dashedLineColor = isDark ? Colors.white24 : Colors.black12;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: backgroundColor,
        body: RefreshIndicator(
          onRefresh: () => _refreshFromSupabase(resetPagination: true),
          color: _headerTeal,
          child: Stack(
            children: [
              // 1. SCROLLABLE LIST
              loading
                  ? Center(child: CircularProgressIndicator(color: _headerTeal))
                  : _filteredHazards.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(top: visibleHeight * 0.220),
                      children: [
                        SizedBox(
                          height: visibleHeight * 0.450,
                          child: _buildEmptyState(isDark),
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        size.width * 0.025,
                        visibleHeight * 0.220,
                        size.width * 0.045,
                        visibleHeight * 0.150,
                      ),
                      itemCount:
                          _filteredHazards.length + (_isLoadingMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == _filteredHazards.length) {
                          return Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: visibleHeight * 0.020,
                            ),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: _headerTeal,
                              ),
                            ),
                          );
                        }
                        return _buildTimelineItem(
                          _filteredHazards[index],
                          index,
                          timeTextColor,
                          dashedLineColor,
                        );
                      },
                    ),

              // 2. CURVED HEADER
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: CustomPaint(
                  painter: HeaderCurvePainter(color: _headerTeal),
                  child: Container(
                    padding: EdgeInsets.only(bottom: visibleHeight * 0.045),
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(height: visibleHeight * 0.018),
                          SizedBox(
                            height: visibleHeight * 0.112,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: ListWheelScrollView.useDelegate(
                                controller: _calendarController,
                                itemExtent: size.width * 0.173,
                                perspective: 0.002,
                                diameterRatio: 1.5,
                                physics: const FixedExtentScrollPhysics(),
                                onSelectedItemChanged: (index) {
                                  final today = DateTime.now();
                                  final date = today.subtract(
                                    Duration(days: 30 - index),
                                  );
                                  widget.onSelectedDateChanged?.call(date);
                                  _filterHazardsByDate(date);
                                },
                                childDelegate: ListWheelChildBuilderDelegate(
                                  childCount: 31,
                                  builder: (context, index) {
                                    return RotatedBox(
                                      quarterTurns: 1,
                                      child: _buildDateCapsule(index),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── All widget builders below are completely unchanged ─────────────────────

  Widget _buildDateCapsule(int index) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final today = DateTime.now();
    final date = today.subtract(Duration(days: 30 - index));
    final isSelected =
        date.year == _selectedDate.year &&
        date.month == _selectedDate.month &&
        date.day == _selectedDate.day;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: size.width * 0.155,
      margin: EdgeInsets.symmetric(horizontal: size.width * 0.010),
      decoration: BoxDecoration(
        color: isSelected
            ? _selectedDateColor
            : Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(size.width * 0.077),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            DateFormat('d').format(date),
            style: TextStyle(
              color: isSelected ? _headerTeal : Colors.white,
              fontSize: size.width * 0.050,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: visibleHeight * 0.005),
          Text(
            DateFormat('E').format(date),
            style: TextStyle(
              color: isSelected ? _headerTeal : Colors.white60,
              fontSize: size.width * 0.030,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineItem(
    Map<String, dynamic> hazard,
    int index,
    Color timeColor,
    Color lineColor,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final dateStr = hazard['resolved_at'] ?? hazard['created_at'];
    String timeDisplay = '--';
    if (dateStr != null) {
      final dt = DateTime.parse(dateStr).toLocal();
      timeDisplay = DateFormat('h:mm a').format(dt).toLowerCase();
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: size.width * 0.045,
            child: Padding(
              padding: EdgeInsets.only(top: visibleHeight * 0.025),
              child: CustomPaint(painter: DashedLinePainter(color: lineColor)),
            ),
          ),
          SizedBox(width: size.width * 0.006),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: visibleHeight * 0.015),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      left: size.width * 0.004,
                      bottom: visibleHeight * 0.004,
                    ),
                    child: Text(
                      timeDisplay,
                      style: TextStyle(
                        color: timeColor,
                        fontWeight: FontWeight.w600,
                        fontSize: size.width * 0.033,
                      ),
                    ),
                  ),
                  _buildTabbedGradientCard(hazard, index),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabbedGradientCard(Map<String, dynamic> hazard, int index) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final hazardType = hazard['hazard_type'] ?? 'Hazard';
    final description = hazard['description'] ?? 'No description';
    final severity = hazard['severity'];
    final String? reportNumber = hazard['report_number']?.toString();

    final bool hasVoice =
        hazard['voice_note_url'] != null &&
        hazard['voice_note_url'].toString().isNotEmpty;
    final bool hasImage =
        hazard['image_url'] != null &&
        hazard['image_url'].toString().isNotEmpty;
    final bool hasMedia = hasVoice || hasImage;

    final List<Color> gradientColors = _getGradientColors(severity);
    final String iconAsset = _getHazardIconPath(hazardType);

    String? officerImage;
    if (hazard['hse_worker'] != null &&
        hazard['hse_worker']['profile_image_url'] != null) {
      officerImage = hazard['hse_worker']['profile_image_url'];
    }

    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 400 + (index * 100)),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(size.width * 0.0, visibleHeight * 0.037 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  ResolvedHazardReportScreen(hazardId: hazard['id'].toString()),
            ),
          );
        },
        child: CustomPaint(
          painter: TabbedCardGradientPainter(
            gradient: LinearGradient(
              colors: gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              size.width * 0.034,
              visibleHeight * 0.010,
              size.width * 0.034,
              visibleHeight * 0.016,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (reportNumber != null && reportNumber.isNotEmpty) ...[
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.016,
                          vertical: visibleHeight * 0.004,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(
                            size.width * 0.015,
                          ),
                        ),
                        child: Text(
                          '#$reportNumber',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: size.width * 0.025,
                            fontWeight: FontWeight.bold,
                            letterSpacing: size.width * 0.003,
                          ),
                        ),
                      ),
                      SizedBox(width: size.width * 0.021),
                    ],
                    if (hasMedia) ...[
                      if (hasVoice)
                        Icon(
                          Icons.mic_rounded,
                          size: size.width * 0.043,
                          color: Colors.white,
                        ),
                      if (hasVoice && hasImage)
                        SizedBox(width: size.width * 0.011),
                      if (hasImage)
                        Icon(
                          Icons.image_rounded,
                          size: size.width * 0.043,
                          color: Colors.white,
                        ),
                    ] else if (reportNumber == null ||
                        reportNumber.isEmpty) ...[
                      Icon(
                        Icons.more_horiz,
                        size: size.width * 0.080,
                        color: Colors.white,
                      ),
                    ],
                    Spacer(),
                    Transform.translate(
                      offset: Offset(
                        size.width * 0.0,
                        -(visibleHeight * 0.006),
                      ),
                      child: SizedBox(
                        height: visibleHeight * 0.035,
                        width: size.width * 0.075,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white.withValues(alpha: 0.5)
                                  : Colors.black,
                              width: size.width * 0.005,
                            ),
                            image: officerImage != null
                                ? DecorationImage(
                                    image: CachedNetworkImageProvider(
                                      officerImage,
                                    ),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                            color: Colors.white24,
                          ),
                          child: officerImage == null
                              ? Icon(
                                  Icons.security,
                                  size: size.width * 0.041,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: visibleHeight * 0.012),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: size.width * 0.165,
                      height: visibleHeight * 0.074,
                      alignment: Alignment.center,
                      child: SvgPicture.asset(
                        iconAsset,
                        fit: BoxFit.contain,
                        width: size.width * 0.132,
                        height: visibleHeight * 0.060,
                        placeholderBuilder: (context) => Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.white,
                          size: size.width * 0.128,
                        ),
                      ),
                    ),
                    SizedBox(width: size.width * 0.032),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hazardType,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: size.width * 0.043,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          SizedBox(height: visibleHeight * 0.005),
                          Text(
                            description,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontSize: size.width * 0.033,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: size.width * 0.018),
                    Container(
                      padding: EdgeInsets.all(size.width * 0.015),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: size.width * 0.005,
                        ),
                      ),
                      child: Icon(
                        Icons.check,
                        size: size.width * 0.041,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.event_note,
            size: size.width * 0.171,
            color: isDark ? Colors.white12 : Colors.black12,
          ),
          SizedBox(height: visibleHeight * 0.020),
          Text(
            "No hazards found for this day",
            style: TextStyle(color: isDark ? Colors.white38 : Colors.black38),
          ),
        ],
      ),
    );
  }
}

// ── PAINTERS — completely unchanged ───────────────────────────────────────────

class HeaderCurvePainter extends CustomPainter {
  final Color color;
  HeaderCurvePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final curveDepth = size.height * 0.180;

    final path = Path();
    path.lineTo(0, size.height - curveDepth);
    path.quadraticBezierTo(
      size.width / 2,
      size.height,
      size.width,
      size.height - curveDepth,
    );
    path.lineTo(size.width, 0);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class DashedLinePainter extends CustomPainter {
  final Color color;
  DashedLinePainter({this.color = Colors.white24});

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    double dashHeight = 5, dashSpace = 3, startY = 0;
    while (startY < size.height) {
      canvas.drawLine(
        Offset(size.width / 2, startY),
        Offset(size.width / 2, startY + dashHeight),
        paint,
      );
      startY += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant DashedLinePainter oldDelegate) =>
      color != oldDelegate.color;
}

class TabbedCardGradientPainter extends CustomPainter {
  final Gradient gradient;
  TabbedCardGradientPainter({required this.gradient});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      )
      ..style = PaintingStyle.fill;

    final path = Path();
    const double radius = 20.0;
    const double tabHeight = 28.0;
    const double tabWidth = 115.0;

    path.moveTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);
    path.lineTo(tabWidth - 20, 0);
    path.cubicTo(tabWidth, 0, tabWidth, tabHeight, tabWidth + 20, tabHeight);
    path.lineTo(size.width - radius, tabHeight);
    path.quadraticBezierTo(
      size.width,
      tabHeight,
      size.width,
      tabHeight + radius,
    );
    path.lineTo(size.width, size.height - radius);
    path.quadraticBezierTo(
      size.width,
      size.height,
      size.width - radius,
      size.height,
    );
    path.lineTo(radius, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - radius);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
