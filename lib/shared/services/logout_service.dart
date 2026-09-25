import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LogoutService {
  LogoutService._();

  static Future<void> signOut() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;

    if (user == null) {
      await client.auth.signOut();
      return;
    }

    final userId = user.id;

    // IMPORTANT:
    // Remove push-notification ownership while the Supabase session
    // is still authenticated. After auth.signOut(), RLS can no longer
    // authorize these operations.
    try {
      await Future.wait([
        client.from('user_fcm_tokens').delete().eq('user_id', userId),

        client.from('officers').update({'fcm_token': null}).eq('id', userId),

        client.from('workers').update({'fcm_token': null}).eq('id', userId),

        client.from('hse_workers').update({'fcm_token': null}).eq('id', userId),
      ]);

      debugPrint('✅ [Logout] FCM ownership cleared for current user.');
    } catch (e) {
      // Token cleanup should not permanently prevent the user
      // from signing out.
      debugPrint('⚠️ [Logout] FCM cleanup failed: $e');
    }

    // Sign out only after authenticated backend cleanup was attempted.
    await client.auth.signOut();

    debugPrint('✅ [Logout] Supabase session signed out.');
  }
}
