// lib/workers/screens/worker_hazard_report_screen.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

import 'package:riskradar/shared/hazards/select_hazard_type_screen.dart';
import 'package:riskradar/workers/screens/worker_home_screen.dart';
import 'package:riskradar/shared/hazards/voice_note_recorder.dart';
import 'package:riskradar/services/repositories/auth_repository.dart';
import 'package:riskradar/services/repositories/hazard_repository.dart';
import 'package:riskradar/services/repositories/sync_repository.dart';
import 'package:riskradar/services/logger_service.dart';
import 'package:riskradar/shared/security/input_sanitizer.dart';
import 'package:riskradar/shared/theme/app_colors.dart';

class WorkerReportHazardScreen extends StatefulWidget {
  final VoidCallback? onHazardReported;

  // Parameters to accept AI Data
  final File? initialImage;
  final String? initialDescription;
  final String? initialSeverity;
  final List<String>? initialHazardTypes;

  const WorkerReportHazardScreen({
    super.key,
    this.onHazardReported,
    this.initialImage,
    this.initialDescription,
    this.initialSeverity,
    this.initialHazardTypes,
  });

  @override
  State<WorkerReportHazardScreen> createState() =>
      _WorkerReportHazardScreenState();
}

class _WorkerReportHazardScreenState extends State<WorkerReportHazardScreen> {
  static const int _descriptionMinLength = 10;
  static const int _descriptionMaxLength = 500;
  static const int _maxSelectedHazards = 4;
  static const String _hazardTypeRequiredMessage =
      'Select at least one hazard type.';
  static const String _maxHazardsMessage =
      'You can only select up to 4 hazards.';
  static const String _descriptionRequiredMessage =
      'Describe the hazard before submitting.';
  static const String _descriptionTooShortMessage =
      'Description must be at least 10 characters.';
  static const String _descriptionTooLongMessage =
      'Description must be 500 characters or fewer.';
  static const String _severityRequiredMessage = 'Select a severity level.';
  static const String _locationRequiredMessage =
      'Location is required before submitting.';
  static const String _locationDeniedMessage =
      'Location permission denied. Enable location access to report a hazard.';
  static const String _locationServiceDisabledMessage =
      'Location services are disabled. Turn them on to report a hazard.';
  static const String _photoRequiredMessage =
      'Capture at least one photo of the hazard.';
  static const String _formValidationMessage =
      'Please fix the highlighted fields before submitting.';
  static const String _stopRecordingMessage = 'Please stop recording first.';
  static const String _stopPlaybackMessage = 'Please stop playback first.';
  static const Set<String> _allowedSeverityLevels = <String>{
    'Low',
    'Moderate',
    'High',
  };

  // State variables
  List<String> _selectedHazardTypes = [];
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _descriptionController = TextEditingController();
  String _severity = 'Low';
  final List<XFile> _selectedImages = [];
  Position? _currentPosition;
  bool _isSubmitting = false;
  bool _isLoadingLocation = false;
  AutovalidateMode _autovalidateMode = AutovalidateMode.onUserInteraction;
  String? _locationError;
  bool _hasSubmittedOnce = false;
  final supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();
  final AuthRepository _authRepository = AuthRepository();
  final HazardRepository _hazardRepository = HazardRepository();
  final SyncRepository _syncRepository = SyncRepository();

  // Worker details
  String? _currentSiteId;
  String? _officerUid;

  // Recorder/player interaction
  final GlobalKey<VoiceNoteRecorderState> _voiceRecorderKey =
      GlobalKey<VoiceNoteRecorderState>();
  bool _isRecording = false;
  bool _isAudioPlaying = false;

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _descriptionController.addListener(_handleDescriptionChanged);
    _getCurrentLocation();
    _fetchWorkerDetails();

    if (widget.initialDescription != null) {
      _descriptionController.text = _cleanReportDescription(
        widget.initialDescription!,
      );
    }
    if (widget.initialSeverity != null) {
      _severity = _normalizeSeverity(widget.initialSeverity!);
    }
    if (widget.initialHazardTypes != null) {
      _selectedHazardTypes = widget.initialHazardTypes!
          .take(_maxSelectedHazards)
          .toList();
    }
    if (widget.initialImage != null) {
      _selectedImages.add(XFile(widget.initialImage!.path));
    }
  }

  @override
  void dispose() {
    _descriptionController.removeListener(_handleDescriptionChanged);
    _descriptionController.dispose();
    super.dispose();
  }

  void _handleDescriptionChanged() {
    if (!mounted) return;
    if (_hasSubmittedOnce) {
      _formKey.currentState?.validate();
    }
    setState(() {});
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FETCH WORKER DETAILS — cache first, Supabase fallback
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _fetchWorkerDetails() async {
    if (!mounted) return;

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      return;
    }

    // ── Step 1: Read from cache immediately ───────────────────────────────
    final cached = _authRepository.getWorkerProfile();
    if (cached != null) {
      _currentSiteId = cached['current_site_id']?.toString();
      _officerUid = cached['officer_uid']?.toString();
      // Still try a background refresh to get latest site assignment
      _refreshWorkerDetailsFromSupabase(userId);
      return;
    }

    // ── Step 2: No cache — must hit Supabase ─────────────────────────────
    await _refreshWorkerDetailsFromSupabase(userId);
  }

  Future<void> _refreshWorkerDetailsFromSupabase(String userId) async {
    try {
      final workerData = await supabase
          .from('workers')
          .select('current_site_id, officer_uid')
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _currentSiteId = workerData['current_site_id']?.toString();
          _officerUid = workerData['officer_uid']?.toString();
        });
      }
    } on SocketException catch (e) {
      // Offline — cached values already applied, nothing to do
      LoggerService.warning(
        '[ReportHazard] Offline, using cached worker details.',
        e,
      );
    } catch (e, s) {
      LoggerService.error('[ReportHazard] Worker details fetch error', e, s);
      if (mounted) {
        // Only show snackbar if we also have no cached data
        if (_currentSiteId == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not verify your site assignment: $e'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CONNECTIVITY CHECK
  // ══════════════════════════════════════════════════════════════════════════

  Future<bool> _isOnline() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 4));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String _normalizeSeverity(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'high') return 'High';
    if (normalized == 'medium' || normalized == 'moderate') return 'Moderate';
    if (normalized == 'low') return 'Low';
    return 'Low';
  }

  String _severityForDatabase(String value) {
    final normalized = value.trim().toLowerCase();

    if (normalized == 'critical') return 'Critical';
    if (normalized == 'high') return 'High';
    if (normalized == 'medium' || normalized == 'moderate') return 'Medium';
    if (normalized == 'low') return 'Low';

    return 'Low';
  }

  String _cleanReportDescription(String value) {
    return InputSanitizer.cleanText(
      value.replaceAll(RegExp(r'[\[\]{}"]'), ''),
      maxLength: _descriptionMaxLength,
    );
  }

  String? _validateDescription(String? value) {
    final String description = value?.trim() ?? '';
    if (description.isEmpty) {
      return _descriptionRequiredMessage;
    }
    if (description.length < _descriptionMinLength) {
      return _descriptionTooShortMessage;
    }
    if (description.length > _descriptionMaxLength) {
      return _descriptionTooLongMessage;
    }
    final securityError = InputSanitizer.validateLongText(
      description,
      minLength: _descriptionMinLength,
      maxLength: _descriptionMaxLength,
    );
    if (securityError != null) {
      return securityError == InputSanitizer.invalidInputMessage
          ? InputSanitizer.invalidInputMessage
          : null;
    }
    return null;
  }

  String? _validateHazardTypes() {
    return _selectedHazardTypes.isEmpty ? _hazardTypeRequiredMessage : null;
  }

  String? _validateSeverity() {
    return _allowedSeverityLevels.contains(_severity)
        ? null
        : _severityRequiredMessage;
  }

  String? _validateLocation() {
    if (_currentPosition != null) {
      return null;
    }
    return _locationError ?? _locationRequiredMessage;
  }

  String? _validateImages() {
    return _selectedImages.isEmpty ? _photoRequiredMessage : null;
  }

  bool get _isReportReady =>
      _validateHazardTypes() == null &&
      _validateDescription(_descriptionController.text) == null &&
      _validateSeverity() == null &&
      _validateLocation() == null &&
      _validateImages() == null;

  String? _reportValidationMessage() {
    final errors = <String>[];
    for (final error in <String?>[
      _validateHazardTypes(),
      _validateDescription(_descriptionController.text),
      _validateSeverity(),
      _validateLocation(),
      _validateImages(),
    ]) {
      if (error != null) errors.add(error);
    }

    if (errors.isEmpty) return null;
    if (errors.length <= 2) return errors.join(' ');

    final remaining = errors.length - 2;
    return '${errors.take(2).join(' ')} +$remaining more.';
  }

  bool _validateReportForm({required bool showErrors}) {
    final bool isTextValid = _formKey.currentState?.validate() ?? false;
    final String? hazardTypeError = _validateHazardTypes();
    final String? severityError = _validateSeverity();
    final String? locationError = _validateLocation();
    final String? imageError = _validateImages();

    if (showErrors && mounted) {
      setState(() {
        _autovalidateMode = AutovalidateMode.onUserInteraction;
        _hasSubmittedOnce = true;
        _locationError = locationError;
      });
    }

    return isTextValid &&
        hazardTypeError == null &&
        severityError == null &&
        locationError == null &&
        imageError == null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SUBMIT HAZARD — online: normal upload | offline: sync queue
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _submitHazard() async {
    if (_isSubmitting) return;

    setState(() => _isSubmitting = true);

    void resetSubmitting() {
      if (mounted) {
        setState(() => _isSubmitting = false);
      } else {
        _isSubmitting = false;
      }
    }

    if (_isRecording || _isAudioPlaying) {
      _showSnack(
        _isRecording ? _stopRecordingMessage : _stopPlaybackMessage,
        isError: true,
      );
      resetSubmitting();
      return;
    }

    if (!_validateReportForm(showErrors: true)) {
      _showSnack(
        _reportValidationMessage() ?? _formValidationMessage,
        isError: true,
      );
      resetSubmitting();
      return;
    }

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      _showSnack("User not logged in", isError: true);
      resetSubmitting();
      return;
    }

    if (_currentSiteId == null || _officerUid == null) {
      await _showNoSiteAssignedDialog();
      resetSubmitting();
      return;
    }

    final online = await _isOnline();
    final String description = InputSanitizer.cleanText(
      _descriptionController.text,
      maxLength: _descriptionMaxLength,
    );

    // ── OFFLINE PATH ──────────────────────────────────────────────────────
    if (!online) {
      try {
        final recordedVoiceFiles =
            _voiceRecorderKey.currentState?.getAllRecordedFiles() ?? [];

        final localId = const Uuid().v4();
        final payload = {
          'id': localId,
          'worker_id': userId,
          'officer_uid': _officerUid,
          'current_site_id': _currentSiteId,
          'hazard_type': _selectedHazardTypes.join(', '),
          'description': description,
          'severity': _severityForDatabase(_severity),
          'latitude': _currentPosition!.latitude,
          'longitude': _currentPosition!.longitude,
          'status': 'reported',
          'image_url': null,
          'voice_note_url': null,
          'image_paths': _selectedImages.map((image) => image.path).toList(),
          'voice_paths': recordedVoiceFiles.map((file) => file.path).toList(),
          'created_at': DateTime.now().toUtc().toIso8601String(),
        };

        await _syncRepository.enqueueAction(
          id: localId,
          table: 'hazards',
          action: 'insert',
          payload: payload,
        );

        // Append to local hazards cache so worker sees it immediately
        await _hazardRepository.appendHazard(payload);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '📴 Saved offline — will sync automatically when online.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
          await Future.delayed(const Duration(seconds: 1));
          _navigateHome();
        }
        return;
      } catch (e, s) {
        LoggerService.error('[ReportHazard] Offline submit error', e, s);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not save the hazard. Please try again.'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
        resetSubmitting();
      }
      return;
    }

    // ── ONLINE PATH ───────────────────────────────────────────────────────
    final List<String> imageUrls = <String>[];
    final List<String> voiceNoteUrls = <String>[];

    try {
      final recordedVoiceFiles =
          _voiceRecorderKey.currentState?.getAllRecordedFiles() ?? [];

      final List<Future<void>> uploadTasks = <Future<void>>[];

      for (final XFile imageFile in _selectedImages) {
        final fileBytes = await imageFile.readAsBytes();
        final fileName = "${const Uuid().v4()}_${imageFile.name}";
        uploadTasks.add(
          supabase.storage
              .from('hazard-images')
              .uploadBinary(fileName, fileBytes)
              .then((_) {
                final imageUrl = supabase.storage
                    .from('hazard-images')
                    .getPublicUrl(fileName);
                imageUrls.add(imageUrl);
              }),
        );
      }

      for (final voiceFile in recordedVoiceFiles) {
        final fileName =
            "voice_notes/${const Uuid().v4()}_${voiceFile.path.split('/').last}";
        uploadTasks.add(
          supabase.storage.from('voice_notes').upload(fileName, voiceFile).then(
            (_) {
              final voiceUrl = supabase.storage
                  .from('voice_notes')
                  .getPublicUrl(fileName);
              voiceNoteUrls.add(voiceUrl);
            },
          ),
        );
      }

      if (uploadTasks.isNotEmpty) {
        await Future.wait(uploadTasks);
      }

      final newHazard = {
        'worker_id': userId,
        'officer_uid': _officerUid,
        'current_site_id': _currentSiteId,
        'hazard_type': _selectedHazardTypes.join(', '),
        'description': description,
        'severity': _severityForDatabase(_severity),
        'latitude': _currentPosition!.latitude,
        'longitude': _currentPosition!.longitude,
        'status': 'reported',
        'image_url': imageUrls.isNotEmpty ? imageUrls.join(',') : null,
        'voice_note_url': voiceNoteUrls.isNotEmpty
            ? voiceNoteUrls.join(',')
            : null,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      final inserted = await supabase
          .from('hazards')
          .insert(newHazard)
          .select()
          .single();

      // Append to local cache immediately
      await _hazardRepository.appendHazard(Map<String, dynamic>.from(inserted));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Hazard reported successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        await Future.delayed(const Duration(seconds: 1));
        _navigateHome();
        widget.onHazardReported?.call();
      }
    } catch (e, s) {
      LoggerService.error('[ReportHazard] Submit error', e, s);
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not report the hazard. Please try again.'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  void _navigateHome() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => WorkerHomeScreen(
          currentThemeMode: ThemeMode.system,
          onThemeChanged: (ThemeMode mode) {},
        ),
      ),
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DIALOGS
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _showNoSiteAssignedDialog() async {
    final mediaQuery = MediaQuery.of(context);
    final visibleHeight =
        mediaQuery.size.height -
        mediaQuery.padding.top -
        mediaQuery.padding.bottom;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('No Site Assigned'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('You do not have any site assigned.'),
                SizedBox(height: visibleHeight * 0.010),
                Text(
                  'To report a hazard, you must be assigned to a site. Please contact your supervisor.',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // ignore: unused_element
  void _showOfflineFilesDialog() {
    final size = MediaQuery.of(context).size;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.051),
        ),
        title: Row(
          children: [
            Icon(Icons.wifi_off_rounded, color: Colors.orange),
            SizedBox(width: size.width * 0.027),
            Text('No Internet'),
          ],
        ),
        content: Text(
          'You are offline. Images and voice notes require an internet connection to upload.\n\n'
          'Remove all images and voice notes to save a text-only report offline — '
          'it will sync automatically when you reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RECORDER & CAMERA HELPERS — unchanged
  // ══════════════════════════════════════════════════════════════════════════

  void _handleRecordingStateChanged(bool isRecording) {
    if (mounted) setState(() => _isRecording = isRecording);
  }

  void _handlePlaybackStateChanged(bool isPlaying) {
    if (mounted) setState(() => _isAudioPlaying = isPlaying);
  }

  void _toggleRecording() {
    if (_isAudioPlaying) return;
    if (_isRecording) {
      _voiceRecorderKey.currentState?.stopRecording();
    } else {
      _voiceRecorderKey.currentState?.startRecording();
    }
  }

  Future<void> _pickImage() async {
    if (_isRecording || _isAudioPlaying) {
      _showSnack(
        _isRecording ? _stopRecordingMessage : _stopPlaybackMessage,
        isError: true,
      );
      return;
    }
    try {
      final permissionStatus = await Permission.camera.request();
      if (!permissionStatus.isGranted) {
        if (!mounted) return;
        _showSnack("Camera permission denied", isError: true);
        return;
      }
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );
      if (pickedFile != null && mounted) {
        setState(() {
          _selectedImages.add(pickedFile);
        });
      }
    } catch (e, s) {
      LoggerService.error('[ReportHazard] Image capture failed', e, s);
      if (!mounted) return;
      _showSnack("Failed to capture image: $e", isError: true);
    }
  }

  Future<void> _getCurrentLocation() async {
    if (!mounted) return;
    setState(() => _isLoadingLocation = true);
    try {
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() {
          _currentPosition = null;
          _isLoadingLocation = false;
          _locationError = _locationServiceDisabledMessage;
        });
        _showSnack(_locationServiceDisabledMessage, isError: true);
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _currentPosition = null;
          _isLoadingLocation = false;
          _locationError = _locationDeniedMessage;
        });
        _showSnack(_locationDeniedMessage, isError: true);
        return;
      }
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          if (!mounted) return;
          setState(() {
            _currentPosition = null;
            _isLoadingLocation = false;
            _locationError = _locationDeniedMessage;
          });
          _showSnack(_locationDeniedMessage, isError: true);
          return;
        }
      }
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
        _isLoadingLocation = false;
        _locationError = null;
      });
    } catch (e, s) {
      LoggerService.error('[ReportHazard] Location capture failed', e, s);
      if (!mounted) return;
      setState(() {
        _currentPosition = null;
        _isLoadingLocation = false;
        _locationError = "Failed to get location: $e";
      });
      _showSnack("Failed to get location: $e", isError: true);
    }
  }

  Future<void> _selectHazardType() async {
    final selectedTypes = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SelectHazardTypeScreen()),
    );
    if (selectedTypes != null && selectedTypes is List<String> && mounted) {
      setState(() {
        _selectedHazardTypes = selectedTypes.take(_maxSelectedHazards).toList();
      });
      if (selectedTypes.length > _maxSelectedHazards) {
        _showSnack(_maxHazardsMessage, isError: true);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD — completely unchanged from original
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final isLightTheme = Theme.of(context).brightness == Brightness.light;

    return PopScope<Object?>(
      canPop: !_isRecording && !_isAudioPlaying,
      onPopInvokedWithResult: _handlePopInvokedWithResult,
      child: Form(
        key: _formKey,
        autovalidateMode: _autovalidateMode,
        child: Scaffold(
          backgroundColor: isLightTheme ? const Color(0xFFF5F5F5) : null,
          appBar: AppBar(
            title: Text("Report Hazard"),
            centerTitle: true,
            backgroundColor: const Color(0xFF1B3D3D),
            foregroundColor: Colors.white,
          ),
          bottomNavigationBar: _buildInputBarSection(),
          body: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: visibleHeight * 0.018),
            children: [
              _buildHazardTypeCard(),
              SizedBox(height: visibleHeight * 0.006),
              _buildSeveritySection(),
              SizedBox(height: visibleHeight * 0.008),
              _buildLocationSection(),
              SizedBox(height: visibleHeight * 0.006),
              _buildImagePreview(),
              SizedBox(height: visibleHeight * 0.006),
              _buildVoiceNotesSection(),
              SizedBox(height: visibleHeight * 0.018),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handlePopInvokedWithResult(bool didPop, Object? result) async {
    if (didPop) return;

    await _voiceRecorderKey.currentState?.discardActiveSession();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isAudioPlaying = false;
    });
    await Navigator.of(context).maybePop();
  }

  Widget _buildInputBarSection() {
    final theme = Theme.of(context);
    final isLightTheme = theme.brightness == Brightness.light;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;

    final isReportReady = _isReportReady;
    final canAttemptSubmit =
        !_isSubmitting && !_isRecording && !_isAudioPlaying;

    final isInputDisabled = _isRecording || _isAudioPlaying;
    final inputBarHeight = visibleHeight * 0.060;
    final inputBarMaxHeight = visibleHeight * 0.082;

    return Container(
      padding: EdgeInsets.only(
        bottom: mediaQuery.viewInsets.bottom + (visibleHeight * 0.006),
        left: size.width * 0.020,
        right: size.width * 0.020,
        top: visibleHeight * 0.006,
      ),
      color: isLightTheme
          ? const Color(0xFFF5F5F5)
          : theme.scaffoldBackgroundColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: inputBarHeight,
                maxHeight: inputBarMaxHeight,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: isLightTheme
                      ? Colors.white
                      : AppColors.brandTeal.withValues(alpha: 0.70),
                  borderRadius: BorderRadius.circular(inputBarHeight / 2),
                  border: Border.all(
                    color: isLightTheme
                        ? AppColors.brandTeal.withValues(alpha: 0.18)
                        : AppColors.accentGold.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          size.width * 0.036,
                          visibleHeight * 0.0,
                          size.width * 0.020,
                          visibleHeight * 0.020,
                        ),
                        child: TextFormField(
                          controller: _descriptionController,
                          enabled: !isInputDisabled,
                          minLines: 1,
                          maxLines: 2,
                          maxLength: _descriptionMaxLength,
                          inputFormatters: const [
                            SanitizingTextInputFormatter(),
                          ],
                          validator: _validateDescription,
                          textAlignVertical: TextAlignVertical.center,
                          style: TextStyle(
                            fontSize: size.width * 0.036,
                            height: visibleHeight * 0.0017,
                            color: isLightTheme
                                ? AppColors.brandTeal
                                : Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            filled: false,
                            fillColor: Colors.transparent,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            counterText: '',
                            errorStyle: TextStyle(
                              fontSize: size.width * 0.0,
                              height: visibleHeight * 0.0,
                            ),
                            errorMaxLines: 1,
                            hintStyle: TextStyle(
                              fontSize: size.width * 0.036,
                              height: visibleHeight * 0.0017,
                              color: isLightTheme
                                  ? AppColors.brandTeal.withValues(alpha: 0.56)
                                  : Colors.white.withValues(alpha: 0.66),
                            ),
                            hintText: _isRecording
                                ? "Recording..."
                                : (_isAudioPlaying
                                      ? "Playing..."
                                      : "Type a description..."),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.only(top: visibleHeight * 0.010),
                      constraints: BoxConstraints(
                        minWidth: size.width * 0.096,
                        minHeight: inputBarHeight,
                      ),
                      icon: Icon(
                        Icons.camera_alt,
                        color: isInputDisabled
                            ? theme.disabledColor
                            : theme.colorScheme.onSurface,
                        size: size.width * 0.056,
                      ),
                      onPressed: isInputDisabled ? null : _pickImage,
                    ),
                    IconButton(
                      padding: EdgeInsets.only(top: visibleHeight * 0.010),
                      constraints: BoxConstraints(
                        minWidth: size.width * 0.096,
                        minHeight: inputBarHeight,
                      ),
                      icon: Icon(
                        _isRecording ? Icons.stop_circle_outlined : Icons.mic,
                        color: _isAudioPlaying
                            ? theme.disabledColor
                            : theme.colorScheme.onSurface,
                        size: size.width * 0.056,
                      ),
                      onPressed: _isAudioPlaying ? null : _toggleRecording,
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: size.width * 0.018),
          SizedBox(
            height: inputBarHeight,
            width: size.width * 0.130,
            child: ElevatedButton(
              onPressed: canAttemptSubmit ? _submitHazard : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: isReportReady
                    ? AppColors.accentGold
                    : theme.disabledColor.withValues(alpha: 0.72),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(inputBarHeight / 2),
                ),
                padding: EdgeInsets.zero,
              ),
              child: _isSubmitting
                  ? SizedBox(
                      width: size.width * 0.056,
                      height: visibleHeight * 0.026,
                      child: CircularProgressIndicator(
                        strokeWidth: size.width * 0.007,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      Icons.send,
                      color: isReportReady
                          ? AppColors.brandTeal
                          : theme.colorScheme.onSurface.withValues(alpha: 0.54),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceNotesSection() {
    final size = MediaQuery.of(context).size;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size.width * 0.040),
      child: VoiceNoteRecorder(
        key: _voiceRecorderKey,
        onRecordingStateChanged: _handleRecordingStateChanged,
        onPlaybackStateChanged: _handlePlaybackStateChanged,
      ),
    );
  }

  String? _selectedHazardIconAsset() {
    if (_selectedHazardTypes.isEmpty) return null;

    const Map<String, String> hazardIconAssets = <String, String>{
      'Fire': 'assets/hazards/fire_warning.svg',
      'Explosives': 'assets/hazards/explosion.svg',
      'Radio Waves': 'assets/hazards/radio_waves.svg',
      'Freeze': 'assets/hazards/freeze.svg',
      'Magnetic Field': 'assets/hazards/magnetic_field.svg',
      'Machine Crush': 'assets/hazards/machine_crush.svg',
      'Falling Objects': 'assets/hazards/falling_objects.svg',
      'High Temperature': 'assets/hazards/high_temperature.svg',
      'High Heat': 'assets/hazards/high_heat.svg',
      'Stairs Falls': 'assets/hazards/stairs_fall.svg',
      'Radioactive': 'assets/hazards/radio_active.svg',
      'Slip / Wet Floor': 'assets/hazards/slip_falling.svg',
      'Electrical / Shock': 'assets/hazards/electric_shock.svg',
      'Manual Handling': 'assets/hazards/load_lifting.svg',
      'Chemical Exposure': 'assets/hazards/fire_warning.svg',
      'PPE Missing': 'assets/hazards/fire_warning.svg',
      'Flooding': 'assets/hazards/fire_warning.svg',
      'Biological Hazard': 'assets/hazards/fire_warning.svg',
      'Noise': 'assets/hazards/fire_warning.svg',
      'Dust / Air Quality': 'assets/hazards/fire_warning.svg',
      'Poor Lighting': 'assets/hazards/fire_warning.svg',
      'Traffic / Vehicles': 'assets/hazards/fire_warning.svg',
      'Equipment Failure': 'assets/hazards/fire_warning.svg',
      'Working at Heights': 'assets/hazards/fire_warning.svg',
      'Confined Spaces': 'assets/hazards/fire_warning.svg',
      'Scaffolding Hazard': 'assets/hazards/fire_warning.svg',
      'Vibration': 'assets/hazards/fire_warning.svg',
      'Collapsing Structures': 'assets/hazards/fire_warning.svg',
      'Insects / Wildlife': 'assets/hazards/fire_warning.svg',
      'Uneven Ground': 'assets/hazards/fire_warning.svg',
      'Unstable Excavation': 'assets/hazards/fire_warning.svg',
      'Crane Operation': 'assets/hazards/fire_warning.svg',
      'Overhead Power Lines': 'assets/hazards/fire_warning.svg',
      'Crowded Work Area': 'assets/hazards/fire_warning.svg',
      'Gas Leak': 'assets/hazards/fire_warning.svg',
    };

    return hazardIconAssets[_selectedHazardTypes.first];
  }

  Widget _buildSelectedHazardIcon() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final String? iconAsset = _selectedHazardIconAsset();
    if (iconAsset == null) {
      return Icon(
        Icons.warning_amber_rounded,
        color: Colors.white,
        size: size.width * 0.070,
      );
    }

    return SvgPicture.asset(
      iconAsset,
      width: size.width * 0.074,
      height: visibleHeight * 0.034,
    );
  }

  Widget _buildHazardTypeCard() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Container(
      margin: EdgeInsets.fromLTRB(
        size.width * 0.040,
        visibleHeight * 0.012,
        size.width * 0.040,
        visibleHeight * 0.006,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.shade400, Colors.deepOrange.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size.width * 0.045),
        boxShadow: [
          BoxShadow(
            color: Colors.orange.withValues(alpha: 0.3),
            blurRadius: size.width * 0.026,
            offset: Offset(size.width * 0.0, visibleHeight * 0.005),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _selectHazardType,
          borderRadius: BorderRadius.circular(size.width * 0.038),
          child: Padding(
            padding: EdgeInsets.all(size.width * 0.036),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(size.width * 0.024),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(size.width * 0.030),
                  ),
                  child: _buildSelectedHazardIcon(),
                ),
                SizedBox(width: size.width * 0.034),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Hazard Type",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: size.width * 0.028,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: visibleHeight * 0.003),
                      Text(
                        _selectedHazardTypes.isEmpty
                            ? "Tap to select hazard types"
                            : _selectedHazardTypes.join(', '),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: size.width * 0.036,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white,
                  size: size.width * 0.040,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSeveritySection() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size.width * 0.040),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Severity Level",
            style: TextStyle(
              fontSize: size.width * 0.036,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: visibleHeight * 0.008),
          Row(
            children: [
              _buildSeverityChip('Low', Colors.green),
              SizedBox(width: size.width * 0.018),
              _buildSeverityChip('Moderate', Colors.orange),
              SizedBox(width: size.width * 0.018),
              _buildSeverityChip('High', Colors.red),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeverityChip(String level, Color color) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final isSelected = _severity == level;
    final isLightTheme = Theme.of(context).brightness == Brightness.light;

    IconData getIconForLevel() {
      switch (level) {
        case 'Low':
          return Icons.check_circle;
        case 'Moderate':
          return Icons.warning;
        case 'High':
          return Icons.error;
        default:
          return Icons.circle;
      }
    }

    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _severity = level),
        borderRadius: BorderRadius.circular(size.width * 0.030),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: visibleHeight * 0.010),
          decoration: BoxDecoration(
            color: isSelected
                ? color
                : (isLightTheme ? Colors.white : color.withValues(alpha: 0.1)),
            borderRadius: BorderRadius.circular(size.width * 0.030),
            border: isSelected
                ? null
                : Border.all(color: color.withValues(alpha: 0.3)),
            boxShadow: isLightTheme && !isSelected
                ? [
                    BoxShadow(
                      color: Colors.grey.withValues(alpha: 0.1),
                      blurRadius: size.width * 0.013,
                      offset: Offset(size.width * 0.0, visibleHeight * 0.003),
                    ),
                  ]
                : [],
          ),
          child: Column(
            children: [
              Icon(
                getIconForLevel(),
                color: isSelected ? Colors.white : color,
                size: size.width * 0.046,
              ),
              SizedBox(height: visibleHeight * 0.003),
              Text(
                level,
                style: TextStyle(
                  fontSize: size.width * 0.030,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? Colors.white : color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLocationSection() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size.width * 0.040),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _currentPosition != null
                ? [Colors.green.shade400, Colors.teal.shade600]
                : [Colors.red.shade400, Colors.red.shade600],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(size.width * 0.045),
          boxShadow: [
            BoxShadow(
              color: (_currentPosition != null ? Colors.green : Colors.red)
                  .withValues(alpha: 0.3),
              blurRadius: size.width * 0.020,
              offset: Offset(size.width * 0.0, visibleHeight * 0.004),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(size.width * 0.028),
          child: _isLoadingLocation
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: size.width * 0.056,
                      height: visibleHeight * 0.026,
                      child: CircularProgressIndicator(
                        strokeWidth: size.width * 0.005,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: size.width * 0.026),
                    Text(
                      "Getting your location...",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: size.width * 0.036,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                )
              : _currentPosition != null
              ? Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(size.width * 0.018),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(size.width * 0.024),
                      ),
                      child: Icon(
                        Icons.location_on,
                        color: Colors.white,
                        size: size.width * 0.054,
                      ),
                    ),
                    SizedBox(width: size.width * 0.028),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Location Captured",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: size.width * 0.032,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: visibleHeight * 0.003),
                          Text(
                            "${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}",
                            style: TextStyle(
                              fontSize: size.width * 0.025,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _getCurrentLocation,
                      icon: Icon(Icons.refresh, color: Colors.white),
                      tooltip: "Refresh location",
                    ),
                  ],
                )
              : Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(size.width * 0.018),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(size.width * 0.024),
                      ),
                      child: Icon(
                        Icons.location_off,
                        color: Colors.white,
                        size: size.width * 0.054,
                      ),
                    ),
                    SizedBox(width: size.width * 0.028),
                    Expanded(
                      child: Text(
                        "Location Required",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: size.width * 0.032,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _getCurrentLocation,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade700,
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.034,
                          vertical: visibleHeight * 0.006,
                        ),
                      ),
                      child: Text("Get Location"),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildImagePreview() {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final horizontalPadding = size.width * 0.040;
    final thumbnailGap = size.width * 0.014;
    final previewWidth = size.width - (horizontalPadding * 2);
    final thumbnailWidth = (previewWidth - (thumbnailGap * 2)) / 3;
    final hasMoreThanThreeImages = _selectedImages.length > 3;
    if (_selectedImages.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        child: Text(
          _photoRequiredMessage,
          style: TextStyle(
            color: Colors.red.shade400,
            fontSize: size.width * 0.030,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: SizedBox(
            width: previewWidth,
            height: visibleHeight * 0.132,
            child: Stack(
              children: [
                ClipRect(
                  child: SizedBox(
                    width: previewWidth,
                    child: ListView.builder(
                      clipBehavior: Clip.hardEdge,
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      itemCount: _selectedImages.length,
                      itemBuilder: (context, index) {
                        final XFile imageFile = _selectedImages[index];
                        return Padding(
                          padding: EdgeInsets.only(
                            right: index == _selectedImages.length - 1
                                ? size.width * 0.0
                                : thumbnailGap,
                          ),
                          child: SizedBox(
                            width: thumbnailWidth,
                            height: visibleHeight * 0.132,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                size.width * 0.026,
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(
                                    File(imageFile.path),
                                    fit: BoxFit.cover,
                                  ),
                                  Positioned(
                                    top: visibleHeight * 0.006,
                                    right: size.width * 0.012,
                                    child: GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _selectedImages.removeAt(index);
                                        });
                                      },
                                      child: Container(
                                        width: size.width * 0.055,
                                        height: size.width * 0.055,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.62,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.close,
                                          color: Colors.white,
                                          size: size.width * 0.034,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                if (hasMoreThanThreeImages)
                  Positioned(
                    right: size.width * 0.012,
                    top: visibleHeight * 0.041,
                    child: IgnorePointer(
                      child: Container(
                        width: size.width * 0.070,
                        height: size.width * 0.070,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.white,
                          size: size.width * 0.052,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
