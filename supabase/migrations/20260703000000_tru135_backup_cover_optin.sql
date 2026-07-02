-- TRU-135 (+ TRU-136 consent versioning): backup cover — owner opt-in and
-- lockbox/access capture.
--
-- Opt-in lives at the profile level (one property per customer profile; decided
-- with Tom 2026-07-03). Cover is free at MVP — no fee capture anywhere.
--
-- Sensitive access details (lockbox location, code) live in private.backup_access,
-- a schema NOT exposed by PostgREST, and are reachable only through:
--   * public.set_backup_cover / public.get_backup_access definer RPCs (the owner,
--     for their own row), and
--   * the founder cover-alert path (TRU-138), which reads via a service_role-only
--     definer function.
-- Storage is encrypted at rest (Supabase disk encryption). Column-level pgcrypto
-- (key in Vault) is a documented follow-up for defence against SQL-level reads.
--
-- Applied to the live DB via apply_migration; committed for version control.

alter table public.customer_profiles
  add column if not exists backup_cover_enabled boolean not null default false,
  -- Geo/zone eligibility ("only offer cover where we can realistically reach in
  -- time") — founder-managed simple flag for MVP, default on (launch area = Sydney).
  add column if not exists backup_cover_eligible boolean not null default true;

create schema if not exists private;

create table if not exists private.backup_access (
  customer_id                uuid primary key references public.customer_profiles(id) on delete cascade,
  external_storage_confirmed boolean not null,
  access_location            text not null,
  access_code                text not null,
  access_notes               text,
  consent_at                 timestamptz not null default now(),
  consent_version            text not null,
  updated_at                 timestamptz not null default now()
);
alter table private.backup_access enable row level security;
-- no policies: not reachable via the API; definer RPCs + service_role only.

-- Owner turns cover on (with full capture) or off. Enforces the TRU-135 invariant:
-- cover cannot be active without all of external-storage confirmation, access
-- detail, and explicit entry consent. Consent is re-stamped on every save.
create or replace function public.set_backup_cover(
  p_enable boolean,
  p_external_storage_confirmed boolean default false,
  p_access_location text default null,
  p_access_code text default null,
  p_access_notes text default null,
  p_consent boolean default false,
  p_consent_version text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  cp public.customer_profiles%rowtype;
begin
  select * into cp from public.customer_profiles where user_id = auth.uid();
  if not found then
    raise exception 'No customer profile for this account';
  end if;

  if not p_enable then
    -- Data minimisation: opting out deletes the stored access details entirely.
    delete from private.backup_access where customer_id = cp.id;
    update public.customer_profiles
       set backup_cover_enabled = false, updated_at = now()
     where id = cp.id;
    return jsonb_build_object('enabled', false);
  end if;

  if not cp.backup_cover_eligible then
    raise exception 'Backup cover is not available in your area yet';
  end if;
  if p_external_storage_confirmed is not true
     or nullif(trim(p_access_location), '') is null
     or nullif(trim(p_access_code), '') is null
     or p_consent is not true
     or nullif(trim(p_consent_version), '') is null then
    raise exception 'Backup cover needs the external-storage confirmation, access details and entry consent';
  end if;

  insert into private.backup_access
    (customer_id, external_storage_confirmed, access_location, access_code, access_notes, consent_at, consent_version, updated_at)
  values
    (cp.id, true, trim(p_access_location), trim(p_access_code), nullif(trim(p_access_notes), ''), now(), trim(p_consent_version), now())
  on conflict (customer_id) do update set
    external_storage_confirmed = excluded.external_storage_confirmed,
    access_location = excluded.access_location,
    access_code     = excluded.access_code,
    access_notes    = excluded.access_notes,
    consent_at      = excluded.consent_at,
    consent_version = excluded.consent_version,
    updated_at      = now();

  update public.customer_profiles
     set backup_cover_enabled = true, updated_at = now()
   where id = cp.id;
  return jsonb_build_object('enabled', true);
end;
$$;

revoke all on function public.set_backup_cover(boolean, boolean, text, text, text, boolean, text) from public, anon;
grant execute on function public.set_backup_cover(boolean, boolean, text, text, text, boolean, text) to authenticated;

-- The owner's own view of what they stored (prefill/edit in the profile UI).
-- Definer because the private schema is not API-exposed; scoped hard to auth.uid().
create or replace function public.get_backup_access()
returns table (access_location text, access_code text, access_notes text, consent_at timestamptz, consent_version text)
language sql security definer stable set search_path = public
as $$
  select ba.access_location, ba.access_code, ba.access_notes, ba.consent_at, ba.consent_version
  from private.backup_access ba
  join public.customer_profiles cp on cp.id = ba.customer_id
  where cp.user_id = auth.uid();
$$;

revoke all on function public.get_backup_access() from public, anon;
grant execute on function public.get_backup_access() to authenticated;
