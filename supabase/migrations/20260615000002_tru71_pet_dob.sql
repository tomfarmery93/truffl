-- TRU-71: store pets' date of birth instead of a static age, so age stays accurate over time.

alter table public.pets add column dob date;

-- Backfill: derive an approximate DOB from the old static age so today's computed age matches.
update public.pets set dob = (current_date - (age_years * interval '1 year'))::date
where age_years is not null;

-- booking_pet_care exposed age_years; recreate it to expose dob plus a *derived* (dynamic)
-- age_years so existing consumers keep working but the value now ages correctly.
drop view public.booking_pet_care;
alter table public.pets drop column age_years;

create view public.booking_pet_care as
select b.id as booking_id, p.id as pet_id, p.name, p.breed, p.species, p.sex,
       p.dob,
       (case when p.dob is not null then greatest(0, extract(year from age(p.dob))::int) end) as age_years,
       p.weight_kg, p.vet_name, p.vet_phone, p.medical_notes, p.behaviour_notes
from public.bookings b
join public.booking_pets bpx on bpx.booking_id = b.id
join public.pets p on p.id = bpx.pet_id
join public.customer_profiles cp on cp.id = b.customer_id
join public.provider_profiles pp on pp.id = b.provider_id
where cp.user_id = auth.uid() or pp.user_id = auth.uid()
union
select b.id, p.id, p.name, p.breed, p.species, p.sex,
       p.dob,
       (case when p.dob is not null then greatest(0, extract(year from age(p.dob))::int) end) as age_years,
       p.weight_kg, p.vet_name, p.vet_phone, p.medical_notes, p.behaviour_notes
from public.bookings b
join public.pets p on p.id = b.pet_id
join public.customer_profiles cp on cp.id = b.customer_id
join public.provider_profiles pp on pp.id = b.provider_id
where (cp.user_id = auth.uid() or pp.user_id = auth.uid())
  and not exists (select 1 from public.booking_pets bpx where bpx.booking_id = b.id);

grant select on public.booking_pet_care to anon, authenticated, service_role;
