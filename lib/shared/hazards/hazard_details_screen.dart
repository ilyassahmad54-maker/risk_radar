// lib/shared/hazards/hazard_details_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:url_launcher/url_launcher.dart';

// ✅ IMPORT YOUR APP COLORS
import 'package:riskradar/shared/theme/app_colors.dart';
import 'package:riskradar/officers/settings/assigned_tasks_screen.dart';

// --- A fully functional, swipeable fullscreen image viewer ---
class FullscreenImageViewer extends StatefulWidget {
  final List<String> imageUrls;
  final int initialIndex;

  const FullscreenImageViewer({
    super.key,
    required this.imageUrls,
    this.initialIndex = 0,
  });

  @override
  State<FullscreenImageViewer> createState() => _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends State<FullscreenImageViewer> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          'Image ${_currentIndex + 1} of ${widget.imageUrls.length}',
          style: TextStyle(color: Colors.white, fontSize: size.width * 0.040),
        ),
        elevation: 0,
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.imageUrls.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              panEnabled: true,
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                widget.imageUrls[index],
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Center(
                    child: CircularProgressIndicator(
                      value: loadingProgress.expectedTotalBytes != null
                          ? loadingProgress.cumulativeBytesLoaded /
                                (loadingProgress.expectedTotalBytes ?? 1)
                          : null,
                      color: AppColors.accentGold,
                    ),
                  );
                },
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image,
                  size: size.width * 0.133,
                  color: Colors.white,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// --- Singleton class to manage audio playback ---
class VoicePlayerManager {
  static final VoicePlayerManager _instance = VoicePlayerManager._internal();
  factory VoicePlayerManager() => _instance;

  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentUrl;

  VoicePlayerManager._internal();

  Stream<PlayerState> get playerStateStream => _audioPlayer.playerStateStream;
  Stream<Duration?> get durationStream => _audioPlayer.durationStream;
  Stream<Duration> get positionStream => _audioPlayer.positionStream;
  String? get currentUrl => _currentUrl;

  Future<void> play(String url) async {
    if (_currentUrl == url) {
      _audioPlayer.playing ? _audioPlayer.pause() : _audioPlayer.play();
    } else {
      try {
        await _audioPlayer.stop();
        await _audioPlayer.setUrl(url);
        _currentUrl = url;
        _audioPlayer.play();
      } catch (e) {
        debugPrint("Error playing audio: $e");
        _currentUrl = null;
      }
    }
  }

  void stop() {
    _audioPlayer.stop();
    _currentUrl = null;
  }

  void dispose() {
    _audioPlayer.dispose();
    _currentUrl = null;
  }
}

// --- Main Screen Widget ---
class HazardDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> hazardData;

  const HazardDetailsScreen({super.key, required this.hazardData});

  @override
  State<HazardDetailsScreen> createState() => _HazardDetailsScreenState();
}

class _HazardDetailsScreenState extends State<HazardDetailsScreen> {
  final VoicePlayerManager _voicePlayerManager = VoicePlayerManager();

  @override
  void dispose() {
    _voicePlayerManager.stop();
    super.dispose();
  }

  String _formatToLocalTime(String? isoString) {
    if (isoString == null || isoString.isEmpty) return 'N/A';
    try {
      DateTime utcDateTime;
      if (isoString.endsWith('Z') || isoString.contains('+')) {
        utcDateTime = DateTime.parse(isoString).toUtc();
      } else {
        utcDateTime = DateTime.parse("${isoString}Z").toUtc();
      }
      final localDateTime = utcDateTime.toLocal();
      return DateFormat("E, MMM d, yyyy 'at' h:mm a").format(localDateTime);
    } catch (e) {
      debugPrint('Error parsing date ($isoString): $e');
      return 'N/A';
    }
  }

  Color _getSeverityColor(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'high':
        return Colors.red.shade700;
      case 'moderate':
      case 'medium':
        return Colors.orange.shade700;
      case 'low':
        return Colors.green.shade700;
      default:
        return Colors.grey.shade700;
    }
  }

  Color _getStatusColor(String? status) {
    switch (status?.toLowerCase()) {
      case 'resolved':
        return Colors.teal;
      case 'in_progress':
      case 'in progress':
        return Colors.blue.shade700;
      case 'assigned':
        return Colors.deepPurple.shade500;
      case 'reported':
        return Colors.brown.shade500;
      default:
        return Colors.grey.shade700;
    }
  }

  String _hazardSvgAsset(String? type) {
    final String normalized = (type ?? '').toLowerCase();
    if (normalized.contains('fire')) return 'assets/hazards/fire_warning.svg';
    if (normalized.contains('electric') ||
        normalized.contains('shock') ||
        normalized.contains('electrocution')) {
      return 'assets/hazards/electric_shock.svg';
    }
    if (normalized.contains('slip') || normalized.contains('wet')) {
      return 'assets/hazards/slip_falling.svg';
    }
    if (normalized.contains('stair')) return 'assets/hazards/stairs_fall.svg';
    if (normalized.contains('fall')) {
      return 'assets/hazards/falling_objects.svg';
    }
    if (normalized.contains('radio') && normalized.contains('active')) {
      return 'assets/hazards/radio_active.svg';
    }
    if (normalized.contains('temperature')) {
      return 'assets/hazards/high_temperature.svg';
    }
    if (normalized.contains('heat')) return 'assets/hazards/high_heat.svg';
    if (normalized.contains('machine') || normalized.contains('crush')) {
      return 'assets/hazards/machine_crush.svg';
    }
    if (normalized.contains('explosive') || normalized.contains('blast')) {
      return 'assets/hazards/explosion.svg';
    }
    if (normalized.contains('freeze') ||
        normalized.contains('ice') ||
        normalized.contains('cold')) {
      return 'assets/hazards/freeze.svg';
    }
    if (normalized.contains('lift') ||
        normalized.contains('load') ||
        normalized.contains('manual')) {
      return 'assets/hazards/load_lifting.svg';
    }
    if (normalized.contains('wave')) return 'assets/hazards/radio_waves.svg';
    if (normalized.contains('magnetic')) {
      return 'assets/hazards/magnetic_field.svg';
    }
    return 'assets/hazards/fire_warning.svg';
  }

  Future<void> _openMap(double lat, double lng) async {
    final url = 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      debugPrint('Could not launch map.');
    }
  }

  List<String> _parseStringToList(dynamic data) {
    if (data == null) return [];
    if (data is List) {
      return data.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    if (data is String && data.isNotEmpty) {
      return data
          .split(',')
          .map((e) => e.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final hazardData = widget.hazardData;

    final String title = hazardData['hazard_type'] ?? 'Hazard';
    final String description =
        hazardData['description'] ?? 'No description provided.';
    final List<String> images = _parseStringToList(
      hazardData['images'] ?? hazardData['image_url'],
    );
    final List<String> voiceUrls = _parseStringToList(
      hazardData['voice_note_url'],
    );

    // Extract Reporter Name
    String getReporterName() {
      if (hazardData['reporter_name'] != null &&
          hazardData['reporter_name'].isNotEmpty) {
        return hazardData['reporter_name'];
      }
      if (hazardData['reporter'] != null) {
        final reporter = hazardData['reporter'];
        final firstName = reporter['first_name'] ?? '';
        final lastName = reporter['last_name'] ?? '';
        final fullName = '$firstName $lastName'.trim();
        return fullName.isNotEmpty ? fullName : 'Unknown';
      }
      if (hazardData['workers'] != null) {
        final worker = hazardData['workers'];
        final firstName = worker['first_name'] ?? '';
        final lastName = worker['last_name'] ?? '';
        final fullName = '$firstName $lastName'.trim();
        return fullName.isNotEmpty ? fullName : 'Unknown';
      }
      return 'Unknown';
    }

    String? getReporterImageUrl() {
      if (hazardData['workers'] != null &&
          hazardData['workers']['profile_image_url'] != null) {
        return hazardData['workers']['profile_image_url'];
      }
      if (hazardData['reporter'] != null &&
          hazardData['reporter']['profile_image_url'] != null) {
        return hazardData['reporter']['profile_image_url'];
      }
      return null;
    }

    final String reporterName = getReporterName();
    final String? reporterImageUrl = getReporterImageUrl();
    final String severity = hazardData['severity'] ?? 'Unknown';
    final String status = hazardData['status'] ?? 'Unknown';
    final String createdAt = _formatToLocalTime(hazardData['created_at']);
    final double? latitude = hazardData['latitude'] is String
        ? double.tryParse(hazardData['latitude'])
        : hazardData['latitude']?.toDouble();
    final double? longitude = hazardData['longitude'] is String
        ? double.tryParse(hazardData['longitude'])
        : hazardData['longitude']?.toDouble();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.brandTeal,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          "Hazard Details",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        elevation: 1,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(size.width * 0.040),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HazardHeaderCard(
              title: title,
              severity: severity,
              status: status,
              iconAsset: _hazardSvgAsset(title),
              severityColor: _getSeverityColor(severity),
              statusColor: _getStatusColor(status),
            ),
            SizedBox(height: visibleHeight * 0.020),
            if (images.isNotEmpty) ...[
              const _SectionHeader(title: "Photos"),
              SizedBox(height: visibleHeight * 0.010),
              ImageSlideshow(imageUrls: images),
              SizedBox(height: visibleHeight * 0.020),
            ],
            const _SectionHeader(title: "Description"),
            SizedBox(height: visibleHeight * 0.007),
            Text(
              description,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.25),
            ),
            SizedBox(height: visibleHeight * 0.020),
            if (voiceUrls.isNotEmpty) ...[
              const _SectionHeader(title: "Voice Notes"),
              SizedBox(height: visibleHeight * 0.010),
              _VoiceNoteList(
                voiceUrls: voiceUrls,
                playerManager: _voicePlayerManager,
              ),
              SizedBox(height: visibleHeight * 0.020),
            ],
            const _SectionHeader(title: "Details"),
            SizedBox(height: visibleHeight * 0.010),
            Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(size.width * 0.032),
                side: BorderSide(color: Theme.of(context).dividerColor),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: visibleHeight * 0.006),
                child: Column(
                  children: [
                    _DetailItem(
                      icon: Icons.person_pin_circle_outlined,
                      title: "Reported By",
                      value: reporterName,
                      imageUrl: reporterImageUrl,
                    ),
                    _DetailItem(
                      icon: Icons.today_outlined,
                      title: "Reported On",
                      value: createdAt,
                    ),
                    if (latitude != null && longitude != null) ...[
                      Divider(
                        height: visibleHeight * 0.001,
                        indent: size.width * 0.192,
                        endIndent: size.width * 0.043,
                      ), // ✅ Pushed the divider to align with text
                      // ✅ Replaced generic ListTile with _DetailItem to ensure the map icon aligns flawlessly
                      _DetailItem(
                        icon: Icons.location_on_outlined,
                        title: "Location",
                        value: "Lat: $latitude, \nLng: $longitude",
                        trailing: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.brandTeal,
                            foregroundColor: Colors.white,
                          ),
                          icon: Icon(
                            Icons.map_rounded,
                            size: size.width * 0.048,
                          ),
                          label: Text("Open"),
                          onPressed: () => _openMap(latitude, longitude),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SizedBox(height: visibleHeight * 0.020),
            const _SectionHeader(title: "Site Inspectors"),
            SizedBox(height: visibleHeight * 0.010),
            _AssignedWorkerList(
              assignHazardsList: hazardData['assign_hazards'],
              formatAssignedTimestamp: _formatToLocalTime,
              getStatusColor: _getStatusColor,
            ),
            SizedBox(height: visibleHeight * 0.015),

            if (hazardData['id'] != null &&
                hazardData['sites']?['id'] != null)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandTeal,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(
                      vertical: visibleHeight * 0.016,
                    ),
                  ),
                  icon: const Icon(Icons.assignment_ind_outlined),
                  label: const Text('Assign Inspector'),
                  onPressed: () async {
                    final result = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AssignTaskScreen(
                          hazardId: hazardData['id'].toString(),
                          siteId: hazardData['sites']['id'].toString(),
                        ),
                      ),
                    );

                    if (result == true && context.mounted) {
                      Navigator.pop(context, true);
                    }
                  },
                ),
              ),

            SizedBox(height: visibleHeight * 0.020),
          ],
        ),
      ),
    );
  }
}

// --- UI HELPER WIDGETS ---

class _AssignedWorkerList extends StatelessWidget {
  final dynamic assignHazardsList;
  final String Function(String?) formatAssignedTimestamp;
  final Color Function(String?) getStatusColor;

  const _AssignedWorkerList({
    required this.assignHazardsList,
    required this.formatAssignedTimestamp,
    required this.getStatusColor,
  });

  String capitalize(String name) {
    if (name.isEmpty) return '';
    return name[0].toUpperCase() + name.substring(1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final List<dynamic> tasks = (assignHazardsList is List)
        ? assignHazardsList
        : [];
    final validTasks = tasks
        .where((task) => task['hse_worker'] != null)
        .toList();

    if (validTasks.isEmpty) {
      return Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.032),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        child: Padding(
          padding: EdgeInsets.all(size.width * 0.040),
          child: Center(
            child: Text(
              "Not yet assigned to any inspector.",
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
        ),
      );
    }

    return Column(
      children: validTasks.map((task) {
        final worker = task['hse_worker'];
        final workerName = worker != null
            ? "${capitalize(worker['first_name'] ?? 'N/A')} ${capitalize(worker['last_name'] ?? '')}"
                  .trim()
            : 'Unassigned';
        final profileImage = worker?['profile_image_url'];
        final status = task['status']?.toString() ?? 'unknown';
        final assignedAt = formatAssignedTimestamp(task['assigned_at']);

        // ✅ Updated Card to perfectly mirror the internal alignment math of _DetailItem
        return Card(
          elevation: 0,
          margin: EdgeInsets.only(bottom: visibleHeight * 0.007),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size.width * 0.032),
            side: BorderSide(color: Theme.of(context).dividerColor),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: visibleHeight * 0.006),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: size.width * 0.040,
                    vertical: visibleHeight * 0.012,
                  ),
                  child: Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.center, // Vertically centered
                    children: [
                      CircleAvatar(
                        radius: size.width * 0.047,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        backgroundImage:
                            profileImage != null &&
                                profileImage.toString().isNotEmpty
                            ? NetworkImage(profileImage)
                            : null,
                        child:
                            profileImage == null ||
                                profileImage.toString().isEmpty
                            ? Text(workerName.isNotEmpty ? workerName[0] : '?')
                            : null,
                      ),
                      SizedBox(width: size.width * 0.035),
                      Expanded(
                        child: Text(
                          workerName,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: size.width * 0.035,
                          ),
                        ),
                      ),
                      _StatusChip(
                        label: status.replaceAll('_', ' ').toUpperCase(),
                        color: getStatusColor(status),
                      ),
                    ],
                  ),
                ),
                // Optional faint divider, pushing it to align with the text block
                Divider(
                  height: visibleHeight * 0.001,
                  indent: size.width * 0.192,
                  endIndent: size.width * 0.043,
                ),

                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: size.width * 0.040,
                    vertical: visibleHeight * 0.012,
                  ),
                  child: Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.center, // Vertically centered
                    children: [
                      SizedBox(
                        width: size.width * 0.094,
                        child: Center(
                          child: Icon(
                            Icons.assignment_turned_in_outlined,
                            color: AppColors.brandTeal,
                            size: size.width * 0.056,
                          ),
                        ),
                      ),
                      SizedBox(width: size.width * 0.035),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Assigned On",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: size.width * 0.035,
                              ),
                            ),
                            SizedBox(height: visibleHeight * 0.003),
                            Text(
                              assignedAt,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.color,
                                fontSize: size.width * 0.035,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _HazardHeaderCard extends StatelessWidget {
  final String title;
  final String severity;
  final String status;
  final String iconAsset;
  final Color severityColor;
  final Color statusColor;

  const _HazardHeaderCard({
    required this.title,
    required this.severity,
    required this.status,
    required this.iconAsset,
    required this.severityColor,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size.width * 0.043),
      ),
      color: severityColor.withValues(alpha: 0.15),
      child: Padding(
        padding: EdgeInsets.all(size.width * 0.038),
        child: Row(
          children: [
            Container(
              width: size.width * 0.128,
              height: visibleHeight * 0.060,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(size.width * 0.043),
              ),
              child: Center(
                child: SvgPicture.asset(
                  iconAsset,
                  width: size.width * 0.082,
                  height: visibleHeight * 0.038,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            SizedBox(width: size.width * 0.034),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: visibleHeight * 0.007),
                  Wrap(
                    spacing: size.width * 0.021,
                    runSpacing: visibleHeight * 0.007,
                    children: [
                      _StatusChip(label: severity, color: severityColor),
                      _StatusChip(
                        label: status.replaceAll('_', ' ').toUpperCase(),
                        color: statusColor,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Row(
      children: [
        Container(
          width: size.width * 0.011,
          height: visibleHeight * 0.025,
          color: AppColors.accentGold,
        ),
        SizedBox(width: size.width * 0.021),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class ImageSlideshow extends StatefulWidget {
  final List<String> imageUrls;
  const ImageSlideshow({super.key, required this.imageUrls});

  @override
  State<ImageSlideshow> createState() => _ImageSlideshowState();
}

class _ImageSlideshowState extends State<ImageSlideshow> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController.addListener(() {
      if (_pageController.page?.round() != _currentPage) {
        setState(() {
          _currentPage = _pageController.page!.round();
        });
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Widget _buildDot(int index) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: EdgeInsets.symmetric(horizontal: size.width * 0.010),
      height: visibleHeight * 0.010,
      width: _currentPage == index ? size.width * 0.064 : size.width * 0.021,
      decoration: BoxDecoration(
        color: _currentPage == index
            ? AppColors.accentGold
            : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(size.width * 0.013),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    if (widget.imageUrls.isEmpty) return const SizedBox.shrink();

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size.width * 0.032),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.imageUrls.length,
              itemBuilder: (context, index) {
                final imageUrl = widget.imageUrls[index];
                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FullscreenImageViewer(
                          imageUrls: widget.imageUrls,
                          initialIndex: index,
                        ),
                      ),
                    );
                  },
                  child: Hero(
                    tag: imageUrl,
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: Colors.grey.shade200,
                        child: Icon(Icons.broken_image, color: Colors.grey),
                      ),
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : Container(
                              color: Colors.grey.shade200,
                              child: Center(
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.brandTeal,
                                ),
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
            if (widget.imageUrls.length > 1)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: EdgeInsets.all(size.width * 0.020),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      widget.imageUrls.length,
                      (index) => _buildDot(index),
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

// ✅ FIX: Master alignment control for all detail items
class _DetailItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? imageUrl;
  final Widget? trailing; // Added to support the Location Map button natively

  const _DetailItem({
    required this.icon,
    required this.title,
    required this.value,
    this.imageUrl,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: size.width * 0.040,
        vertical: visibleHeight * 0.012,
      ),
      child: Row(
        // Perfectly centers the text block vertically alongside the icon/avatar
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (imageUrl != null && imageUrl!.isNotEmpty)
            CircleAvatar(
              radius: size.width * 0.047,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              backgroundImage: NetworkImage(imageUrl!),
            )
          else
            // Places icons in a strict 40px box so the text line starts exactly the same as the avatar
            SizedBox(
              width: size.width * 0.094,
              child: Center(
                child: Icon(
                  icon,
                  color: AppColors.brandTeal,
                  size: size.width * 0.056,
                ),
              ),
            ),

          SizedBox(width: size.width * 0.035),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize:
                  MainAxisSize.min, // Prevents Column from shifting up/down
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: size.width * 0.035,
                  ),
                ),
                SizedBox(height: visibleHeight * 0.003),
                Text(
                  value,
                  style: TextStyle(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),

          if (trailing != null) ...[
            SizedBox(width: size.width * 0.035),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: size.width * 0.025,
        vertical: visibleHeight * 0.006,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size.width * 0.053),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: size.width * 0.023,
          letterSpacing: size.width * 0.002,
        ),
      ),
    );
  }
}

class _VoiceNoteList extends StatelessWidget {
  final List<String> voiceUrls;
  final VoicePlayerManager playerManager;
  const _VoiceNoteList({required this.voiceUrls, required this.playerManager});

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Column(
      children: List.generate(voiceUrls.length, (index) {
        return Card(
          elevation: 0,
          margin: EdgeInsets.only(bottom: visibleHeight * 0.007),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size.width * 0.032),
            side: BorderSide(color: Theme.of(context).dividerColor),
          ),
          child: VoiceNotePlayer(
            key: ValueKey(voiceUrls[index]),
            url: voiceUrls[index],
            playerManager: playerManager,
          ),
        );
      }),
    );
  }
}

class _PlayerData {
  final PlayerState? playerState;
  final Duration? duration;
  final Duration? position;
  _PlayerData(this.playerState, this.duration, this.position);
}

class VoiceNotePlayer extends StatelessWidget {
  final String url;
  final VoicePlayerManager playerManager;
  const VoiceNotePlayer({
    super.key,
    required this.url,
    required this.playerManager,
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return StreamBuilder<String?>(
      stream: playerManager.playerStateStream
          .map((_) => playerManager.currentUrl)
          .startWith(playerManager.currentUrl),
      builder: (context, activeUrlSnapshot) {
        final bool isActive = activeUrlSnapshot.data == url;

        return StreamBuilder<_PlayerData>(
          stream: Rx.combineLatest3(
            playerManager.playerStateStream,
            playerManager.durationStream,
            playerManager.positionStream,
            (a, b, c) => _PlayerData(a, b, c),
          ),
          builder: (context, snapshot) {
            final playerState = snapshot.data?.playerState;
            final playing = playerState?.playing ?? false;
            final duration = snapshot.data?.duration ?? Duration.zero;
            final position = isActive
                ? (snapshot.data?.position ?? Duration.zero)
                : Duration.zero;

            return Padding(
              padding: EdgeInsets.fromLTRB(
                size.width * 0.020,
                visibleHeight * 0.002,
                size.width * 0.020,
                visibleHeight * 0.0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      isActive && playing
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_filled_rounded,
                    ),
                    iconSize: size.width * 0.082,
                    color: AppColors.brandTeal,
                    onPressed: () => playerManager.play(url),
                  ),
                  SizedBox(width: size.width * 0.016),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: visibleHeight * 0.022,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: visibleHeight * 0.003,
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: size.width * 0.013,
                              ),
                              overlayShape: RoundSliderOverlayShape(
                                overlayRadius: size.width * 0.026,
                              ),
                              activeTrackColor: AppColors.accentGold,
                              inactiveTrackColor: AppColors.brandTeal
                                  .withValues(alpha: 0.2),
                              thumbColor: AppColors.accentGold,
                            ),
                            child: Slider(
                              value: position.inMilliseconds.toDouble().clamp(
                                0.0,
                                duration.inMilliseconds.toDouble(),
                              ),
                              max: duration.inMilliseconds.toDouble(),
                              onChanged: (value) {
                                if (isActive) {
                                  playerManager._audioPlayer.seek(
                                    Duration(milliseconds: value.toInt()),
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: size.width * 0.030,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: TextStyle(fontSize: size.width * 0.027),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: TextStyle(fontSize: size.width * 0.027),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
