import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:riskradar/services/repositories/auth_repository.dart';
import 'package:riskradar/services/supabase_service.dart';
import 'package:riskradar/officers/screens/officer_home_screen.dart';
import 'package:riskradar/hse_worker/screens/hse_worker_dashboard.dart';
import 'package:riskradar/workers/screens/worker_home_screen.dart';
import 'package:riskradar/shared/security/input_sanitizer.dart';
import 'package:riskradar/shared/utils/profile_photo_permission.dart';
import 'package:riskradar/shared/widgets/risk_radar_loader.dart';
import 'package:riskradar/shared/services/logout_service.dart'; // ✅ Import Added

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  // ---------------------------------------------------------------------------
  // ✅ LOGIC SECTION
  // ---------------------------------------------------------------------------
  File? _imageFile;
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  String? _selectedContractorId;
  String? _selectedContractorName;

  String? _role;
  String? _workType;
  String? _hseDesignation;
  String? _birthDay;
  String? _birthMonth;
  String? _birthYear;
  bool _isSaving = false;
  bool _isProfileSaved = false;
  bool _isLoadingProfile = true;

  static const String _workerRole = 'Worker';
  static const String _contractorRole = 'Contractor';
  static const String _safetyRole = 'Safety Officer';

  final List<String> _roles = [_workerRole, _safetyRole, _contractorRole];
  final List<String> _workTypes = [
    'Mason',
    'Plumber',
    'Electrician',
    'Painter',
    'Carpenter',
    'Welder',
    'Other',
  ];
  final List<String> _hseDesignations = [
    'Safety Inspector',
    'Safety Engineer',
    'Safety Supervisor',
    'Technician',
    'Other',
  ];
  final List<String> _days = List.generate(31, (i) => '${i + 1}');
  final List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final List<String> _years = List.generate(
    80,
    (i) => '${DateTime.now().year - i}',
  );

  @override
  void initState() {
    super.initState();
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null && user.email != null) {
      _emailController.text = user.email!;
    }
    _loadProfileIfExists();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  // --- Image Cropper Logic ---
  Future<File?> _cropImage(File imageFile) async {
    final croppedFile = await ImageCropper().cropImage(
      sourcePath: imageFile.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Edit Photo',
          toolbarColor: const Color(0xFF1B3D3D), // Matches your Teal Theme
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true, // Force square for profile pics
          aspectRatioPresets: [CropAspectRatioPreset.square],
          hideBottomControls: true,
        ),
        IOSUiSettings(
          title: 'Edit Photo',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
          aspectRatioPresets: [CropAspectRatioPreset.square],
        ),
      ],
    );
    if (croppedFile != null) return File(croppedFile.path);
    return null;
  }

  // --- Pick & Crop Logic ---
  Future<void> _pickImage(ImageSource source) async {
    final bool hasPermission = await requestProfilePhotoPermission(
      context,
      source,
    );
    if (!hasPermission) {
      return;
    }

    try {
      // 1. Pick Image
      final picked = await ImagePicker().pickImage(source: source);
      if (picked == null) return;

      // 2. Crop Image immediately after picking
      final File? cropped = await _cropImage(File(picked.path));

      // 3. Set State if crop was successful
      if (cropped != null) {
        setState(() => _imageFile = cropped);
      }
    } catch (e) {
      if (mounted) {
        _showMessage('Error processing image: $e');
      }
    }
  }

  void _showPicker() {
    if (_isProfileSaved) return;
    final size = MediaQuery.of(context).size;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(size.width * 0.051),
        ),
      ),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.photo_library, color: Color(0xFF1B3D3D)),
              title: Text(
                'Gallery',
                style: TextStyle(color: Color(0xFF1B3D3D)),
              ),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_camera, color: Color(0xFF1B3D3D)),
              title: Text('Camera', style: TextStyle(color: Color(0xFF1B3D3D))),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _navigateToHomeScreen() {
    void onThemeChanged(ThemeMode mode) {}
    Widget screen;
    if (_role == _contractorRole) {
      screen = OfficerHomeScreen(
        currentThemeMode: ThemeMode.system,
        onThemeChanged: onThemeChanged,
      );
    } else if (_role == _safetyRole) {
      screen = HSEWorkerHomeScreen(
        currentThemeMode: ThemeMode.system,
        onThemeChanged: onThemeChanged,
      );
    } else {
      screen = WorkerHomeScreen(
        currentThemeMode: ThemeMode.system,
        onThemeChanged: onThemeChanged,
      );
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  Future<void> _changeAccount() async {
    if (_isSaving) return;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.071),
        ),
        backgroundColor: Colors.transparent,
        elevation: size.width * 0.0,
        child: Container(
          padding: EdgeInsets.all(size.width * 0.060),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1B3D3D),
                const Color(0xFF1B3D3D).withValues(alpha: 0.85),
              ],
            ),
            borderRadius: BorderRadius.circular(size.width * 0.071),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: size.width * 0.051,
                offset: Offset(size.width * 0.0, visibleHeight * 0.012),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(size.width * 0.040),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: Colors.white,
                  size: size.width * 0.081,
                ),
              ),
              SizedBox(height: visibleHeight * 0.025),
              Text(
                'Change Account',
                style: TextStyle(
                  fontSize: size.width * 0.055,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: visibleHeight * 0.015),
              Text(
                'You will be signed out and returned to login so you can use a different email.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size.width * 0.038,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              SizedBox(height: visibleHeight * 0.035),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: size.width * 0.040,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(width: size.width * 0.032),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1B3D3D),
                      padding: EdgeInsets.symmetric(
                        horizontal: size.width * 0.061,
                        vertical: visibleHeight * 0.015,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(size.width * 0.041),
                      ),
                      elevation: size.width * 0.010,
                    ),
                    child: Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: size.width * 0.040,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;

    setState(() => _isSaving = true);
    try {
      await LogoutService.signOut();
      await AuthRepository().clearAll();
      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
    } catch (_) {
      if (mounted) {
        _showMessage('Could not sign out. Please try again.', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _loadProfileIfExists() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      setState(() => _isLoadingProfile = false);
      return;
    }
    try {
      final officer = await Supabase.instance.client
          .from('officers')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (officer != null) {
        setState(() {
          _role = _contractorRole;
          _firstNameController.text = officer['first_name'] ?? '';
          _isProfileSaved = true;
        });
        _navigateToHomeScreen();
        return;
      }
      final worker = await Supabase.instance.client
          .from('workers')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (worker != null) {
        setState(() {
          _role = _workerRole;
          _firstNameController.text = worker['first_name'] ?? '';
          _isProfileSaved = true;
        });
        _navigateToHomeScreen();
        return;
      }
      final safetyWorker = await Supabase.instance.client
          .from('hse_workers')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (safetyWorker != null) {
        setState(() {
          _role = _safetyRole;
          _firstNameController.text = safetyWorker['first_name'] ?? '';
          _isProfileSaved = true;
        });
        _navigateToHomeScreen();
        return;
      }
    } catch (e) {
      debugPrint("Error loading profile: $e");
    }
    setState(() => _isLoadingProfile = false);
  }

  Future<void> _onSave() async {
    if (_isSaving || _isProfileSaved) return;
    final firstName = InputSanitizer.cleanText(
      _firstNameController.text,
      maxLength: 50,
    );
    final lastName = InputSanitizer.cleanText(
      _lastNameController.text,
      maxLength: 50,
    );
    final firstNameError = InputSanitizer.validateName(firstName);
    final lastNameError = InputSanitizer.validateName(
      lastName,
      required: false,
    );
    if (firstNameError == InputSanitizer.invalidInputMessage ||
        lastNameError == InputSanitizer.invalidInputMessage) {
      _showMessage(InputSanitizer.invalidInputMessage, isError: true);
      return;
    }
    if (_role == null || firstName.isEmpty || _imageFile == null) {
      _showMessage(
        'Please complete all required fields and upload a photo.',
        isError: true,
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        _showMessage(
          'Your session expired. Please sign in again.',
          isError: true,
        );
        if (mounted) setState(() => _isSaving = false);
        return;
      }

      String? dobFormatted;
      if (_birthDay != null && _birthMonth != null && _birthYear != null) {
        final monthIndex = _months.indexOf(_birthMonth!) + 1;
        dobFormatted =
            '${_birthYear!}-${monthIndex.toString().padLeft(2, '0')}-${_birthDay!.padLeft(2, '0')}';
      }

      if (_role == _workerRole || _role == _safetyRole) {
        if (_selectedContractorId == null) {
          await _showContractorUidDialog(
            title: 'Contractor required',
            message: 'Please select your contractor before continuing.',
            icon: Icons.person_search_rounded,
          );
          if (mounted) setState(() => _isSaving = false);
          return;
        }
      }

      final imageUrl = await SupabaseService().uploadProfileImage(
        _imageFile!,
        user.id,
        'profile',
      );

      final data = {
        'id': user.id,
        'first_name': firstName,
        'last_name': lastName,
        'email': _emailController.text.trim(),
        'dob': dobFormatted,
        'profile_image_url': imageUrl,
        'created_at': DateTime.now().toIso8601String(),
      };

      if (_role == _workerRole) {
        await Supabase.instance.client.from('workers').insert({
          ...data,
          'officer_uid': _selectedContractorId,
          'work_type': _workType,
        });
      } else if (_role == _safetyRole) {
        await Supabase.instance.client.from('hse_workers').insert({
          ...data,
          'officer_uid': _selectedContractorId,
          'designation': _hseDesignation,
        });
      } else {
        await Supabase.instance.client.from('officers').insert(data);
      }
      _showMessage('✅ Profile saved!');
      setState(() => _isProfileSaved = true);
      _navigateToHomeScreen();
    } catch (e, stackTrace) {
      debugPrint('════════ PROFILE SETUP SAVE FAILED ════════');
      debugPrint('ERROR TYPE: ${e.runtimeType}');
      debugPrint('ERROR: $e');
      debugPrint('STACK TRACE: $stackTrace');
      debugPrint('════════════════════════════════════════════');
      _showMessage('Could not save profile. Please try again.', isError: true);
    }
    setState(() => _isSaving = false);
  }

  Future<void> _selectContractor() async {
    try {
      final contractors = await Supabase.instance.client.rpc(
        'get_contractor_directory',
      );

      if (!mounted) return;

      final List<Map<String, dynamic>> contractorList =
          List<Map<String, dynamic>>.from(contractors);

      if (contractorList.isEmpty) {
        await _showContractorUidDialog(
          title: 'No contractors found',
          message:
              'No contractor profiles are available yet. Please ask your contractor to create their account first.',
          icon: Icons.person_search_rounded,
        );
        return;
      }

      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Select Contractor'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: contractorList.length,
                itemBuilder: (context, index) {
                  final contractor = contractorList[index];
                  final firstName = (contractor['first_name'] ?? '')
                      .toString()
                      .trim();
                  final lastName = (contractor['last_name'] ?? '')
                      .toString()
                      .trim();
                  final email = (contractor['email'] ?? '').toString().trim();

                  final name = '$firstName $lastName'.trim();
                  final displayName = name.isEmpty
                      ? 'Unnamed Contractor'
                      : name;

                  return ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
                    title: Text(displayName),
                    subtitle: email.isEmpty ? null : Text(email),
                    onTap: () => Navigator.pop(dialogContext, contractor),
                  );
                },
              ),
            ),
          );
        },
      );

      if (selected != null && mounted) {
        setState(() {
          _selectedContractorId = selected['id']?.toString();
          final firstName = (selected['first_name'] ?? '').toString().trim();
          final lastName = (selected['last_name'] ?? '').toString().trim();
          final name = '$firstName $lastName'.trim();
          _selectedContractorName = name.isEmpty ? 'Unnamed Contractor' : name;
        });
      }
    } catch (e, stackTrace) {
      debugPrint('════════ CONTRACTOR SELECTION FAILED ════════');
      debugPrint('ERROR TYPE: ${e.runtimeType}');
      debugPrint('ERROR: $e');
      debugPrint('STACK TRACE: $stackTrace');
      debugPrint('══════════════════════════════════════════════');

      if (mounted) {
        _showMessage(
          'Could not load contractors. Please try again.',
          isError: true,
        );
      }
    }
  }

  Future<void> _showContractorUidDialog({
    required String title,
    required String message,
    required IconData icon,
  }) async {
    if (!mounted) return;
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.071),
        ),
        backgroundColor: Colors.transparent,
        elevation: size.width * 0.0,
        child: Container(
          padding: EdgeInsets.all(size.width * 0.060),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1B3D3D),
                const Color(0xFF1B3D3D).withValues(alpha: 0.85),
              ],
            ),
            borderRadius: BorderRadius.circular(size.width * 0.071),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: size.width * 0.051,
                offset: Offset(size.width * 0.0, visibleHeight * 0.012),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: size.width * 0.112,
                    height: visibleHeight * 0.053,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6A050).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(size.width * 0.031),
                    ),
                    child: Icon(
                      icon,
                      color: const Color(0xFFE6A050),
                      size: size.width * 0.056,
                    ),
                  ),
                  SizedBox(width: size.width * 0.032),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: size.width * 0.046,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: visibleHeight * 0.018),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    height: visibleHeight * 0.0017,
                    fontSize: size.width * 0.036,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              SizedBox(height: visibleHeight * 0.020),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF1B3D3D),
                  ),
                  child: Text(
                    'Edit UID',
                    style: TextStyle(
                      color: const Color(0xFFE6A050),
                      fontWeight: FontWeight.w800,
                      fontSize: size.width * 0.038,
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

  void _showMessage(String msg, {bool isError = false}) {
    final size = MediaQuery.of(context).size;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError
            ? const Color(0xFF8B1E24)
            : const Color(0xFF1B3D3D),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.036),
        ),
        content: Text(
          msg,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: size.width * 0.036,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ✅ UI SECTION (Updated with RiskRadarLoader)
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    const Color tealColor = Color(0xFF1B3D3D);
    const Color goldColor = Color(0xFFE6A050);
    final headerHeight = visibleHeight * 0.275;
    final avatarSize = size.width * 0.33;
    final goldRimOffset = visibleHeight * 0.006;
    final horizontalPadding = size.width * 0.077;
    final hasRoleDetails = _role == _workerRole || _role == _safetyRole;
    final fieldGap = visibleHeight * (hasRoleDetails ? 0.012 : 0.022);
    final formTopGap = visibleHeight * (hasRoleDetails ? 0.026 : 0.070);
    final dobTopGap = visibleHeight * (hasRoleDetails ? 0.018 : 0.031);
    final buttonTopGap = visibleHeight * (hasRoleDetails ? 0.026 : 0.050);
    final postButtonGap = visibleHeight * (hasRoleDetails ? 0.008 : 0.018);
    final buttonHeight = visibleHeight * 0.061;
    final titleFont = size.width * 0.060;
    final subtitleFont = size.width * 0.035;
    final labelFont = size.width * 0.038;
    final iconSize = size.width * 0.056;

    if (_isLoadingProfile) {
      // ✅ REPLACED: Full Screen Loader
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: RiskRadarLoader(size: size.width * 0.205, color: tealColor),
        ),
      );
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: Colors.white,
        resizeToAvoidBottomInset: true,

        body: ListView(
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            // 1. HEADER SECTION
            SizedBox(
              height: headerHeight + (avatarSize / 2) - (visibleHeight * 0.020),
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  Positioned(
                    top: goldRimOffset,
                    left: size.width * 0.0,
                    right: size.width * 0.0,
                    child: ClipPath(
                      clipper: ConcaveHeaderClipper(),
                      child: Container(height: headerHeight, color: goldColor),
                    ),
                  ),
                  ClipPath(
                    clipper: ConcaveHeaderClipper(),
                    child: Container(
                      height: headerHeight,
                      width: double.infinity,
                      color: tealColor,
                      padding: EdgeInsets.only(top: visibleHeight * 0.080),
                      child: Column(
                        children: [
                          Text(
                            "Setup Your Profile",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: titleFont,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: visibleHeight * 0.006),
                          Text(
                            "Complete your details to continue",
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: subtitleFont,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top:
                        headerHeight -
                        (avatarSize / 2) -
                        (visibleHeight * 0.030),
                    child: Stack(
                      children: [
                        Container(
                          height: avatarSize,
                          width: avatarSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            // ✅ UPDATED: Opacity
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: size.width * 0.038,
                                offset: Offset(
                                  size.width * 0.0,
                                  visibleHeight * 0.008,
                                ),
                              ),
                            ],
                          ),
                          padding: EdgeInsets.all(size.width * 0.010),
                          child: ClipOval(
                            child: _imageFile != null
                                ? Image.file(_imageFile!, fit: BoxFit.cover)
                                : Image.asset(
                                    'assets/default_user.png',
                                    fit: BoxFit.cover,
                                    errorBuilder: (c, o, s) => Container(
                                      color: Colors.grey.shade200,
                                      child: Icon(
                                        Icons.person,
                                        size: size.width * 0.154,
                                        color: Colors.grey.shade400,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        if (!_isProfileSaved)
                          Positioned(
                            bottom: visibleHeight * 0.006,
                            right: size.width * 0.013,
                            child: GestureDetector(
                              onTap: _showPicker,
                              child: Container(
                                padding: EdgeInsets.all(size.width * 0.020),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: goldColor,
                                ),
                                child: Icon(
                                  Icons.camera_alt,
                                  size: iconSize,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: formTopGap),

            // 2. FORM SECTION
            Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildCustomTextField(
                          _firstNameController,
                          "First Name",
                          Icons.person_outline,
                          action: TextInputAction.next,
                        ),
                      ),
                      SizedBox(width: size.width * 0.040),
                      Expanded(
                        child: _buildCustomTextField(
                          _lastNameController,
                          "Last Name",
                          Icons.person_outline,
                          action: TextInputAction.next,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: fieldGap),
                  _buildCustomTextField(
                    _emailController,
                    "Email",
                    Icons.email_outlined,
                    isEnabled: false,
                  ),
                  SizedBox(height: fieldGap),

                  _buildCustomDropdown("Select Role", _roles, _role, (value) {
                    setState(() {
                      _role = value;
                      _workType = null;
                      _hseDesignation = null;
                      _selectedContractorId = null;
                      _selectedContractorName = null;
                    });
                  }, Icons.work_outline),

                  if (hasRoleDetails) ...[
                    SizedBox(height: fieldGap),
                    InkWell(
                      onTap: _selectContractor,
                      borderRadius: BorderRadius.circular(size.width * 0.077),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.038,
                          vertical: visibleHeight * 0.018,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(
                            size.width * 0.077,
                          ),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.badge_outlined,
                              color: const Color(0xFF1B3D3D),
                              size: size.width * 0.056,
                            ),
                            SizedBox(width: size.width * 0.050),
                            Expanded(
                              child: Text(
                                _selectedContractorName ?? 'Select Contractor',
                                style: TextStyle(
                                  color: _selectedContractorName == null
                                      ? Colors.grey.shade500
                                      : const Color(0xFF1B3D3D),
                                  fontSize: size.width * 0.033,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: Colors.grey.shade500,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: fieldGap),
                    _buildCustomDropdown(
                      _role == _workerRole
                          ? "Trade / Work Type"
                          : "Safety Role",
                      _role == _workerRole ? _workTypes : _hseDesignations,
                      _role == _workerRole ? _workType : _hseDesignation,
                      (val) => setState(
                        () => _role == _workerRole
                            ? _workType = val
                            : _hseDesignation = val,
                      ),
                      Icons.category_outlined,
                    ),
                  ],

                  SizedBox(height: dobTopGap),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Date of Birth",
                      style: TextStyle(
                        color: tealColor,
                        fontWeight: FontWeight.w600,
                        fontSize: labelFont,
                      ),
                    ),
                  ),
                  SizedBox(height: visibleHeight * 0.013),

                  Row(
                    children: [
                      Expanded(
                        child: _buildCustomDropdown(
                          "Day",
                          _days,
                          _birthDay,
                          (val) => setState(() => _birthDay = val),
                          null,
                        ),
                      ),
                      SizedBox(width: size.width * 0.027),
                      Expanded(
                        child: _buildCustomDropdown(
                          "Month",
                          _months,
                          _birthMonth,
                          (val) => setState(() => _birthMonth = val),
                          null,
                        ),
                      ),
                      SizedBox(width: size.width * 0.027),
                      Expanded(
                        child: _buildCustomDropdown(
                          "Year",
                          _years,
                          _birthYear,
                          (val) => setState(() => _birthYear = val),
                          null,
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: buttonTopGap),

                  SizedBox(
                    width: double.infinity,
                    height: buttonHeight,
                    child: ElevatedButton(
                      onPressed: (_isSaving || _isProfileSaved)
                          ? null
                          : _onSave,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: goldColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(buttonHeight / 2),
                        ),
                        elevation: size.width * 0.021,
                        // ✅ UPDATED: Opacity
                        shadowColor: goldColor.withValues(alpha: 0.4),
                      ),
                      child: _isSaving
                          // ✅ REPLACED: Button Loader
                          ? RiskRadarLoader(
                              size: size.width * 0.062,
                              color: Colors.white,
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _isProfileSaved
                                      ? 'Profile Saved'
                                      : 'Complete Setup',
                                  style: TextStyle(
                                    fontSize: size.width * 0.041,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                if (!_isProfileSaved)
                                  SizedBox(width: size.width * 0.027),
                                if (!_isProfileSaved)
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    color: Colors.white,
                                    size: iconSize,
                                  ),
                              ],
                            ),
                    ),
                  ),
                  SizedBox(height: postButtonGap),
                  TextButton.icon(
                    onPressed: _isSaving ? null : _changeAccount,
                    style: TextButton.styleFrom(
                      foregroundColor: tealColor,
                      padding: EdgeInsets.symmetric(
                        horizontal: size.width * 0.046,
                        vertical: visibleHeight * 0.012,
                      ),
                    ),
                    icon: Icon(Icons.logout_rounded, size: size.width * 0.046),
                    label: Text(
                      'Change account',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: size.width * 0.036,
                      ),
                    ),
                  ),
                  SizedBox(height: visibleHeight * 0.033),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? type,
    bool isEnabled = true,
    TextInputAction? action,
  }) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(size.width * 0.077),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: TextField(
        controller: controller,
        keyboardType: type,
        inputFormatters: const [SanitizingTextInputFormatter()],
        textInputAction: action,
        enabled: isEnabled && !_isProfileSaved,
        scrollPadding: EdgeInsets.only(bottom: visibleHeight * 0.125),
        style: TextStyle(
          fontSize: size.width * 0.038,
          color: Colors.black87,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: EdgeInsets.only(
              left: size.width * 0.038,
              right: size.width * 0.026,
            ),
            child: Icon(
              icon,
              color: const Color(0xFF1B3D3D),
              size: size.width * 0.056,
            ),
          ),
          hintText: label,
          hintStyle: TextStyle(color: Colors.grey.shade500),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: visibleHeight * 0.018),
          filled: true,
          fillColor: Colors.transparent,
        ),
      ),
    );
  }

  Widget _buildCustomDropdown(
    String label,
    List<String> items,
    String? selectedValue,
    void Function(String?) onChanged,
    IconData? icon,
  ) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final leadingGap = size.width * 0.038;
    final iconTextGap = size.width * 0.050;
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(size.width * 0.077),
        border: Border.all(color: Colors.grey.shade200),
      ),
      padding: EdgeInsets.symmetric(horizontal: leadingGap),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selectedValue,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Colors.grey.shade500,
          ),
          hint: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  color: const Color(0xFF1B3D3D),
                  size: size.width * 0.056,
                ),
                SizedBox(width: iconTextGap),
              ],
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: size.width * 0.033,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          selectedItemBuilder: (_) => items
              .map(
                (e) => Row(
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        color: const Color(0xFF1B3D3D),
                        size: size.width * 0.056,
                      ),
                      SizedBox(width: iconTextGap),
                    ],
                    Expanded(
                      child: Text(
                        e,
                        style: TextStyle(
                          color: Colors.black87,
                          fontSize: size.width * 0.038,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              )
              .toList(),
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(size.width * 0.051),
          items: items
              .map(
                (e) => DropdownMenuItem(
                  value: e,
                  child: Text(
                    e,
                    style: TextStyle(
                      color: Colors.black87,
                      fontSize: size.width * 0.038,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: _isProfileSaved ? null : onChanged,
        ),
      ),
    );
  }
}

class ConcaveHeaderClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    var path = Path();
    final dip = size.height * 0.21;
    path.lineTo(size.width * 0.0, size.height - dip);
    var controlPoint = Offset(size.width * 0.5, size.height + (dip * 1.2));
    var endPoint = Offset(size.width, size.height - dip);
    path.quadraticBezierTo(
      controlPoint.dx,
      controlPoint.dy,
      endPoint.dx,
      endPoint.dy,
    );
    path.lineTo(size.width, size.height * 0.0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}
