-- Harden direct access to user_fcm_tokens.
--
-- Token registration is handled by the register_fcm_token() SECURITY DEFINER
-- RPC. Flutter does not directly read or update token rows.
--
-- Keep DELETE access for the authenticated user's own row because the current
-- logout flow removes FCM ownership before signing out.

drop policy if exists "user_fcm_tokens_insert_own"
on public.user_fcm_tokens;

drop policy if exists "user_fcm_tokens_select_own"
on public.user_fcm_tokens;

drop policy if exists "user_fcm_tokens_update_own"
on public.user_fcm_tokens;
