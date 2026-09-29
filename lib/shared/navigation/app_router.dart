import 'package:flutter/material.dart';

import '../../auth/auth_wrapper.dart';
import '../../auth/login_screen.dart';
import '../../auth/reset_password_screen.dart';
import '../../auth/signup_screen.dart';
import '../../officers/settings/edit_officer_profile_screen.dart';
import '../../officers/settings/officer_view_profile_screen.dart';
import '../../workers/settings/worker_view_profile_screen.dart';
import '../../workers/tabs/ai_image.dart';
import '../screens/profile_setup_screen.dart';

class AppRouter {
  const AppRouter._();

  static Map<String, WidgetBuilder> routes({
    required ThemeMode currentThemeMode,
    required ValueChanged<ThemeMode> onThemeChanged,
  }) {
    return {
      '/': (_) => AuthWrapper(
        currentThemeMode: currentThemeMode,
        onThemeChanged: onThemeChanged,
      ),
      '/login': (_) => const LoginScreen(),
      '/signup': (_) => const SignupScreen(),
      '/reset-password': (_) => const ResetPasswordScreen(),
      '/profile-setup': (_) => const ProfileSetupScreen(),
      '/officer-profile-setup': (_) => const EditOfficerProfileScreen(),
      '/officer-view-profile': (_) => const OfficerViewProfileScreen(),
      '/worker-view-profile': (_) => const WorkerEditProfileScreen(),
      '/hazard-scanner': (_) => const HazardScreen(),
    };
  }

  static Route<dynamic> onUnknownRoute(RouteSettings settings) {
    return MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Page Not Found')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 80,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(height: 24),
                Text(
                  '404',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade700,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Page not found: ${settings.name}',
                  style: const TextStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pushReplacementNamed(context, '/'),
                  icon: const Icon(Icons.home),
                  label: const Text('Go Home'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
