-- TRU-156 (search stage 2): travel-time service areas.
--
-- A carer can now set "up to N minutes from home" instead of a crow-flies
-- radius. The isochrone polygon is computed ONCE per settings save (geo-api
-- edge function → OpenRouteService) and stored on the profile; search stays
-- pure PostGIS — ST_Covers against the polygon when present, radius fallback
-- otherwise — so there are no per-search API calls and no search-UI changes.
-- This fixes the crow-flies failure at Sydney's water crossings (Manly ↔
-- Watsons Bay: ~5km straight line, 45+ min by road).
--
-- The ORS API key lives in private.geo_config, populated OUT OF BAND (not in
-- git), same pattern as private.email_config / stripe_config:
--   insert into private.geo_config (id, ors_api_key) values (1, '<key>')
--   on conflict (id) do update set ors_api_key = excluded.ors_api_key;
--
-- Applied to the live DB via apply_migration; committed for version control.

alter table public.provider_profiles
  add column if not exists travel_time_mins integer,
  add column if not exists service_area geography(MultiPolygon,4326);
create index if not exists idx_provider_service_area
  on public.provider_profiles using gist (service_area);

create table if not exists private.geo_config (
  id int primary key default 1,
  ors_api_key text not null,
  enabled boolean not null default true,
  constraint geo_config_single_row check (id = 1)
);
alter table private.geo_config enable row level security;
-- no policies: read only via the service_role getter below.

-- If a carer moves suburb, the stored polygon is stale: clear it so search
-- falls back to the radius until they re-save their service area.
-- (In the geocode trigger's table this column doesn't exist for customers, so
-- this is a separate provider-only trigger; plain row trigger because
-- UPDATE-OF lists don't see columns modified by other BEFORE triggers.)
create or replace function public.trg_provider_area_stale()
returns trigger language plpgsql as $$
begin
  if NEW.location is distinct from OLD.location then
    NEW.service_area := null;
  end if;
  return NEW;
end;
$$;
revoke execute on function public.trg_provider_area_stale() from public, anon, authenticated;
drop trigger if exists provider_area_stale on public.provider_profiles;
create trigger provider_area_stale
  before update on public.provider_profiles
  for each row execute function public.trg_provider_area_stale();

-- ── geo-api helpers (service_role only — the edge fn authenticates the carer
--    itself via auth.getUser, then acts through these) ─────────────────────────
create or replace function public.get_geo_config()
returns text language sql stable security definer set search_path = public as $$
  select ors_api_key from private.geo_config where id = 1 and enabled;
$$;
revoke all on function public.get_geo_config() from public, anon, authenticated;
grant execute on function public.get_geo_config() to service_role;

create or replace function public.provider_lnglat(p_user_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when location is null then null
    else jsonb_build_array(st_x(location::geometry), st_y(location::geometry)) end
  from public.provider_profiles where user_id = p_user_id;
$$;
revoke all on function public.provider_lnglat(uuid) from public, anon, authenticated;
grant execute on function public.provider_lnglat(uuid) to service_role;

-- Store the isochrone and return the covered-suburb preview in one round trip.
create or replace function public.apply_service_area(p_user_id uuid, p_geojson jsonb, p_minutes integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  g geography;
  covered jsonb;
begin
  g := st_multi(st_setsrid(st_geomfromgeojson(p_geojson::text), 4326))::geography;
  update public.provider_profiles
     set service_area = g, travel_time_mins = p_minutes, updated_at = now()
   where user_id = p_user_id;
  select coalesce(jsonb_agg(s.name order by st_distance(s.centroid, pp.location)), '[]'::jsonb)
    into covered
  from public.provider_profiles pp
  join public.suburbs s on st_covers(pp.service_area, s.centroid)
  where pp.user_id = p_user_id;
  return jsonb_build_object('mode', 'travel', 'minutes', p_minutes, 'covered', covered);
end;
$$;
revoke all on function public.apply_service_area(uuid, jsonb, integer) from public, anon, authenticated;
grant execute on function public.apply_service_area(uuid, jsonb, integer) to service_role;

create or replace function public.apply_radius_area(p_user_id uuid, p_radius_km integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare covered jsonb;
begin
  update public.provider_profiles
     set radius_km = p_radius_km, travel_time_mins = null, service_area = null, updated_at = now()
   where user_id = p_user_id;
  select coalesce(jsonb_agg(s.name order by st_distance(s.centroid, pp.location)), '[]'::jsonb)
    into covered
  from public.provider_profiles pp
  join public.suburbs s on st_dwithin(s.centroid, pp.location, p_radius_km * 1000)
  where pp.user_id = p_user_id;
  return jsonb_build_object('mode', 'radius', 'radius_km', p_radius_km, 'covered', covered);
end;
$$;
revoke all on function public.apply_radius_area(uuid, integer) from public, anon, authenticated;
grant execute on function public.apply_radius_area(uuid, integer) to service_role;

-- Current coverage for the carer's own settings card (works for either mode).
create or replace function public.my_service_area_suburbs()
returns table (name text, distance_km numeric)
language sql stable security definer set search_path = public as $$
  select s.name, round((st_distance(s.centroid, pp.location) / 1000.0)::numeric, 1)
  from public.provider_profiles pp
  join public.suburbs s on (
    (pp.service_area is not null and st_covers(pp.service_area, s.centroid))
    or (pp.service_area is null and st_dwithin(s.centroid, pp.location, greatest(coalesce(pp.radius_km, 5), 1) * 1000))
  )
  where pp.user_id = (select auth.uid()) and pp.location is not null
  order by 2
  limit 80;
$$;
revoke all on function public.my_service_area_suburbs() from public, anon;
grant execute on function public.my_service_area_suburbs() to authenticated;

-- ── Search: polygon first, radius fallback (signature + outputs unchanged) ────
create or replace function public.search_carers(
  p_suburb text default null,
  p_postcode text default null,
  p_date date default null
) returns table (
  id uuid, user_id uuid, first_name text, last_name text, avatar_url text,
  bio text, suburb text, radius_km integer, is_verified boolean, is_active boolean,
  avg_rating numeric, total_reviews integer, services json, created_at timestamptz,
  distance_km numeric, nearby_same_day boolean
)
language sql stable security definer set search_path = public as $$
  with pt as (
    select public.suburb_centroid(p_suburb, p_postcode) as g
  )
  select pp.id, pp.user_id, u.first_name, u.last_name, u.avatar_url,
    pp.bio, pp.suburb, pp.radius_km, pp.is_verified, pp.is_active,
    pp.avg_rating, pp.total_reviews,
    coalesce(json_agg(ps.service_type order by ps.service_type)
             filter (where ps.service_type is not null), '[]'::json) as services,
    pp.created_at,
    case when (select g from pt) is not null and pp.location is not null
         then round((st_distance(pp.location, (select g from pt)) / 1000.0)::numeric, 1)
    end as distance_km,
    case when p_date is not null and (select g from pt) is not null then exists (
      select 1
      from public.bookings b
      join public.customer_profiles cp on cp.id = b.customer_id
      where b.provider_id = pp.id
        and b.status in ('confirmed', 'in_progress')
        and not coalesce(b.is_meet_and_greet, false)
        and (b.scheduled_at at time zone 'Australia/Sydney')::date = p_date
        and cp.location is not null
        and st_dwithin(cp.location, (select g from pt), 3000)
    ) else false end as nearby_same_day
  from public.provider_profiles pp
  join public.users u on u.id = pp.user_id
  left join public.provider_services ps on ps.provider_id = pp.user_id and ps.is_available = true
  where pp.is_active = true
    and (
      nullif(trim(coalesce(p_suburb, '')), '') is null
      or ((select g from pt) is not null and pp.location is not null and (
            (pp.service_area is not null and st_covers(pp.service_area, (select g from pt)))
            or (pp.service_area is null
                and st_dwithin(pp.location, (select g from pt), greatest(coalesce(pp.radius_km, 5), 1) * 1000))
          ))
      or (((select g from pt) is null or pp.location is null)
          and pp.suburb ilike '%' || p_suburb || '%')
    )
  group by pp.id, pp.user_id, u.first_name, u.last_name, u.avatar_url, pp.bio,
           pp.suburb, pp.radius_km, pp.is_verified, pp.is_active, pp.avg_rating,
           pp.total_reviews, pp.created_at, pp.location, pp.service_area
  order by nearby_same_day desc, distance_km asc nulls last, pp.avg_rating desc nulls last
$$;
revoke all on function public.search_carers(text, text, date) from public;
grant execute on function public.search_carers(text, text, date) to anon, authenticated;
