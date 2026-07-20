-- TRU-226: capture leads from the BOTTOM of a non-empty results list, flagged by source.
--
-- The TRU-216 capture flow only triggered on zero-result searches. An owner who scrolls a
-- full list and thinks "still not it" is an equally valuable lead — but the flag matters:
-- that lead exists DESPITE available carers (a fit/quality gap), not because of a supply
-- gap. So:
--   • carer_requests.capture_trigger records the source (named capture_trigger, not
--     "trigger" — TRIGGER is a SQL keyword and unquoted use invites tooling papercuts):
--       no_carers       — true area-zero (default; also all pre-existing rows)
--       filtered_out    — carers exist but the owner's filters excluded them all
--       browsed_unhappy — saw the list, clicked "Can't see an option that suits you?"
--   • carer_requests.results_seen — how many carers the search returned (server-side
--     count, pre client filters). Per-suburb supply-QUALITY signal for recruitment.
--   • submit_carer_request replaced (dropped + recreated, never overloaded — PostgREST
--     named-arg dispatch 300s on ambiguous overloads) with p_trigger + p_results_seen,
--     both defaulted so the cached live page keeps working between migration and deploy.
--
-- Applied to the live DB via apply_migration (Supabase branching is broken on this repo);
-- committed here for version control (see TRU-145). 14-digit unique prefix.

alter table public.carer_requests
  add column if not exists capture_trigger text not null default 'no_carers'
    check (capture_trigger in ('no_carers','filtered_out','browsed_unhappy')),
  add column if not exists results_seen int;

drop function if exists public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb,text,text,text,text,text,text[]);

create function public.submit_carer_request(
  p_suburb          text    default null,
  p_service_type    text    default null,
  p_wanted_date     date    default null,
  p_recurring       boolean default false,
  p_window_start    text    default null,
  p_window_end      text    default null,
  p_dog_size        text    default null,
  p_puppy           boolean default false,
  p_pet_id          uuid    default null,
  p_contact_name    text    default null,
  p_contact_email   text    default null,
  p_note            text    default null,
  p_search_params   jsonb   default null,
  p_contact_phone   text    default null,
  p_dog_name        text    default null,
  p_dog_breed       text    default null,
  p_dog_temperament text    default null,
  p_frequency       text    default null,
  p_preferred_times text[]  default null,
  p_trigger         text    default 'no_carers',
  p_results_seen    int     default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_customer_id uuid;
  v_pet_id      uuid := null;
  v_phone       text;
  v_frequency   text;
  v_trigger     text;
  v_times       text[];
  v_id          uuid;
begin
  select cp.id into v_customer_id
  from public.customer_profiles cp
  where cp.user_id = auth.uid();

  -- The founder call is the product: every lead needs a phone number.
  v_phone := nullif(trim(coalesce(p_contact_phone, '')), '');
  if v_phone is null then
    raise exception 'contact_phone is required';
  end if;

  -- Guests must also leave an email (confirmation email + account invite).
  if v_customer_id is null and coalesce(trim(p_contact_email), '') = '' then
    raise exception 'contact_email is required for guest requests';
  end if;

  -- Only accept a pet_id that actually belongs to the caller (defends the assign path).
  if p_pet_id is not null and v_customer_id is not null then
    select pt.id into v_pet_id
    from public.pets pt
    where pt.id = p_pet_id and pt.customer_id = v_customer_id;
  end if;

  -- Whitelist enumerated inputs rather than trusting the client.
  v_frequency := nullif(trim(coalesce(p_frequency, '')), '');
  if v_frequency is not null
     and v_frequency not in ('one_off','weekly','few_per_week','daily') then
    raise exception 'invalid frequency %', v_frequency;
  end if;
  v_trigger := coalesce(nullif(trim(coalesce(p_trigger, '')), ''), 'no_carers');
  if v_trigger not in ('no_carers','filtered_out','browsed_unhappy') then
    raise exception 'invalid trigger %', v_trigger;
  end if;
  v_times := (
    select coalesce(array_agg(t), '{}')
    from unnest(coalesce(p_preferred_times, '{}')) as t
    where t in ('morning','midday','afternoon','evening')
  );

  insert into public.carer_requests (
    customer_id, pet_id, contact_name, contact_email, contact_phone, suburb, service_type,
    wanted_date, recurring, window_start, window_end, dog_size, puppy,
    dog_name, dog_breed, dog_temperament_note, frequency, preferred_times,
    capture_trigger, results_seen, note, search_params
  ) values (
    v_customer_id, v_pet_id,
    nullif(trim(coalesce(p_contact_name, '')), ''),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    v_phone,
    nullif(trim(coalesce(p_suburb, '')), ''),
    nullif(trim(coalesce(p_service_type, '')), ''),
    p_wanted_date, coalesce(p_recurring, false),
    nullif(trim(coalesce(p_window_start, '')), ''),
    nullif(trim(coalesce(p_window_end, '')), ''),
    nullif(trim(coalesce(p_dog_size, '')), ''),
    coalesce(p_puppy, false),
    nullif(trim(coalesce(p_dog_name, '')), ''),
    nullif(trim(coalesce(p_dog_breed, '')), ''),
    nullif(trim(coalesce(p_dog_temperament, '')), ''),
    v_frequency, v_times,
    v_trigger, p_results_seen,
    nullif(trim(coalesce(p_note, '')), ''),
    p_search_params
  ) returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb,text,text,text,text,text,text[],text,int) from public;
grant execute on function public.submit_carer_request(text,text,date,boolean,text,text,text,boolean,uuid,text,text,text,jsonb,text,text,text,text,text,text[],text,int) to anon, authenticated;
