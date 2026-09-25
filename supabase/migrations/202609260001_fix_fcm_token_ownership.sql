-- ============================================================
-- RiskRadar
-- Fix FCM token ownership
--
-- Guarantees:
--   1. One token belongs to at most one authenticated user.
--   2. One user has at most one registered token row.
--   3. A device token can safely move between accounts.
--   4. Token registration is performed server-side through
--      register_fcm_token().
-- ============================================================


-- ------------------------------------------------------------
-- 1. Remove duplicate ownership of the same FCM token.
--    Keep the newest row.
-- ------------------------------------------------------------

with ranked_tokens as (
  select
    id,
    row_number() over (
      partition by fcm_token
      order by updated_at desc, created_at desc, id desc
    ) as rn
  from public.user_fcm_tokens
)
delete from public.user_fcm_tokens
where id in (
  select id
  from ranked_tokens
  where rn > 1
);


-- ------------------------------------------------------------
-- 2. Guarantee that one FCM token cannot belong to multiple
--    users.
--
--    The live database may already contain this constraint,
--    therefore make the migration safe to apply there too.
-- ------------------------------------------------------------

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'user_fcm_tokens_fcm_token_key'
      and conrelid = 'public.user_fcm_tokens'::regclass
  ) then
    alter table public.user_fcm_tokens
      add constraint user_fcm_tokens_fcm_token_key
      unique (fcm_token);
  end if;
end
$$;


-- ------------------------------------------------------------
-- 3. Secure token registration RPC.
--
--    SECURITY DEFINER is intentional:
--    normal RLS prevents one user from deleting another user's
--    stale ownership row. This function allows the current
--    authenticated device token to move safely to the currently
--    authenticated account.
-- ------------------------------------------------------------

create or replace function public.register_fcm_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'FCM token cannot be empty';
  end if;

  -- Remove this device token from any previous account.
  delete from public.user_fcm_tokens
  where fcm_token = p_token
    and user_id <> v_user_id;

  -- Register it to the currently authenticated account.
  insert into public.user_fcm_tokens (
    user_id,
    fcm_token
  )
  values (
    v_user_id,
    p_token
  )
  on conflict (user_id)
  do update
  set
    fcm_token = excluded.fcm_token,
    updated_at = now();
end;
$$;


-- ------------------------------------------------------------
-- 4. Restrict RPC execution.
-- ------------------------------------------------------------

revoke all
on function public.register_fcm_token(text)
from public;

grant execute
on function public.register_fcm_token(text)
to authenticated;