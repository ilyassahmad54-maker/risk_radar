// lib/app_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:riskradar/shared/theme/app_colors.dart';
import 'package:riskradar/shared/services/logout_service.dart';

// Import your existing screens
import 'officer_emergency_details_screen.dart';

/// Shared Settings screen
class AppSettingsScreen extends StatelessWidget {
  final void Function(BuildContext) onAboutTap;
  final void Function(ThemeMode) onThemeChanged;
  final void Function() onProfileTap;
  final ThemeMode currentThemeMode;

  const AppSettingsScreen({
    super.key,
    required this.onAboutTap,
    required this.onThemeChanged,
    required this.currentThemeMode,
    required this.onProfileTap,
  });

  // -------------------
  // Sign Out Helper
  // -------------------
  Future<void> _handleSignOut(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          padding: EdgeInsets.all(R.blockH * 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.brandTeal,
                AppColors.brandTeal.withValues(alpha: 0.85),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.all(R.blockH * 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              SizedBox(height: R.blockV * 2.5),
              Text(
                'Confirm Logout',
                style: TextStyle(
                  fontSize: R.blockH * 5.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: R.blockV * 1.5),
              Text(
                'Are you sure you want to log out of RiskRadar?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: R.blockH * 3.75,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              SizedBox(height: R.blockV * 3.5),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: R.blockH * 4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(width: R.blockH * 3.2),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.brandTeal,
                      padding: EdgeInsets.symmetric(
                        horizontal: R.blockH * 6,
                        vertical: R.blockV * 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 4,
                    ),
                    child: Text(
                      'Logout',
                      style: TextStyle(
                        fontSize: R.blockH * 4,
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

    if (confirm == true && context.mounted) {
      try {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Logging out...')));
        await LogoutService.signOut();
        if (context.mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Logout failed: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    R.init(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      },
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
        body: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: R.blockH * 4,
                vertical: R.blockV * 1.5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Profile Card
                  _CompactSettingsTile(
                    icon: Icons.person_outline,
                    title: 'Profile',
                    onTap: onProfileTap,
                  ),
                  SizedBox(height: R.blockV * 2),

                  // Emergency Details Card
                  _CompactSettingsTile(
                    icon: Icons.warning_amber_outlined,
                    iconColor: Colors.red,
                    title: 'Emergency Details',
                    onTap: () {
                      final user = Supabase.instance.client.auth.currentUser;
                      if (user != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => OfficerEmergencyDetailsScreen(
                              officerId: user.id,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  SizedBox(height: R.blockV * 2),

                  // Theme Toggle Card
                  _CompactSettingsTile(
                    icon: Icons.color_lens_outlined,
                    title: isDark ? 'Dark Mode' : 'Light Mode',
                    enableTileTap: true,
                    trailing: Switch.adaptive(
                      value: isDark,
                      onChanged: (value) => onThemeChanged(
                        value ? ThemeMode.dark : ThemeMode.light,
                      ),
                      activeThumbColor: AppColors.accentGold,
                      activeTrackColor: AppColors.brandTeal.withValues(
                        alpha: 0.65,
                      ),
                      inactiveThumbColor: Colors.white,
                      inactiveTrackColor: const Color(0xFF355F67),
                    ),
                    onTap: () {
                      onThemeChanged(isDark ? ThemeMode.light : ThemeMode.dark);
                    },
                  ),
                  SizedBox(height: R.blockV * 2),

                  // Notifications
                  _CompactSettingsTile(
                    icon: Icons.notifications_outlined,
                    title: 'Notifications',
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Notification settings coming soon',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: AppColors.brandTeal,
                      ),
                    ),
                  ),
                  SizedBox(height: R.blockV * 2),

                  // Privacy
                  _CompactSettingsTile(
                    icon: Icons.security_outlined,
                    title: 'Privacy & Security',
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Privacy settings coming soon',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: AppColors.brandTeal,
                      ),
                    ),
                  ),
                  SizedBox(height: R.blockV * 2),

                  // About
                  _CompactSettingsTile(
                    icon: Icons.info_outline,
                    title: 'About App',
                    onTap: () => onAboutTap(context),
                  ),
                  SizedBox(height: R.blockV * 4),

                  // Sign Out Button
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFE53845), Color(0xFFB0002C)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFFFF295F,
                          ).withValues(alpha: 0.35),
                          blurRadius: 14,
                          spreadRadius: 1,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => _handleSignOut(context),
                      icon: Icon(Icons.logout, size: 22),
                      label: Text(
                        'Sign Out',
                        style: TextStyle(
                          fontSize: R.blockH * 4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: R.blockV * 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------
// Compact Settings Tile Widget
// -----------------------------------------------------------
class _CompactSettingsTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool enableTileTap;

  const _CompactSettingsTile({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.onTap,
    this.trailing,
    this.enableTileTap = true,
  });

  @override
  Widget build(BuildContext context) {
    R.init(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBase = isDark
        ? Color.lerp(AppColors.brandTeal, Colors.black, 0.35)!
        : AppColors.brandTeal;

    return InkWell(
      onTap: enableTileTap ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: R.blockH * 4,
          vertical: R.blockV * 2.25,
        ),
        decoration: BoxDecoration(
          color: cardBase,
          border: Border.all(
            color: isDark
                ? AppColors.surfaceTeal.withValues(alpha: 0.8)
                : AppColors.brandTeal.withValues(alpha: 0.22),
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? Colors.white, size: 26),
            SizedBox(width: R.blockH * 4.267),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: R.blockH * 4,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
            if (trailing != null)
              trailing!
            else
              Icon(Icons.chevron_right, color: Colors.white70, size: 24),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------
// Theme Toggle Widget (Optimized for smaller size)
// -----------------------------------------------------------
