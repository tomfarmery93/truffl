-- TRU-110: booking request context for walkers.
--
-- When a request lands, give the walker the efficiency signals the ticket asks
-- for: how far the job is from home, and whether it slots next to a walk they
-- already have that day ("you're already walking 0.9km away at 2pm"). This is
-- the supply-side twin of the TRU-154 search ranking and rides the same geo
-- groundwork (customer_profiles.location, provider locations, PostGIS).
--
-- Privacy: definer fn; only the request's own walker (or the service role, for
-- the future email enhancement) can call it, and only distances + the walker's
-- own booking details leave the DB — never another customer's coordinates.
--
-- Applied to the live DB via apply_migration; committed for version control.

create or replace function public.booking_request_context(p_booking_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  b public.bookings%rowtype;
  pp public.provider_profiles%rowtype;
  req_loc geography;
  result jsonb;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return null; end if;
  select * into pp from provider_profiles where id = b.provider_id;
  -- The request's own walker only. A service_role call carries no uid (allowed);
  -- anon has EXECUTE revoked below.
  if auth.uid() is not null and pp.user_id is distinct from auth.uid() then
    raise exception 'Not authorised';
  end if;
  select cp.location into req_loc from customer_profiles cp where cp.id = b.customer_id;

  select jsonb_build_object(
    'distance_from_home_km',
      case when pp.location is not null and req_loc is not null
           then round((st_distance(pp.location, req_loc) / 1000.0)::numeric, 1) end,
    'same_day', coalesce((
      select jsonb_agg(jsonb_build_object(
               'scheduled_at', o.scheduled_at,
               'pet_name', o.pet_name,
               'distance_km', o.distance_km) order by o.distance_km)
      from (
        select ob.scheduled_at, p.name as pet_name,
               round((st_distance(ocp.location, req_loc) / 1000.0)::numeric, 1) as distance_km
        from bookings ob
        join customer_profiles ocp on ocp.id = ob.customer_id
        left join pets p on p.id = ob.pet_id
        where ob.provider_id = b.provider_id
          and ob.id <> b.id
          and ob.status in ('confirmed', 'in_progress')
          and not coalesce(ob.is_meet_and_greet, false)
          and (ob.scheduled_at at time zone 'Australia/Sydney')::date
              = (b.scheduled_at at time zone 'Australia/Sydney')::date
          and ocp.location is not null
          and req_loc is not null
        order by st_distance(ocp.location, req_loc)
        limit 3
      ) o
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke all on function public.booking_request_context(uuid) from public, anon;
grant execute on function public.booking_request_context(uuid) to authenticated, service_role;
