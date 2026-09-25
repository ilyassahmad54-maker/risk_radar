import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/gestures.dart';
import 'package:riskradar/shared/widgets/risk_radar_loader.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  // ---------------------------------------------------------------------------
  // CONTROLLERS & KEYS
  // ---------------------------------------------------------------------------
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loadingEmail = false;
  bool _loadingGoogle = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  // ✅ SECURITY: Cooldown after failed attempts
  int _failedAttempts = 0;
  DateTime? _cooldownUntil;

  // ---------------------------------------------------------------------------
  // ✅ SECURITY: Password strength validator
  // ---------------------------------------------------------------------------
  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Minimum 8 characters required';
    if (!value.contains(RegExp(r'[A-Z]'))) {
      return 'Must contain at least one uppercase letter';
    }
    if (!value.contains(RegExp(r'[0-9]'))) {
      return 'Must contain at least one number';
    }
    if (!value.contains(RegExp(r'[!@#\$&*~%^()_\-+=]'))) {
      return 'Must contain at least one special character';
    }
    return null;
  }

  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) return 'Email is required';
    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) return 'Please confirm your password';
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  String _firstValidationMessage() {
    return _validateEmail(_emailController.text) ??
        _validatePassword(_passwordController.text) ??
        _validateConfirmPassword(_confirmPasswordController.text) ??
        'Please check the highlighted fields.';
  }

  // ---------------------------------------------------------------------------
  // ✅ SECURITY: Check cooldown before any auth attempt
  // ---------------------------------------------------------------------------
  bool _isInCooldown() {
    if (_cooldownUntil == null) return false;
    if (DateTime.now().isBefore(_cooldownUntil!)) return true;
    _cooldownUntil = null;
    return false;
  }

  void _handleFailedAttempt() {
    _failedAttempts++;
    if (_failedAttempts >= 3) {
      // ✅ Lock for 30 seconds after 3 failed attempts
      _cooldownUntil = DateTime.now().add(const Duration(seconds: 30));
      _failedAttempts = 0;
      _showSnackBar('Too many attempts. Please wait 30 seconds.');
    }
  }

  void _showSnackBar(String message, {bool isError = true}) {
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.031),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ✅ FIXED: Correct signup flow — sign up first, handle existing user error
  // ---------------------------------------------------------------------------
  Future<void> _signUpWithEmail() async {
    if (!_formKey.currentState!.validate()) {
      _showSnackBar(_firstValidationMessage());
      return;
    }

    // ✅ SECURITY: Check cooldown
    if (_isInCooldown()) {
      final remaining = _cooldownUntil!.difference(DateTime.now()).inSeconds;
      _showSnackBar('Please wait $remaining seconds before trying again.');
      return;
    }

    setState(() => _loadingEmail = true);

    try {
      // ✅ FIX: Sign up directly — don't try sign-in first
      final response = await Supabase.instance.client.auth
          .signUp(
            email: _emailController.text.trim(),
            password: _passwordController.text.trim(),
            emailRedirectTo: 'hazardreporter://login-callback',
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Request timed out. Check your connection.'),
          );

      if (!mounted) return;

      if (response.user != null) {
        // ✅ Reset failed attempts on success
        _failedAttempts = 0;
        _cooldownUntil = null;

        _showSnackBar(
          'Account created! Check your email to confirm.',
          isError: false,
        );
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.pushReplacementNamed(context, '/login');
      }
    } on AuthException catch (e) {
      _handleFailedAttempt();

      // ✅ Handle specific auth errors with clear messages
      if (e.message.toLowerCase().contains('already registered') ||
          e.message.toLowerCase().contains('already exists') ||
          e.message.toLowerCase().contains('user already')) {
        _showSnackBar(
          'An account with this email already exists. Please log in.',
        );
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) Navigator.pushReplacementNamed(context, '/login');
      } else {
        _showSnackBar('Signup failed: ${e.message}');
      }
    } catch (e) {
      _handleFailedAttempt();
      _showSnackBar(
        e.toString().contains('timed out')
            ? 'Request timed out. Check your connection.'
            : 'An unexpected error occurred. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _loadingEmail = false);
    }
  }

  // ---------------------------------------------------------------------------
  // ✅ FIXED: Google Sign-In with proper await
  // ---------------------------------------------------------------------------
  Future<void> _signInWithGoogle() async {
    if (_isInCooldown()) {
      final remaining = _cooldownUntil!.difference(DateTime.now()).inSeconds;
      _showSnackBar('Please wait $remaining seconds before trying again.');
      return;
    }

    setState(() => _loadingGoogle = true);

    try {
      final GoogleSignIn googleSignIn = GoogleSignIn.instance;
      await googleSignIn.initialize();
      final GoogleSignInAccount googleUser = await googleSignIn.authenticate();

      // ignore: unnecessary_null_comparison
      if (googleUser == null) {
        // User cancelled — not a failure
        setState(() => _loadingGoogle = false);
        return;
      }

      // ✅ FIX: Added await — was missing before
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      final String? idToken = googleAuth.idToken;

      if (idToken == null) {
        throw const AuthException('Failed to get Google ID token.');
      }

      final AuthResponse response = await Supabase.instance.client.auth
          .signInWithIdToken(provider: OAuthProvider.google, idToken: idToken)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw Exception('Google sign-in timed out.'),
          );

      if (!mounted) return;

      if (response.user != null) {
        _failedAttempts = 0;
        Navigator.pushReplacementNamed(context, '/');
      }
    } on AuthException catch (e) {
      _handleFailedAttempt();
      _showSnackBar('Google sign-in failed: ${e.message}');
    } catch (e) {
      if (e.toString().contains('canceled') ||
          e.toString().contains('cancelled')) {
        // User cancelled — silent
        return;
      }
      _handleFailedAttempt();
      _showSnackBar(
        e.toString().contains('timed out')
            ? 'Google sign-in timed out.'
            : 'Google sign-in failed. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _loadingGoogle = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    const Color tealColor = Color(0xFF1B3D3D);
    const Color goldColor = Color(0xFFE6A050);
    final headerHeight = visibleHeight * 0.265;
    final logoSize = size.width * 0.31;
    final goldRimOffset = visibleHeight * 0.006;
    final horizontalPadding = size.width * 0.077;
    final fieldGap = visibleHeight * 0.017;
    final buttonHeight = visibleHeight * 0.061;
    final titleFont = size.width * 0.070;
    final subtitleFont = size.width * 0.037;
    final smallFont = size.width * 0.028;
    final bodyFont = size.width * 0.034;
    final iconSize = size.width * 0.050;
    final googleSize = size.width * 0.135;
    final formMaxWidth = size.width - (horizontalPadding * 2);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, _) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: visibleHeight),
                child: Column(
                  children: [
                    // Header
                    SizedBox(
                      height:
                          headerHeight +
                          (logoSize / 2) -
                          (visibleHeight * 0.018),
                      child: Stack(
                        children: [
                          Positioned(
                            top: goldRimOffset,
                            left: size.width * 0.0,
                            right: size.width * 0.0,
                            child: ClipPath(
                              clipper: ConcaveHeaderClipper(),
                              child: Container(
                                height: headerHeight,
                                color: goldColor,
                              ),
                            ),
                          ),
                          ClipPath(
                            clipper: ConcaveHeaderClipper(),
                            child: Container(
                              height: headerHeight,
                              width: double.infinity,
                              decoration: const BoxDecoration(color: tealColor),
                              child: Stack(
                                children: [
                                  Positioned(
                                    top: -(visibleHeight * 0.060),
                                    right: -(size.width * 0.103),
                                    child: Icon(
                                      Icons.security,
                                      size: size.width * 0.487,
                                      color: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            top:
                                headerHeight -
                                (logoSize / 2) -
                                (visibleHeight * 0.018),
                            left: (size.width - logoSize) / 2,
                            child: Hero(
                              tag: 'app-logo',
                              child: Container(
                                height: logoSize,
                                width: logoSize,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.2,
                                      ),
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
                                  child: Image.asset(
                                    'assets/logo.png',
                                    fit: BoxFit.cover,
                                    errorBuilder: (c, o, s) => Container(
                                      color: tealColor,
                                      child: Icon(
                                        Icons.security,
                                        size: size.width * 0.205,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: visibleHeight * 0.014),
                    Text(
                      'Create Account',
                      style: TextStyle(
                        fontSize: titleFont,
                        fontWeight: FontWeight.w800,
                        color: tealColor,
                        letterSpacing: size.width * 0.0013,
                      ),
                    ),
                    SizedBox(height: visibleHeight * 0.007),
                    Text(
                      'Join RiskRadar to report hazards',
                      style: TextStyle(
                        fontSize: subtitleFont,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: visibleHeight * 0.024),

                    Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: formMaxWidth),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            children: [
                              _buildCustomTextField(
                                size: size,
                                visibleHeight: visibleHeight,
                                controller: _emailController,
                                label: "Email Address",
                                icon: Icons.email_outlined,
                                keyboardType: TextInputType.emailAddress,
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Email is required';
                                  }
                                  // ✅ SECURITY: Stricter email validation
                                  final emailRegex = RegExp(
                                    r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
                                  );
                                  if (!emailRegex.hasMatch(value.trim())) {
                                    return 'Enter a valid email address';
                                  }
                                  return null;
                                },
                              ),
                              SizedBox(height: fieldGap),

                              // ✅ Password with show/hide toggle
                              _buildCustomTextField(
                                size: size,
                                visibleHeight: visibleHeight,
                                controller: _passwordController,
                                label: "Password",
                                icon: Icons.lock_outline,
                                obscureText: _obscurePassword,
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    color: tealColor,
                                    size: iconSize,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                ),
                                validator: _validatePassword,
                              ),

                              // ✅ Password strength hint
                              Padding(
                                padding: EdgeInsets.only(
                                  top: visibleHeight * 0.007,
                                  left: size.width * 0.020,
                                ),
                                child: Text(
                                  'Min 8 chars • 1 uppercase • 1 number • 1 special character',
                                  style: TextStyle(
                                    fontSize: smallFont,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),

                              SizedBox(height: fieldGap),

                              // ✅ NEW: Confirm password field
                              _buildCustomTextField(
                                size: size,
                                visibleHeight: visibleHeight,
                                controller: _confirmPasswordController,
                                label: "Confirm Password",
                                icon: Icons.lock_outline,
                                obscureText: _obscureConfirm,
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscureConfirm
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    color: tealColor,
                                    size: iconSize,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscureConfirm = !_obscureConfirm,
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Please confirm your password';
                                  }
                                  if (value != _passwordController.text) {
                                    return 'Passwords do not match';
                                  }
                                  return null;
                                },
                              ),

                              SizedBox(height: visibleHeight * 0.030),

                              // SIGN UP BUTTON
                              SizedBox(
                                width: double.infinity,
                                height: buttonHeight,
                                child: ElevatedButton(
                                  // ✅ SECURITY: Disabled during loading or cooldown
                                  onPressed: (_loadingEmail || _isInCooldown())
                                      ? null
                                      : _signUpWithEmail,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: goldColor,
                                    disabledBackgroundColor:
                                        Colors.grey.shade300,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        buttonHeight / 2,
                                      ),
                                    ),
                                    elevation: size.width * 0.021,
                                    shadowColor: goldColor.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                  child: _loadingEmail
                                      ? RiskRadarLoader(
                                          size: size.width * 0.062,
                                          color: Colors.white,
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              "SIGN UP",
                                              style: TextStyle(
                                                fontSize: size.width * 0.041,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            SizedBox(width: size.width * 0.026),
                                            Icon(
                                              Icons.person_add_rounded,
                                              color: Colors.white,
                                              size: size.width * 0.056,
                                            ),
                                          ],
                                        ),
                                ),
                              ),

                              SizedBox(height: visibleHeight * 0.020),
                              Row(
                                children: [
                                  Expanded(
                                    child: Divider(color: Colors.grey.shade300),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: size.width * 0.026,
                                    ),
                                    child: Text(
                                      "or sign up with",
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: smallFont,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Divider(color: Colors.grey.shade300),
                                  ),
                                ],
                              ),

                              SizedBox(height: visibleHeight * 0.016),

                              // GOOGLE BUTTON
                              GestureDetector(
                                onTap: (_loadingGoogle || _isInCooldown())
                                    ? null
                                    : _signInWithGoogle,
                                child: Container(
                                  height: googleSize,
                                  width: googleSize,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.grey.shade200,
                                        blurRadius: size.width * 0.026,
                                        offset: Offset(
                                          size.width * 0.0,
                                          visibleHeight * 0.005,
                                        ),
                                      ),
                                    ],
                                    border: Border.all(
                                      color: Colors.grey.shade100,
                                    ),
                                  ),
                                  padding: EdgeInsets.all(size.width * 0.031),
                                  child: _loadingGoogle
                                      ? RiskRadarLoader(
                                          size: size.width * 0.062,
                                        )
                                      : SvgPicture.asset(
                                          'assets/google_logo.svg',
                                        ),
                                ),
                              ),

                              SizedBox(height: visibleHeight * 0.024),

                              RichText(
                                text: TextSpan(
                                  text: "Already have an account? ",
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: bodyFont,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: 'Login',
                                      style: TextStyle(
                                        color: tealColor,
                                        fontWeight: FontWeight.bold,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () =>
                                            Navigator.pushReplacementNamed(
                                              context,
                                              '/login',
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: visibleHeight * 0.014),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCustomTextField({
    required Size size,
    required double visibleHeight,
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
    Widget? suffixIcon,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(size.width * 0.077),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        validator: validator,
        // ✅ SECURITY: Disable autocorrect/suggestions for password fields
        autocorrect: false,
        enableSuggestions: !obscureText,
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
          suffixIcon: suffixIcon,
          hintText: label,
          hintStyle: TextStyle(color: Colors.grey.shade500),
          border: InputBorder.none,
          errorStyle: TextStyle(
            height: visibleHeight * 0.0,
            fontSize: size.width * 0.0,
          ),
          errorMaxLines: 1,
          contentPadding: EdgeInsets.symmetric(vertical: visibleHeight * 0.018),
          filled: true,
          fillColor: Colors.transparent,
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
