// lib/officers/screens/resolved_hazards_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';
import 'hazard_report_generation_screen.dart';

class ResolvedHazardsScreen extends StatefulWidget {
  const ResolvedHazardsScreen({super.key});

  @override
  State<ResolvedHazardsScreen> createState() => _ResolvedHazardsScreenState();
}

class _ResolvedHazardsScreenState extends State<ResolvedHazardsScreen> {
  final SupabaseClient supabase = Supabase.instance.client;
  final HazardRepository _hazardRepository = HazardRepository();
  final ScrollController _scrollController = ScrollController();

  static const int _pageSize = 20;
  static const double _loadMoreScrollThreshold = 0.8;

  List<Map<String, dynamic>> _allHazards = [];
  List<Map<String, dynamic>> _filteredHazards = [];

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMoreHazards = true;
  int _currentPage = 0;
  String? _error;
  DateTime _selectedDate = DateTime.now();
  late FixedExtentScrollController _calendarController;

  // --- Constants ---
  static const Color _headerTeal = Color(0xFF1B3D3D);
  static const Color _selectedDateColor = Color(0xFFD1F0B1);

  // Gradient Colors
  static const Color _successPrimary = Color(0xFF10B981);
  static const Color _successSecondary = Color(0xFF34D399);
  static const Color _warningPrimary = Color(0xFFF59E0B);
  static const Color _warningSecondary = Color(0xFFFBBF24);
  static const Color _errorPrimary = Color(0xFFEF4444);
  static const Color _errorSecondary = Color(0xFFF87171);

  @override
  void initState() {
    super.initState();
    _calendarController = FixedExtentScrollController(initialItem: 30);
    _scrollController.addListener(_handleScroll);
    _loadResolvedCacheFirst();
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
        _isLoading) {
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

  Future<void> _loadResolvedCacheFirst() async {
    final cached = await _hazardRepository.getOfficerResolvedHazards();
    if (cached != null) {
      setState(() {
        _allHazards = cached;
        _isLoading = false;
        _error = null;
      });
      _filterHazardsByDate(_selectedDate);
    }

    await fetchResolvedHazards(
      showBlockingLoader: cached == null,
      resetPagination: true,
    );
  }

  Future<void> _loadNextPage() async {
    if (!_hasMoreHazards || _isLoadingMore) {
      return;
    }

    setState(() => _isLoadingMore = true);
    _currentPage++;
    await fetchResolvedHazards(
      showBlockingLoader: false,
      resetPagination: false,
    );
  }

  Future<void> _refreshResolvedHazards() async {
    await fetchResolvedHazards(
      showBlockingLoader: false,
      resetPagination: true,
    );
  }

  Future<void> fetchResolvedHazards({
    bool showBlockingLoader = true,
    bool resetPagination = true,
  }) async {
    if (!mounted) {
      return;
    }
    if (resetPagination) {
      _currentPage = 0;
      _hasMoreHazards = true;
    }
    if (showBlockingLoader) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final int pageStart = _currentPage * _pageSize;
      final int pageEnd = pageStart + _pageSize - 1;
      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId == null) {
        throw Exception('No authenticated officer found.');
      }

      // Related tables store officers.id in their officer_uid column.
      final officerUid = currentUserId;

      final response = await supabase
          .from('resolved_hazards')
          .select('''
            *,
            workers:worker_id(first_name, last_name, work_type, profile_image_url),
            resolver:assigned_to(first_name, last_name, designation, profile_image_url),
            sites:current_site_id(name)
          ''')
          .eq('officer_uid', officerUid)
          .order('resolved_at', ascending: false)
          .range(pageStart, pageEnd);

      final List<Map<String, dynamic>> processedHazards = response.map((h) {
        final workerInfo = h['workers'] as Map<String, dynamic>?;
        String reporterName = 'Orphaned';
        String? imageUrl; // ✅ Create a variable to safely hold the image URL

        if (workerInfo != null) {
          reporterName =
              '${workerInfo['first_name']} ${workerInfo['last_name']}';
          if (workerInfo['work_type'] != null) {
            reporterName += ' (${workerInfo['work_type']})';
          }
          // ✅ Explicitly grab the image URL from the join
          imageUrl = workerInfo['profile_image_url'];
        }

        return {
          ...h,
          'reporter_name': reporterName,
          // ✅ Explicitly build the reporter object so the details screen gets exactly what it expects
          'reporter': {
            'first_name': workerInfo?['first_name'],
            'last_name': workerInfo?['last_name'],
            'work_type': workerInfo?['work_type'],
            'profile_image_url': imageUrl,
          },
        };
      }).toList();

      final List<Map<String, dynamic>> updatedHazards = resetPagination
          ? processedHazards
          : <Map<String, dynamic>>[..._allHazards, ...processedHazards];

      if (!mounted) {
        return;
      }
      await _hazardRepository.saveOfficerResolvedHazards(updatedHazards);
      setState(() {
        _allHazards = updatedHazards;
        _hasMoreHazards = processedHazards.length == _pageSize;
        _isLoading = false;
        _isLoadingMore = false;
      });
      _filterHazardsByDate(_selectedDate);
    } on SocketException {
      debugPrint('Officer resolved hazards offline - using cached data.');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching resolved hazards: $e');
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Failed to load hazards. Please try again.';
        _isLoading = false;
        _isLoadingMore = false;
      });
    }
  }

  void _filterHazardsByDate(DateTime date) {
    setState(() {
      _selectedDate = date;
      _filteredHazards = _allHazards.where((hazard) {
        final dateStr = hazard['resolved_at'] ?? hazard['created_at'];
        if (dateStr == null) {
          return false;
        }

        DateTime hazardDate;
        final str = dateStr.toString();
        if (str.endsWith('Z') || str.contains('+')) {
          hazardDate = DateTime.parse(str).toLocal();
        } else {
          hazardDate = DateTime.parse("${str}Z").toLocal();
        }

        return hazardDate.year == date.year &&
            hazardDate.month == date.month &&
            hazardDate.day == date.day;
      }).toList();
    });
  }

  List<Color> _getGradientColors(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'low':
        return [_successPrimary, _successSecondary];
      case 'moderate':
        return [_warningPrimary, _warningSecondary];
      case 'high':
        return [_errorPrimary, _errorSecondary];
      default:
        return [_successPrimary, _successSecondary];
    }
  }

  String _getHazardIconPath(String? type) {
    if (type == null) {
      return 'assets/hazards/fire_warning.svg';
    }

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
        body: Stack(
          children: [
            _isLoading
                ? Center(child: CircularProgressIndicator(color: _headerTeal))
                : _error != null
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(top: visibleHeight * 0.220),
                    children: [
                      SizedBox(
                        height: visibleHeight * 0.450,
                        child: Center(child: Text(_error!)),
                      ),
                    ],
                  )
                : _filteredHazards.isEmpty
                ? RefreshIndicator(
                    onRefresh: _refreshResolvedHazards,
                    color: _headerTeal,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(top: visibleHeight * 0.220),
                      children: [
                        SizedBox(
                          height: visibleHeight * 0.450,
                          child: _buildEmptyState(isDark),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _refreshResolvedHazards,
                    color: _headerTeal,
                    child: ListView.builder(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        size.width * 0.025,
                        visibleHeight * 0.260,
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
                  ),

            Positioned(
              top: visibleHeight * 0.0,
              left: size.width * 0.0,
              right: size.width * 0.0,
              child: CustomPaint(
                painter: HeaderCurvePainter(color: _headerTeal),
                child: Container(
                  padding: EdgeInsets.only(bottom: visibleHeight * 0.045),
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                                size: size.width * 0.056,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                            Expanded(
                              child: Text(
                                DateFormat('MMMM yyyy').format(_selectedDate),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: size.width * 0.052,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            SizedBox(width: size.width * 0.120),
                          ],
                        ),
                        SizedBox(height: visibleHeight * 0.006),
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
    );
  }

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
      DateTime dt;
      final str = dateStr.toString();
      if (str.endsWith('Z') || str.contains('+')) {
        dt = DateTime.parse(str).toLocal();
      } else {
        dt = DateTime.parse("${str}Z").toLocal();
      }
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
              child: CustomPaint(
                painter: DashedLinePainter(color: lineColor),
              ),
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
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final String reportNumber = hazard['report_number']?.toString() ?? 'N/A';

    String siteName = 'Unknown';
    if (hazard['sites'] != null) {
      if (hazard['sites'] is Map && hazard['sites']['name'] != null) {
        siteName = hazard['sites']['name'];
      } else if (hazard['sites'] is List && hazard['sites'].isNotEmpty) {
        siteName = hazard['sites'][0]['name'] ?? 'Unknown';
      }
    }

    final hazardType = hazard['hazard_type'] ?? 'Hazard';
    final description = hazard['description'] ?? 'No description';
    final severity = hazard['severity'];

    final images =
        (hazard['image_url'] != null &&
            hazard['image_url'].toString().isNotEmpty)
        ? hazard['image_url']
              .toString()
              .split(',')
              .map((e) => e.trim())
              .toList()
        : <String>[];
    final voiceUrls =
        (hazard['voice_note_url'] != null &&
            hazard['voice_note_url'].toString().trim().isNotEmpty)
        ? hazard['voice_note_url']
              .toString()
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];

    final bool hasImages = images.isNotEmpty;
    final bool hasVoiceNotes = voiceUrls.isNotEmpty;

    final List<Color> gradientColors = _getGradientColors(severity);
    final String iconAsset = _getHazardIconPath(hazardType);
    final resolver = hazard['resolver'] is Map
        ? hazard['resolver'] as Map
        : hazard['hse_worker'] is Map
        ? hazard['hse_worker'] as Map
        : null;
    final String? resolverImage = resolver?['profile_image_url']?.toString();

    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 400 + (index * 100)),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(
            size.width * 0.0,
            visibleHeight * 0.037 * (1 - value),
          ),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ResolvedHazardDetailsScreen(hazard: hazard),
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
                    // ✅ Report Number Tag
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: size.width * 0.018,
                        vertical: visibleHeight * 0.003,
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
                          fontSize: size.width * 0.030,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    // ✅ Media Icons (Profile Image entirely removed from here)
                    if (hasVoiceNotes) ...[
                      SizedBox(width: size.width * 0.021),
                      Icon(
                        Icons.mic_rounded,
                        size: size.width * 0.041,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ],
                    if (hasImages) ...[
                      SizedBox(width: size.width * 0.021),
                      Icon(
                        Icons.image_rounded,
                        size: size.width * 0.041,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ],
                    Spacer(),
                    Transform.translate(
                      offset: Offset(
                        size.width * 0.0,
                        -(visibleHeight * 0.018),
                      ),
                      child: Container(
                        width: size.width * 0.075,
                        height: size.width * 0.075,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white24,
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.5)
                                : Colors.black,
                            width: size.width * 0.005,
                          ),
                          image:
                              resolverImage != null &&
                                  resolverImage.trim().isNotEmpty
                              ? DecorationImage(
                                  image: CachedNetworkImageProvider(
                                    resolverImage,
                                  ),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child:
                            resolverImage == null ||
                                resolverImage.trim().isEmpty
                            ? Icon(
                                Icons.person,
                                size: size.width * 0.041,
                                color: Colors.white,
                              )
                            : null,
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
                          SizedBox(height: visibleHeight * 0.006),

                          Row(
                            children: [
                              Icon(
                                Icons.location_on,
                                size: size.width * 0.031,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                              SizedBox(width: size.width * 0.011),
                              Expanded(
                                child: Text(
                                  'Site: $siteName',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    fontSize: size.width * 0.030,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
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
            size: size.width * 0.164,
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

// --- PAINTERS ---

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
    path.lineTo(size.width * 0.0, size.height - curveDepth);
    path.quadraticBezierTo(
      size.width * 0.5,
      size.height,
      size.width,
      size.height - curveDepth,
    );
    path.lineTo(size.width, size.height * 0.0);
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
      ..strokeWidth = size.width * 0.020
      ..style = PaintingStyle.stroke;

    double dashHeight = size.height * 0.040;
    double dashSpace = size.height * 0.022;
    double startY = size.height * 0.0;
    while (startY < size.height) {
      canvas.drawLine(
        Offset(size.width * 0.5, startY),
        Offset(size.width * 0.5, startY + dashHeight),
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
    final double radius = size.width * 0.060;
    final double tabHeight = size.height * 0.220;
    final double tabWidth = size.width * 0.390;
    final double tabShoulder = size.width * 0.045;

    path.moveTo(size.width * 0.0, radius);
    path.quadraticBezierTo(
      size.width * 0.0,
      size.height * 0.0,
      radius,
      size.height * 0.0,
    );
    path.lineTo(tabWidth - tabShoulder, size.height * 0.0);
    path.cubicTo(
      tabWidth,
      size.height * 0.0,
      tabWidth,
      tabHeight,
      tabWidth + tabShoulder,
      tabHeight,
    );
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
    path.quadraticBezierTo(
      size.width * 0.0,
      size.height,
      size.width * 0.0,
      size.height - radius,
    );
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
