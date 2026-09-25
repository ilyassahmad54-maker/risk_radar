// lib/worker_app_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:riskradar/shared/theme/app_colors.dart';
import '../settings/worker_sites_screen.dart';
import '../settings/worker_emergency_details_screen.dart';
import 'package:riskradar/shared/services/logout_service.dart';

class WorkerAppSettingsScreen extends StatelessWidget {
  final void Function(BuildContext) onAboutTap;
  final void Function(ThemeMode) onThemeChanged;
  final void Function() onProfileTap;
  final ThemeMode currentThemeMode;

  const WorkerAppSettingsScreen({
    super.key,
    required this.onAboutTap,
    required this.onThemeChanged,
    required this.currentThemeMode,
    required this.onProfileTap,
  });

  void _showInfoSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.brandTeal,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showErrorSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleSignOut(BuildContext context) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final mediaQuery = MediaQuery.of(ctx);
        final size = mediaQuery.size;
        final visibleHeight =
            size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
        return Dialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: size.width * 0.085,
            vertical: visibleHeight * 0.030,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(size.width * 0.071),
          ),
          backgroundColor: Colors.transparent,
          elevation: size.width * 0.0,
          child: Container(
            padding: EdgeInsets.all(size.width * 0.048),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  AppColors.brandTeal,
                  AppColors.brandTeal.withValues(alpha: 0.85),
                ],
              ),
              borderRadius: BorderRadius.circular(size.width * 0.071),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: size.width * 0.053,
                  offset: Offset(size.width * 0.0, visibleHeight * 0.013),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding: EdgeInsets.all(size.width * 0.032),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.logout_rounded,
                    color: Colors.white,
                    size: size.width * 0.074,
                  ),
                ),
                SizedBox(height: visibleHeight * 0.018),
                Text(
                  'Confirm Logout',
                  style: TextStyle(
                    fontSize: size.width * 0.050,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: visibleHeight * 0.010),
                Text(
                  'Are you sure you want to log out of RiskRadar?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: size.width * 0.035,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                SizedBox(height: visibleHeight * 0.024),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
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
                        foregroundColor: AppColors.brandTeal,
                        padding: EdgeInsets.symmetric(
                          horizontal: size.width * 0.064,
                          vertical: visibleHeight * 0.011,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            size.width * 0.041,
                          ),
                        ),
                        elevation: size.width * 0.011,
                      ),
                      child: Text(
                        'Logout',
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
        );
      },
    );

    if (confirm == true && context.mounted) {
      try {
        _showInfoSnackBar(context, 'Logging out...');
        await LogoutService.signOut();

        if (context.mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
        }
      } catch (e) {
        if (context.mounted) {
          _showErrorSnackBar(context, 'Logout failed: $e');
        }
      }
    }
  }

  void _onChangeSiteTap(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WorkerSitesScreen()),
    );
  }

  void _onEmergencyDetailsTap(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => WorkerEmergencyDetailsScreen(
          workerId: Supabase.instance.client.auth.currentUser!.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: size.width * 0.040,
              vertical: visibleHeight * 0.010,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _CompactSettingsTile(
                  icon: Icons.person_outline,
                  title: 'Profile',
                  subtitle: 'View and update your personal details',
                  onTap: onProfileTap,
                ),
                SizedBox(height: visibleHeight * 0.014),
                _CompactSettingsTile(
                  icon: Icons.warning_amber_outlined,
                  iconColor: Colors.red.shade200,
                  title: 'Emergency Details',
                  subtitle: 'View or update emergency contacts and info',
                  onTap: () => _onEmergencyDetailsTap(context),
                ),
                SizedBox(height: visibleHeight * 0.014),
                _CompactSettingsTile(
                  icon: Icons.location_on_outlined,
                  title: 'Change Current Site',
                  subtitle: 'Select or switch your active work site',
                  onTap: () => _onChangeSiteTap(context),
                ),
                SizedBox(height: visibleHeight * 0.014),
                _CompactSettingsTile(
                  icon: Icons.color_lens_outlined,
                  title: isDark ? 'Dark Mode' : 'Light Mode',
                  subtitle: 'Adjust RiskRadar appearance',
                  enableTileTap: false,
                  trailing: ThemeToggle(
                    isDark: isDark,
                    onChanged: (bool value) {
                      onThemeChanged(value ? ThemeMode.dark : ThemeMode.light);
                    },
                  ),
                  onTap: () {},
                ),
                SizedBox(height: visibleHeight * 0.014),
                _CompactSettingsTile(
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  subtitle: 'Manage notification preferences',
                  onTap: () => _showInfoSnackBar(
                    context,
                    'Notification settings coming soon',
                  ),
                ),
                SizedBox(height: visibleHeight * 0.014),
                _CompactSettingsTile(
                  icon: Icons.security_outlined,
                  title: 'Privacy & Security',
                  subtitle: 'Change password and privacy options',
                  onTap: () => _showInfoSnackBar(
                    context,
                    'Privacy settings coming soon',
                  ),
                ),
                SizedBox(height: visibleHeight * 0.014),
                _CompactSettingsTile(
                  icon: Icons.info_outline,
                  title: 'About App',
                  subtitle: 'Learn more about this application',
                  onTap: () => onAboutTap(context),
                ),
                SizedBox(height: visibleHeight * 0.026),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Colors.red.shade600, Colors.red.shade800],
                    ),
                    borderRadius: BorderRadius.circular(size.width * 0.036),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.red.shade600.withValues(alpha: 0.32),
                        blurRadius: size.width * 0.037,
                        spreadRadius: size.width * 0.003,
                        offset: Offset(size.width * 0.0, visibleHeight * 0.008),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      minimumSize: Size(double.infinity, visibleHeight * 0.060),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(size.width * 0.036),
                      ),
                    ),
                    onPressed: () => _handleSignOut(context),
                    icon: Icon(Icons.logout, size: size.width * 0.053),
                    label: Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: size.width * 0.037,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: visibleHeight * 0.014),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSettingsTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool enableTileTap;

  const _CompactSettingsTile({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.enableTileTap = true,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final Color cardBase = isDark
        ? Color.lerp(AppColors.brandTeal, Colors.black, 0.35)!
        : AppColors.brandTeal;

    return InkWell(
      onTap: enableTileTap ? onTap : null,
      borderRadius: BorderRadius.circular(size.width * 0.031),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: size.width * 0.040,
          vertical: visibleHeight * 0.015,
        ),
        decoration: BoxDecoration(
          color: cardBase,
          border: Border.all(
            color: isDark
                ? AppColors.surfaceTeal.withValues(alpha: 0.8)
                : AppColors.brandTeal.withValues(alpha: 0.22),
          ),
          borderRadius: BorderRadius.circular(size.width * 0.031),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
              blurRadius: size.width * 0.027,
              offset: Offset(size.width * 0.0, visibleHeight * 0.005),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              color: iconColor ?? Colors.white,
              size: size.width * 0.064,
            ),
            SizedBox(width: size.width * 0.035),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: size.width * 0.039,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: visibleHeight * 0.003),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: size.width * 0.029,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.74),
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else
              Icon(
                Icons.chevron_right,
                color: Colors.white70,
                size: size.width * 0.060,
              ),
          ],
        ),
      ),
    );
  }
}

class ThemeToggle extends StatelessWidget {
  final bool isDark;
  final ValueChanged<bool> onChanged;

  const ThemeToggle({super.key, required this.isDark, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final size = mediaQuery.size;
    final visibleHeight =
        size.height - mediaQuery.padding.top - mediaQuery.padding.bottom;
    final trackLight = Colors.grey.shade300;
    final trackDark = Colors.grey.shade800;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!isDark),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: size.width * 0.205,
        height: visibleHeight * 0.041,
        padding: EdgeInsets.symmetric(horizontal: size.width * 0.012),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [trackDark, Colors.black54]
                : [trackLight, Colors.white],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(size.width * 0.064),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: size.width * 0.011,
              offset: Offset(size.width * 0.0, visibleHeight * 0.003),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: size.width * 0.020),
                child: Icon(
                  Icons.wb_sunny_rounded,
                  size: size.width * 0.046,
                  color: isDark ? Colors.white30 : Colors.orangeAccent.shade700,
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: size.width * 0.020),
                child: Icon(
                  Icons.nightlight_round,
                  size: size.width * 0.046,
                  color: isDark ? Colors.indigoAccent.shade100 : Colors.black26,
                ),
              ),
            ),
            AnimatedAlign(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              alignment: isDark ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: size.width * 0.078,
                height: visibleHeight * 0.036,
                decoration: BoxDecoration(
                  color: isDark
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: size.width * 0.011,
                      offset: Offset(size.width * 0.0, visibleHeight * 0.003),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    isDark ? Icons.nightlight_round : Icons.wb_sunny_rounded,
                    size: size.width * 0.041,
                    color: isDark ? Colors.white : Colors.orangeAccent.shade700,
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
