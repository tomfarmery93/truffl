-- Supply-side Phase 2, invoices for own clients (GitHub #166, E2).
--
-- Decision (September 2026): own-client money stays off Truffl. An invoice here is a record
-- and a document, never a payment: it carries the carer's own bank details or PayID, the
-- client pays them directly, and the carer marks it paid. No Stripe, no card collection.
--
-- Shape:
--   * invoice_settings   one row per carer: trading name, ABN, whether they are GST registered,
--                        how to pay them, numbering prefix and counter, default due days.
--   * invoices           numbered per carer (INV-0001, ...), one client each, totals, status
--                        unpaid / paid / void, a share token for the public page. The issuer
--                        block (name, ABN, bank details) is snapshotted at creation so a later
--                        settings change never rewrites a document already sent.
--   * invoice_items      the lines: usually one per completed job (jobs.invoice_id points back,
--                        so a job is on at most one live invoice), plus free-text lines.
--   * create_invoice     allocates the next number under a row lock, snapshots the jobs, works
--                        out GST. Prices in Australia are quoted GST-inclusive, so for a
--                        registered carer the GST line is total / 11, not 10% on top.
--   * invoice_public     anon-callable definer RPC behind the token, same pattern as walk_report.
--   * set_invoice_paid   paid / unpaid, cascading to the jobs on it (the client book's owed
--                        balance reads jobs.paid_at). void_invoice frees the jobs again.

-- ── 1. Settings ─────────────────────────────────────────────────────────────
create table if not exists public.invoice_settings (
  provider_user_id  uuid primary key references public.users(id) on delete cascade,
  business_name     text,
  abn               text,
  gst_registered    boolean not null default false,
  address           text,
  email             text,
  phone             text,
  bank_account_name text,
  bank_bsb          text,
  bank_account      text,
  payid             text,
  payment_notes     text,                              -- "Cash on the day is fine too"
  invoice_prefix    text not null default 'INV-',
  next_number       integer not null default 1 check (next_number > 0),
  due_days          integer not null default 7 check (due_days between 0 and 90),
  footer_note       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
drop trigger if exists set_invoice_settings_updated_at on public.invoice_settings;
create trigger set_invoice_settings_updated_at before update on public.invoice_settings
  for each row execute function public.set_updated_at();

alter table public.invoice_settings enable row level security;
drop policy if exists invoice_settings_owner_all on public.invoice_settings;
create policy invoice_settings_owner_all on public.invoice_settings
  for all using (provider_user_id = (select auth.uid())) with check (provider_user_id = (select auth.uid()));
revoke all on public.invoice_settings from public, anon;
grant select, insert, update, delete on public.invoice_settings to authenticated, service_role;

-- ── 2. Invoices and items ───────────────────────────────────────────────────
create table if not exists public.invoices (
  id                uuid primary key default gen_random_uuid(),
  provider_user_id  uuid not null references public.users(id) on delete cascade,
  client_id         uuid references public.clients(id) on delete set null,
  client_name       text not null,                     -- snapshot, survives client edits
  sequence          integer not null,
  number            text not null,
  status            text not null default 'unpaid' check (status in ('unpaid','paid','void')),
  issued_on         date not null default current_date,
  due_on            date,
  gst_applied       boolean not null default false,
  subtotal_cents    integer not null default 0 check (subtotal_cents >= 0),
  gst_cents         integer not null default 0 check (gst_cents >= 0),
  total_cents       integer not null default 0 check (total_cents >= 0),
  notes             text,
  issuer            jsonb not null default '{}'::jsonb, -- name, abn, address, bank, payid, notes
  share_token       text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  share_revoked_at  timestamptz,
  sent_at           timestamptz,
  paid_at           timestamptz,
  payment_method    text check (payment_method is null or payment_method in ('cash','bank_transfer','card','other')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (provider_user_id, sequence)
);
create index if not exists idx_invoices_provider_status on public.invoices (provider_user_id, status, issued_on desc);
create index if not exists idx_invoices_client on public.invoices (client_id);
create unique index if not exists idx_invoices_share_token on public.invoices (share_token);

drop trigger if exists set_invoices_updated_at on public.invoices;
create trigger set_invoices_updated_at before update on public.invoices
  for each row execute function public.set_updated_at();

create table if not exists public.invoice_items (
  id            uuid primary key default gen_random_uuid(),
  invoice_id    uuid not null references public.invoices(id) on delete cascade,
  job_id        uuid references public.jobs(id) on delete set null,
  service_on    date,
  description   text not null,
  quantity      numeric(8,2) not null default 1 check (quantity > 0),
  unit_cents    integer not null check (unit_cents >= 0),
  amount_cents  integer not null check (amount_cents >= 0),
  sort_order    integer not null default 0
);
create index if not exists idx_invoice_items_invoice on public.invoice_items (invoice_id, sort_order);
create index if not exists idx_invoice_items_job on public.invoice_items (job_id) where job_id is not null;

alter table public.jobs add column if not exists invoice_id uuid references public.invoices(id) on delete set null;
create index if not exists idx_jobs_invoice on public.jobs (invoice_id) where invoice_id is not null;

alter table public.message_log add column if not exists invoice_id uuid references public.invoices(id) on delete set null;

-- RLS: the owning carer reads everything; writes go through the RPCs below, except a few
-- bookkeeping columns the page patches directly.
alter table public.invoices      enable row level security;
alter table public.invoice_items enable row level security;
drop policy if exists invoices_owner_select on public.invoices;
create policy invoices_owner_select on public.invoices
  for select using (provider_user_id = (select auth.uid()));
drop policy if exists invoices_owner_update on public.invoices;
create policy invoices_owner_update on public.invoices
  for update using (provider_user_id = (select auth.uid())) with check (provider_user_id = (select auth.uid()));
drop policy if exists invoice_items_owner_select on public.invoice_items;
create policy invoice_items_owner_select on public.invoice_items
  for select using (exists (select 1 from public.invoices i where i.id = invoice_items.invoice_id and i.provider_user_id = (select auth.uid())));
-- Supabase's default privileges hand new tables to authenticated in full; take that back so
-- the column list below is the whole of what the page can write.
revoke all on public.invoices, public.invoice_items from public, anon, authenticated;
grant select on public.invoices, public.invoice_items to authenticated;
grant update (sent_at, notes, due_on, share_revoked_at) on public.invoices to authenticated;
grant select, insert, update, delete on public.invoices, public.invoice_items to service_role;

-- ── 3. Create ───────────────────────────────────────────────────────────────
-- p_job_ids: completed (or scheduled) own jobs for this client, priced, unpaid, not yet on a
-- live invoice. p_extra_items: [{description, amount_cents, quantity?, unit_cents?, service_on?}].
create or replace function public.create_invoice(
  p_client_id   uuid,
  p_job_ids     uuid[] default '{}',
  p_extra_items jsonb default '[]'::jsonb,
  p_issued_on   date default current_date,
  p_due_on      date default null,
  p_notes       text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_client  public.clients;
  v_set     public.invoice_settings;
  v_inv_id  uuid;
  v_seq     integer;
  v_number  text;
  v_total   integer := 0;
  v_gst     integer := 0;
  v_n       integer := 0;
  v_job     public.jobs;
  v_item    jsonb;
  v_amount  integer;
  v_qty     numeric;
  v_unit    integer;
  v_desc    text;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  select * into v_client from public.clients where id = p_client_id and provider_user_id = v_uid;
  if v_client.id is null then raise exception 'Not your client'; end if;

  -- Settings row, created on first use, locked so two tabs cannot take the same number.
  insert into public.invoice_settings (provider_user_id) values (v_uid) on conflict (provider_user_id) do nothing;
  select * into v_set from public.invoice_settings where provider_user_id = v_uid for update;
  v_seq := v_set.next_number;
  v_number := coalesce(v_set.invoice_prefix, '') || lpad(v_seq::text, 4, '0');
  update public.invoice_settings set next_number = v_seq + 1 where provider_user_id = v_uid;

  insert into public.invoices (provider_user_id, client_id, client_name, sequence, number, issued_on, due_on, gst_applied, notes, issuer)
  values (v_uid, v_client.id, coalesce(nullif(btrim(concat_ws(' ', v_client.first_name, v_client.last_name)), ''), 'Client'),
          v_seq, v_number, coalesce(p_issued_on, current_date),
          coalesce(p_due_on, coalesce(p_issued_on, current_date) + v_set.due_days),
          v_set.gst_registered, nullif(btrim(coalesce(p_notes, '')), ''),
          jsonb_strip_nulls(jsonb_build_object(
            'business_name', v_set.business_name, 'abn', v_set.abn, 'address', v_set.address,
            'email', v_set.email, 'phone', v_set.phone,
            'bank_account_name', v_set.bank_account_name, 'bank_bsb', v_set.bank_bsb, 'bank_account', v_set.bank_account,
            'payid', v_set.payid, 'payment_notes', v_set.payment_notes, 'footer_note', v_set.footer_note)))
  returning id into v_inv_id;

  -- Job lines, in date order, each locked onto this invoice.
  for v_job in
    select j.* from public.jobs j
     where j.id = any(p_job_ids) and j.provider_user_id = v_uid
     order by j.starts_at
  loop
    if v_job.client_id is distinct from p_client_id then raise exception 'Job % is for a different client', v_job.id; end if;
    if v_job.status = 'cancelled' then raise exception 'Job % is cancelled', v_job.id; end if;
    if v_job.paid_at is not null then raise exception 'Job % is already paid', v_job.id; end if;
    if v_job.invoice_id is not null then raise exception 'Job % is already on an invoice', v_job.id; end if;
    if coalesce(v_job.price_cents, 0) <= 0 then raise exception 'Job % has no price', v_job.id; end if;
    v_desc := concat_ws(' ',
      case v_job.service_type when 'dog_walking' then 'Dog walk' when 'dog_sitting' then 'Sitting'
                              when 'dog_boarding' then 'Boarding' when 'pet_sitting' then 'Visit' else 'Job' end,
      case when (select count(*) from public.job_pets jp where jp.job_id = v_job.id) > 0
           then 'for ' || (select string_agg(cp.name, ' and ' order by cp.name) from public.job_pets jp join public.client_pets cp on cp.id = jp.client_pet_id where jp.job_id = v_job.id) end,
      nullif(btrim(coalesce(v_job.title, '')), ''),
      '(' || to_char(v_job.starts_at at time zone 'Australia/Sydney', 'Dy DD Mon') || ', '
          || round(extract(epoch from (v_job.ends_at - v_job.starts_at)) / 60)::int || ' min)');
    insert into public.invoice_items (invoice_id, job_id, service_on, description, quantity, unit_cents, amount_cents, sort_order)
    values (v_inv_id, v_job.id, (v_job.starts_at at time zone 'Australia/Sydney')::date, v_desc, 1, v_job.price_cents, v_job.price_cents, v_n);
    update public.jobs set invoice_id = v_inv_id where id = v_job.id;
    v_total := v_total + v_job.price_cents;
    v_n := v_n + 1;
  end loop;

  -- Free-text lines.
  for v_item in select * from jsonb_array_elements(coalesce(p_extra_items, '[]'::jsonb)) loop
    v_desc := nullif(btrim(coalesce(v_item->>'description', '')), '');
    v_qty := coalesce(nullif(v_item->>'quantity', '')::numeric, 1);
    v_unit := coalesce(nullif(v_item->>'unit_cents', '')::integer, nullif(v_item->>'amount_cents', '')::integer, 0);
    v_amount := coalesce(nullif(v_item->>'amount_cents', '')::integer, round(v_qty * v_unit)::integer);
    if v_desc is null or v_amount <= 0 or v_qty <= 0 then continue; end if;
    insert into public.invoice_items (invoice_id, service_on, description, quantity, unit_cents, amount_cents, sort_order)
    values (v_inv_id, nullif(v_item->>'service_on', '')::date, v_desc, v_qty, v_unit, v_amount, v_n);
    v_total := v_total + v_amount;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then raise exception 'An invoice needs at least one line'; end if;

  -- GST-inclusive pricing: the GST component of a registered carer's total is one eleventh.
  if v_set.gst_registered then v_gst := round(v_total / 11.0)::integer; end if;
  update public.invoices
     set total_cents = v_total, gst_cents = v_gst, subtotal_cents = v_total - v_gst
   where id = v_inv_id;
  return v_inv_id;
end;
$$;
revoke all on function public.create_invoice(uuid, uuid[], jsonb, date, date, text) from public, anon;
grant execute on function public.create_invoice(uuid, uuid[], jsonb, date, date, text) to authenticated, service_role;

-- ── 4. Paid, unpaid, void ───────────────────────────────────────────────────
create or replace function public.set_invoice_paid(p_invoice_id uuid, p_paid boolean, p_method text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_inv public.invoices;
begin
  select * into v_inv from public.invoices where id = p_invoice_id and provider_user_id = auth.uid();
  if v_inv.id is null then raise exception 'Not your invoice'; end if;
  if v_inv.status = 'void' then raise exception 'Invoice is void'; end if;
  if p_paid then
    update public.invoices set status = 'paid', paid_at = now(), payment_method = coalesce(p_method, 'bank_transfer') where id = p_invoice_id;
    update public.jobs set paid_at = now(), payment_method = coalesce(p_method, 'bank_transfer')
     where invoice_id = p_invoice_id and paid_at is null;
  else
    update public.invoices set status = 'unpaid', paid_at = null, payment_method = null where id = p_invoice_id;
    update public.jobs set paid_at = null, payment_method = null where invoice_id = p_invoice_id;
  end if;
end;
$$;
revoke all on function public.set_invoice_paid(uuid, boolean, text) from public, anon;
grant execute on function public.set_invoice_paid(uuid, boolean, text) to authenticated, service_role;

-- Void keeps the number (gaps in a sequence are fine; reusing one is not) and frees the jobs.
create or replace function public.void_invoice(p_invoice_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_inv public.invoices;
begin
  select * into v_inv from public.invoices where id = p_invoice_id and provider_user_id = auth.uid();
  if v_inv.id is null then raise exception 'Not your invoice'; end if;
  if v_inv.status = 'paid' then raise exception 'Mark it unpaid first'; end if;
  update public.invoices set status = 'void', share_revoked_at = now() where id = p_invoice_id;
  update public.jobs set invoice_id = null where invoice_id = p_invoice_id;
end;
$$;
revoke all on function public.void_invoice(uuid) from public, anon;
grant execute on function public.void_invoice(uuid) to authenticated, service_role;

-- A job marked paid on the schedule (cash on the day) while sitting on an unpaid invoice:
-- when every job line on that invoice is paid, the invoice follows. Free-text lines have no
-- job, so an invoice with any of those waits for the explicit mark.
create or replace function private.tg_job_paid_settles_invoice()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if NEW.invoice_id is not null and NEW.paid_at is not null and OLD.paid_at is null then
    if not exists (select 1 from public.invoice_items ii left join public.jobs j on j.id = ii.job_id
                    where ii.invoice_id = NEW.invoice_id and (ii.job_id is null or j.paid_at is null)) then
      update public.invoices set status = 'paid', paid_at = NEW.paid_at, payment_method = NEW.payment_method
       where id = NEW.invoice_id and status = 'unpaid';
    end if;
  end if;
  return NEW;
end;
$$;
drop trigger if exists trg_job_paid_settles_invoice on public.jobs;
create trigger trg_job_paid_settles_invoice after update of paid_at on public.jobs
  for each row execute function private.tg_job_paid_settles_invoice();

-- ── 5. Public page ──────────────────────────────────────────────────────────
create or replace function public.invoice_public(p_token text)
returns jsonb
language sql
security definer
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'invoice', jsonb_build_object(
      'number', i.number, 'status', i.status, 'issued_on', i.issued_on, 'due_on', i.due_on,
      'gst_applied', i.gst_applied, 'subtotal_cents', i.subtotal_cents, 'gst_cents', i.gst_cents,
      'total_cents', i.total_cents, 'notes', i.notes, 'paid_at', i.paid_at, 'payment_method', i.payment_method),
    'issuer', i.issuer || jsonb_build_object('carer_name', nullif(btrim(concat_ws(' ', u.first_name, u.last_name)), '')),
    'client', jsonb_build_object('name', i.client_name, 'email', c.email,
                                 'address', nullif(concat_ws(', ', c.address, c.suburb, c.postcode), '')),
    'items', coalesce((select jsonb_agg(jsonb_build_object('description', ii.description, 'service_on', ii.service_on,
                                                            'quantity', ii.quantity, 'unit_cents', ii.unit_cents, 'amount_cents', ii.amount_cents)
                                        order by ii.sort_order, ii.service_on)
                         from public.invoice_items ii where ii.invoice_id = i.id), '[]'::jsonb)
  )
  from public.invoices i
  join public.users u on u.id = i.provider_user_id
  left join public.clients c on c.id = i.client_id
  where p_token is not null and length(p_token) >= 32
    and i.share_token = p_token and i.share_revoked_at is null and i.status <> 'void';
$$;
revoke all on function public.invoice_public(text) from public;
grant execute on function public.invoice_public(text) to anon, authenticated;

-- ── 6. Account deletion: invoices go with the carer ─────────────────────────
-- Full replacement of admin_delete_account (last changed in 20260913000000); the only new
-- lines are the two deletes marked "E2".
create or replace function public.admin_delete_account(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cp_id  uuid;
  v_pp_id  uuid;
  v_email  text;
  v_future integer;
  v_owed   integer;
  v_tag    text := replace(p_user_id::text, '-', '');
  v_pings  integer := 0;
  v_msgs   integer := 0;
  v_sessions uuid[];
  v_clients integer := 0;
begin
  select email into v_email from public.users where id = p_user_id;
  if v_email is null then
    raise exception 'No such user: %', p_user_id;
  end if;

  select id into v_cp_id from public.customer_profiles where user_id = p_user_id;
  select id into v_pp_id from public.provider_profiles where user_id = p_user_id;

  select count(*) into v_future
  from public.bookings b
  where b.status in ('pending', 'confirmed')
    and coalesce(b.ends_at, b.scheduled_at) > now()
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );
  if v_future > 0 then
    raise exception 'Cannot delete: % future booking(s) still scheduled', v_future;
  end if;

  select count(*) into v_owed
  from public.bookings b
  where b.status = 'completed'
    and coalesce(b.payment_status, 'unpaid') in ('unpaid', 'failed', 'processing')
    and ( (v_cp_id is not null and b.customer_id = v_cp_id)
       or (v_pp_id is not null and b.provider_id = v_pp_id) );
  if v_owed > 0 then
    raise exception 'Cannot delete: % completed booking(s) not yet settled', v_owed;
  end if;

  -- Delist first.
  if v_pp_id is not null then
    update public.provider_profiles
       set is_active = false, updated_at = now()
     where id = v_pp_id;
    update public.provider_services set is_available = false where provider_id = p_user_id;
  end if;

  -- PURGE: the trail.
  select array_agg(ws.id) into v_sessions
    from public.walk_sessions ws
    left join public.bookings b on b.id = ws.booking_id
   where ws.provider_id = p_user_id
      or (v_cp_id is not null and b.customer_id = v_cp_id)
      or (v_pp_id is not null and b.provider_id = v_pp_id);

  delete from public.gps_pings where walk_session_id = any(v_sessions);
  get diagnostics v_pings = row_count;

  update public.messages set body = '[deleted]' where sender_id = p_user_id;
  get diagnostics v_msgs = row_count;

  update public.walk_updates
     set message = null, photo_url = null
   where provider_id = p_user_id
      or walk_session_id = any(v_sessions);

  delete from public.booking_updates bu
   where bu.provider_user_id = p_user_id
      or (v_cp_id is not null and bu.booking_id in (select id from public.bookings where customer_id = v_cp_id));

  delete from public.notifications  where user_id = p_user_id;
  delete from public.system_messages where recipient_user_id = p_user_id;

  if v_cp_id is not null then
    delete from private.backup_access where customer_id = v_cp_id;
  end if;

  update public.search_misses set customer_id = null where customer_id = v_cp_id;

  -- Supply-side additions. A leaving carer's client book, series, jobs (and with them any
  -- job-backed walk sessions), templates and send log are deleted outright. A leaving owner
  -- is scrubbed from every carer's book where Truffl created the record.
  delete from public.invoices                     where provider_user_id = p_user_id;  -- E2 (items cascade)
  delete from public.invoice_settings             where provider_user_id = p_user_id;  -- E2
  delete from private.google_tokens              where provider_user_id = p_user_id;  -- C3
  delete from public.calendar_event_links         where provider_user_id = p_user_id;  -- C3
  delete from public.google_calendar_connections  where provider_user_id = p_user_id;  -- C3
  delete from public.message_log       where provider_user_id = p_user_id;  -- D1
  delete from public.message_templates where provider_user_id = p_user_id;  -- D1
  delete from public.jobs        where provider_user_id = p_user_id;
  delete from public.job_series  where provider_user_id = p_user_id;
  delete from public.clients     where provider_user_id = p_user_id;
  get diagnostics v_clients = row_count;

  if v_cp_id is not null then
    update public.client_pets
       set name = 'Pet', breed = null, dob = null, weight_kg = null,
           behaviour_notes = null, medical_notes = null, vet_name = null, vet_phone = null,
           photo_url = null, is_active = false, linked_pet_id = null
     where client_id in (select id from public.clients where linked_customer_id = v_cp_id and source = 'truffl');
    update public.clients
       set first_name = 'Deleted', last_name = 'user', phone = null, email = null,
           address = null, suburb = null, postcode = null, notes = null, tags = '{}',
           is_archived = true, linked_customer_id = null
     where linked_customer_id = v_cp_id and source = 'truffl';
    update public.clients set linked_customer_id = null where linked_customer_id = v_cp_id;
  end if;

  -- ANONYMISE: the identity.
  if v_cp_id is not null then
    update public.customer_profiles
       set address = null, suburb = null, postcode = null,
           emergency_contact = null, emergency_phone = null,
           location = null,
           backup_cover_enabled = false,
           updated_at = now()
     where id = v_cp_id;

    update public.pets
       set name = 'Pet', breed = null, microchip_no = null,
           vet_name = null, vet_phone = null,
           medical_notes = null, behaviour_notes = null,
           photo_url = null, is_active = false
     where customer_id = v_cp_id;
  end if;

  if v_pp_id is not null then
    update public.provider_profiles
       set bio = null, suburb = null, postcode = null, abn = null,
           location = null, service_area = null,
           updated_at = now()
     where id = v_pp_id;
  end if;

  update public.carer_requests
     set contact_name = 'Deleted user', contact_email = null, contact_phone = null,
         note = null, dog_name = null, dog_breed = null, dog_temperament_note = null,
         search_params = null
   where (v_cp_id is not null and (customer_id = v_cp_id or converted_customer_id = v_cp_id))
      or lower(contact_email) = lower(v_email);

  update public.users
     set first_name = 'Deleted',
         last_name  = 'user',
         email      = 'deleted+' || v_tag || '@trufflpets.com',
         phone      = null,
         avatar_url = null,
         is_active  = false,
         is_admin   = false,
         updated_at = now()
   where id = p_user_id;

  return jsonb_build_object(
    'user_id',              p_user_id,
    'gps_pings_deleted',    v_pings,
    'messages_redacted',    v_msgs,
    'clients_deleted',      v_clients,
    'had_customer_profile', v_cp_id is not null,
    'had_provider_profile', v_pp_id is not null
  );
end;
$$;
revoke all on function public.admin_delete_account(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_account(uuid) to service_role;
