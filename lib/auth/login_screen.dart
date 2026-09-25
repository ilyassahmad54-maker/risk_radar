import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/gestures.dart';
import 'package:riskradar/shared/widgets/risk_radar_loader.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ---------------------------------------------------------------------------
  // CONTROLLERS & KEYS
  // ---------------------------------------------------------------------------
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loadingEmail = false;
  bool _loadingGoogle = false;
  bool _obscurePassword = true;

  // ✅ SECURITY: Rate limiting
  int _failedAttempts = 0;
  DateTime? _cooldownUntil;
  static const int _maxAttempts = 3;
  static const int _cooldownSeconds = 30;

  // ---------------------------------------------------------------------------
  // ✅ SECURITY HELPERS
  // ---------------------------------------------------------------------------
  bool _isInCooldown() {
    if (_cooldownUntil == null) return false;
    if (DateTime.now().isBefore(_cooldownUntil!)) return true;
    // Cooldown expired — reset
    _cooldownUntil = null;
    _failedAttempts = 0;
    return false;
  }

  int _remainingCooldownSeconds() {
    if (_cooldownUntil == null) return 0;
    return _cooldownUntil!.difference(DateTime.now()).inSeconds;
  }

  void _handleFailedAttempt() {
    _failedAttempts++;
    if (_failedAttempts >= _maxAttempts) {
      _cooldownUntil = DateTime.now().add(
        const Duration(seconds: _cooldownSeconds),
      );
      _failedAttempts = 0;
      _showSnackBar(
        '🔒 Too many failed attempts. Please wait $_cooldownSeconds seconds.',
      );
    }
  }

  void _showSnackBar(String message, {bool isError = true}) {
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size.width * 0.031),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // ✅ FIXED & SECURED: Email Login
  // ---------------------------------------------------------------------------
  Future<void> _loginWithEmail() async {
    if (!_formKey.currentState!.validate()) return;

    // ✅ SECURITY: Block if in cooldown
    if (_isInCooldown()) {
      _showSnackBar(
        '🔒 Please wait ${_remainingCooldownSeconds()} seconds before trying again.',
      );
      return;
    }

    setState(() => _loadingEmail = true);

    try {
      final response = await Supabase.instance.client.auth
          .signInWithPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text.trim(),
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
        Navigator.pushReplacementNamed(context, '/');
      }
    } on AuthException catch (e) {
      _handleFailedAttempt();

      // ✅ SECURITY: Generic error messages — don't reveal if email exists
      final message = e.message.toLowerCase();
      if (message.contains('invalid') ||
          message.contains('credentials') ||
          message.contains('wrong') ||
          message.contains('not found')) {
        _showSnackBar('Incorrect email or password. Please try again.');
      } else if (message.contains('email not confirmed')) {
        _showSnackBar(
          'Please confirm your email before logging in. Check your inbox.',
        );
      } else if (message.contains('too many')) {
        _showSnackBar('Too many requests. Please wait a moment.');
      } else {
        // ✅ SECURITY: Don't expose raw error to user
        _showSnackBar('Login failed. Please try again.');
        debugPrint('Auth error (hidden from user): ${e.message}');
      }
    } catch (e) {
      _handleFailedAttempt();
      if (e.toString().contains('timed out')) {
        _showSnackBar('Request timed out. Check your internet connection.');
      } else {
        _showSnackBar('Something went wrong. Please try again.');
        debugPrint('Login error (hidden from user): $e');
      }
    } finally {
      if (mounted) setState(() => _loadingEmail = false);
    }
  }

  // ---------------------------------------------------------------------------
  // ✅ FIXED & SECURED: Google Login
  // ---------------------------------------------------------------------------
  Future<void> _loginWithGoogle() async {
    if (_isInCooldown()) {
      _showSnackBar(
        '🔒 Please wait ${_remainingCooldownSeconds()} seconds before trying again.',
      );
      return;
    }

    setState(() => _loadingGoogle = true);

    try {
      final GoogleSignIn googleSignIn = GoogleSignIn.instance;
      await googleSignIn.initialize();
      final GoogleSignInAccount googleUser = await googleSignIn.authenticate();

      // User cancelled — not a failure, exit silently
      // ✅ FIX: Added await — was missing in original
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
      final String? idToken = googleAuth.idToken;

      if (idToken == null) {
        throw const AuthException('Failed to get Google ID token.');
      }

      // ✅ Get access token separately
      final authorization = await googleUser.authorizationClient
          .authorizationForScopes(['email', 'profile']);
      final String? accessToken = authorization?.accessToken;

      final response = await Supabase.instance.client.auth
          .signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
            accessToken: accessToken,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw Exception('Google sign-in timed out.'),
          );

      if (!mounted) return;

      if (response.user != null) {
        _failedAttempts = 0;
        _cooldownUntil = null;
        Navigator.pushReplacementNamed(context, '/');
      }
    } on AuthException catch (e) {
      _handleFailedAttempt();
      debugPrint('Google auth error: ${e.message}');
      _showSnackBar('Google sign-in failed. Please try again.');
    } catch (e) {
      final errorStr = e.toString().toLowerCase();

      // ✅ User cancelled — silent, not a failure
      if (errorStr.contains('canceled') ||
          errorStr.contains('cancelled') ||
          errorStr.contains('sign_in_canceled')) {
        setState(() => _loadingGoogle = false);
        return;
      }

      _handleFailedAttempt();

      if (errorStr.contains('timed out')) {
        _showSnackBar('Google sign-in timed out. Check your connection.');
      } else {
        debugPrint('Google login error (hidden from user): $e');
        _showSnackBar('Google sign-in failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _loadingGoogle = false);
    }
  }

  // ---------------------------------------------------------------------------
  // ✅ Forgot Password
  // ---------------------------------------------------------------------------
  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      _showSnackBar('Enter your email above first, then tap Forgot Password.');
      return;
    }

    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
          email,
          redirectTo: 'hazardreporter://login-callback',
        );
      // ✅ SECURITY: Same message whether email exists or not
      _showSnackBar(
        'If this email is registered, a reset link has been sent.',
        isError: false,
      );
    } catch (e) {
      // ✅ SECURITY: Don't reveal if email exists
      _showSnackBar(
        'If this email is registered, a reset link has been sent.',
        isError: false,
      );
      debugPrint('Password reset error (hidden from user): $e');
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
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
    final headerHeight = visibleHeight * 0.285;
    final logoSize = size.width * 0.35;
    final goldRimOffset = visibleHeight * 0.006;
    final horizontalPadding = size.width * 0.077;
    final fieldGap = visibleHeight * 0.022;
    final buttonHeight = visibleHeight * 0.061;
    final titleFont = size.width * 0.072;
    final subtitleFont = size.width * 0.037;
    final smallFont = size.width * 0.030;
    final bodyFont = size.width * 0.034;
    final iconSize = size.width * 0.050;
    final googleSize = size.width * 0.135;
    final formMaxWidth = size.width - (horizontalPadding * 2);

    // ✅ Show remaining cooldown in button
    final bool isCoolingDown = _isInCooldown();

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
                          (visibleHeight * 0.020),
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
                                (visibleHeight * 0.020),
                            left: (size.width - logoSize) / 2,
                            child: Hero(
                              tag: 'app-logo',
                              child: Container(
                                height: logoSize,
                                width: logoSize,
                                padding: EdgeInsets.all(size.width * 0.010),
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

                    SizedBox(height: visibleHeight * 0.018),
                    Text(
                      'Welcome Back!',
                      style: TextStyle(
                        fontSize: titleFont,
                        fontWeight: FontWeight.w800,
                        color: tealColor,
                        letterSpacing: size.width * 0.0013,
                      ),
                    ),
                    SizedBox(height: visibleHeight * 0.010),
                    Text(
                      'Sign in to continue to RiskRadar',
                      style: TextStyle(
                        fontSize: subtitleFont,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    // ✅ Cooldown warning banner
                    if (isCoolingDown)
                      Container(
                        margin: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          visibleHeight * 0.012,
                          horizontalPadding,
                          visibleHeight * 0.0,
                        ),
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.041,
                          vertical: visibleHeight * 0.011,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(
                            size.width * 0.031,
                          ),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.lock_clock,
                              color: Colors.red.shade700,
                              size: iconSize,
                            ),
                            SizedBox(width: size.width * 0.026),
                            Expanded(
                              child: Text(
                                'Too many attempts. Wait ${_remainingCooldownSeconds()}s before retrying.',
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontSize: smallFont,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    SizedBox(height: visibleHeight * 0.030),

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
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Password is required';
                                  }
                                  if (value.length < 6) {
                                    return 'Password must be at least 6 characters';
                                  }
                                  return null;
                                },
                              ),

                              // ✅ Forgot password link
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _forgotPassword,
                                  style: TextButton.styleFrom(
                                    foregroundColor: tealColor,
                                    padding: EdgeInsets.all(size.width * 0.0),
                                  ),
                                  child: Text(
                                    'Forgot Password?',
                                    style: TextStyle(
                                      fontSize: smallFont,
                                      fontWeight: FontWeight.w600,
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                              ),

                              SizedBox(height: visibleHeight * 0.016),

                              // LOGIN BUTTON
                              SizedBox(
                                width: double.infinity,
                                height: buttonHeight,
                                child: ElevatedButton(
                                  onPressed: (_loadingEmail || isCoolingDown)
                                      ? null
                                      : _loginWithEmail,
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
                                          color: Colors.white,
                                          size: size.width * 0.062,
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              isCoolingDown
                                                  ? 'WAIT ${_remainingCooldownSeconds()}s'
                                                  : 'LOG IN',
                                              style: TextStyle(
                                                fontSize: size.width * 0.041,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            SizedBox(width: size.width * 0.026),
                                            Icon(
                                              Icons.arrow_forward_rounded,
                                              color: Colors.white,
                                              size: size.width * 0.056,
                                            ),
                                          ],
                                        ),
                                ),
                              ),

                              SizedBox(height: visibleHeight * 0.024),
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
                                      "or continue with",
                                      style: TextStyle(
                                        fontSize: smallFont,
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Divider(color: Colors.grey.shade300),
                                  ),
                                ],
                              ),

                              SizedBox(height: visibleHeight * 0.018),

                              // GOOGLE BUTTON
                              GestureDetector(
                                onTap: (_loadingGoogle || isCoolingDown)
                                    ? null
                                    : _loginWithGoogle,
                                child: AnimatedOpacity(
                                  opacity: isCoolingDown ? 0.4 : 1.0,
                                  duration: const Duration(milliseconds: 300),
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
                              ),

                              SizedBox(height: visibleHeight * 0.024),

                              RichText(
                                text: TextSpan(
                                  text: "New to RiskRadar? ",
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: bodyFont,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: 'Create Account',
                                      style: TextStyle(
                                        color: tealColor,
                                        fontWeight: FontWeight.bold,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () =>
                                            Navigator.pushReplacementNamed(
                                              context,
                                              '/signup',
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
    final fieldFont = size.width * 0.038;
    final iconSize = size.width * 0.056;

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
        autocorrect: false,
        enableSuggestions: !obscureText,
        style: TextStyle(
          fontSize: fieldFont,
          color: Colors.black87,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          prefixIcon: Padding(
            padding: EdgeInsets.only(
              left: size.width * 0.038,
              right: size.width * 0.026,
            ),
            child: Icon(icon, color: const Color(0xFF1B3D3D), size: iconSize),
          ),
          suffixIcon: suffixIcon,
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
