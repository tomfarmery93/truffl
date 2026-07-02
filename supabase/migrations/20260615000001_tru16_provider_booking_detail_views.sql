-- TRU-16: surface the info a provider needs to do the job. Providers can't read
-- customer_profiles / users / pets directly under RLS, so expose just what's needed via
-- definer views scoped to the caller's bookings (same pattern as booking_party_names).

-- Contact + location, one row per booking. Suburb is always visible to the provider so
-- they can judge the service area; the full street address + contact numbers are withheld
-- until the booking is accepted (the customer always sees their own).
create view public.booking_contact_details as
select
  b.id as booking_id,
  b.status,
  cp.suburb,
  case when cp.user_id = auth.uid() or b.status in ('confirmed','in_progress','completed') then cp.address end as address,
  case when cp.user_id = auth.uid() or b.status in ('confirmed','in_progress','completed') then cp.postcode end as postcode,
  case when cp.user_id = auth.uid() or b.status in ('confirmed','in_progress','completed') then cu.phone end as customer_phone,
  case when cp.user_id = auth.uid() or b.status in ('confirmed','in_progress','completed') then cp.emergency_contact end as emergency_contact,
  case when cp.user_id = auth.uid() or b.status in ('confirmed','in_progress','completed') then cp.emergency_phone end as emergency_phone
from public.bookings b
join public.customer_profiles cp on cp.id = b.customer_id
join public.users cu on cu.id = cp.user_id
join public.provider_profiles pp on pp.id = b.provider_id
where cp.user_id = auth.uid() or pp.user_id = auth.uid();

grant select on public.booking_contact_details to anon, authenticated, service_role;

-- Pet care details, one row per pet on the booking (covers multi-pet booking_pets, with a
-- fallback to the legacy single bookings.pet_id). Always visible to the booking's parties.
create view public.booking_pet_care as
select b.id as booking_id, p.id as pet_id, p.name, p.breed, p.species, p.sex, p.age_years, p.weight_kg,
       p.vet_name, p.vet_phone, p.medical_notes, p.behaviour_notes
from public.bookings b
join public.booking_pets bpx on bpx.booking_id = b.id
join public.pets p on p.id = bpx.pet_id
join public.customer_profiles cp on cp.id = b.customer_id
join public.provider_profiles pp on pp.id = b.provider_id
where cp.user_id = auth.uid() or pp.user_id = auth.uid()
union
select b.id, p.id, p.name, p.breed, p.species, p.sex, p.age_years, p.weight_kg,
       p.vet_name, p.vet_phone, p.medical_notes, p.behaviour_notes
from public.bookings b
join public.pets p on p.id = b.pet_id
join public.customer_profiles cp on cp.id = b.customer_id
join public.provider_profiles pp on pp.id = b.provider_id
where (cp.user_id = auth.uid() or pp.user_id = auth.uid())
  and not exists (select 1 from public.booking_pets bpx where bpx.booking_id = b.id);

grant select on public.booking_pet_care to anon, authenticated, service_role;
