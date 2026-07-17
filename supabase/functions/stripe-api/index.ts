// TRU-143 (+ later phases): authenticated client-facing Stripe actions.
// verify_jwt is DISABLED: the browser CORS preflight (OPTIONS) carries no JWT, so the
// platform gate would reject it and the call would never reach us. Instead we authenticate
// in-function by validating the caller's Supabase JWT via auth.getUser (a request with no
// valid user is rejected 401 below). We talk to Stripe's REST API directly (no SDK — most
// reliable in the Deno edge runtime, same fetch style as send-notification).
//
// Actions:
//   connect_onboard - get/create the carer's Express account, return a Stripe onboarding URL
//   connect_status  - retrieve the account, persist payouts/charges readiness, return it
//   setup_intent    - get/create the customer's Stripe Customer, return a SetupIntent secret
//   set_default_pm  - set the just-saved card as the customer's default payment method
//   retry_charge    - recover a failed charge on-session (returns a PaymentIntent secret)
//   sync_payment    - reconcile a booking's payment_status from its PaymentIntent
//   list_recent_charges - (admin) recent paid/failed/refunded bookings for the admin page
//   refund_booking  - (admin) refund a paid booking + reverse the carer's transfer
//   cover_list      - (admin) covered bookings (triggered/reassigned/fell_through) + credits
//   cover_reassign  - (admin) take over a covered cancelled booking (TRU-139)
//   cover_fell_through - (admin) mark cover as failed; issue a manual credit + owner message
//   credit_redeem   - (admin) mark a manual credit as applied
//   requests_list   - (admin) open "can't find a carer" requests + unmet-search signal (TRU-121)
//   request_find_carers - (admin) candidate carers near a request (reuses search_carers)
//   request_assign  - (admin) assign an existing carer -> creates a pending booking request
//   request_update  - (admin) set a request's status + admin note (guest / onboarding path)
//
// Required function secrets (Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY   - sk_test_… (platform secret key)
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITE = 'https://trufflpets.com';
// Platform take rate in basis points (matches charge-booking). 1500 = 15%; set 0 at launch.
const PLATFORM_FEE_BPS = 1500;

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

// Form-encode with Stripe's nested-bracket convention (e.g. capabilities[transfers][requested]).
function encode(obj: Record<string, unknown>, prefix = ''): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (typeof v === 'object') parts.push(encode(v as Record<string, unknown>, key));
    else parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
  }
  return parts.filter(Boolean).join('&');
}

async function stripe(path: string, method: 'GET' | 'POST', body?: Record<string, unknown>) {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body ? encode(body) : undefined,
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || `Stripe ${path} failed (${res.status})`);
  return data;
}

async function getProvider(userId: string) {
  const { data } = await sb
    .from('provider_profiles')
    .select('id,user_id,stripe_account_id,payouts_enabled,charges_enabled')
    .eq('user_id', userId)
    .single();
  return data;
}

async function getCustomer(userId: string) {
  const { data } = await sb
    .from('customer_profiles')
    .select('id,user_id,stripe_customer_id')
    .eq('user_id', userId)
    .single();
  return data;
}

async function isAdmin(userId: string) {
  const { data } = await sb.from('users').select('is_admin').eq('id', userId).single();
  return !!data?.is_admin;
}

Deno.serve(async (req) => {
  // Per-request CORS (origin allow-list) — TRU-200. Local `json` closes over it.
  const CORS = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  // Identify the caller from their Supabase JWT (users.id === auth.uid()).
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: { user }, error: uerr } = await sb.auth.getUser(jwt);
  if (uerr || !user) return json({ error: 'Not authenticated' }, 401);

  let payload: Record<string, unknown> = {};
  try { payload = await req.json(); } catch { /* empty body ok */ }
  const action = String(payload.action || '');

  try {
    if (action === 'connect_onboard') {
      const provider = await getProvider(user.id);
      if (!provider) return json({ error: 'Not a carer account' }, 403);

      let acctId = provider.stripe_account_id as string | null;
      if (!acctId) {
        const acct = await stripe('accounts', 'POST', {
          type: 'express',
          country: 'AU',
          email: user.email,
          business_type: 'individual',
          // Destination charges settle on the platform and transfer to the carer, so the
          // connected account only needs the transfers capability.
          capabilities: { transfers: { requested: true } },
          business_profile: { product_description: 'Pet care services via Truffl Pets' },
          metadata: { provider_profile_id: provider.id, user_id: user.id },
        });
        acctId = acct.id as string;
        await sb.from('provider_profiles').update({ stripe_account_id: acctId }).eq('id', provider.id);
      }

      const link = await stripe('account_links', 'POST', {
        account: acctId,
        type: 'account_onboarding',
        // TRU-157: land back on the Earnings tab so the carer sees the payout
        // confirmation card instead of the default bookings view.
        refresh_url: `${SITE}/dashboard/?payouts=refresh&tab=earnings`,
        return_url: `${SITE}/dashboard/?payouts=return&tab=earnings`,
      });
      return json({ url: link.url });
    }

    if (action === 'connect_status') {
      const provider = await getProvider(user.id);
      if (!provider) return json({ error: 'Not a carer account' }, 403);
      if (!provider.stripe_account_id) {
        return json({ connected: false, payouts_enabled: false, charges_enabled: false });
      }
      const acct = await stripe(`accounts/${provider.stripe_account_id}`, 'GET');
      const payouts_enabled = !!acct.payouts_enabled;
      const charges_enabled = !!acct.charges_enabled;
      await sb.from('provider_profiles')
        .update({ payouts_enabled, charges_enabled })
        .eq('id', provider.id);
      return json({
        connected: true,
        payouts_enabled,
        charges_enabled,
        details_submitted: !!acct.details_submitted,
        stripe_account_id: provider.stripe_account_id,
      });
    }

    if (action === 'setup_intent') {
      // Save a customer's card off-session at the M&G proceed step (no charge here).
      const customer = await getCustomer(user.id);
      if (!customer) return json({ error: 'Not a customer account' }, 403);
      let custId = customer.stripe_customer_id as string | null;
      if (!custId) {
        const c = await stripe('customers', 'POST', {
          email: user.email,
          metadata: { customer_profile_id: customer.id, user_id: user.id },
        });
        custId = c.id as string;
        await sb.from('customer_profiles').update({ stripe_customer_id: custId }).eq('id', customer.id);
      }
      const si = await stripe('setup_intents', 'POST', {
        customer: custId,
        usage: 'off_session',
        'payment_method_types[]': 'card',
      });
      return json({ client_secret: si.client_secret, customer_id: custId });
    }

    if (action === 'set_default_pm') {
      // Make the just-saved card the customer's default so Phase 3 can charge it off-session.
      const customer = await getCustomer(user.id);
      if (!customer?.stripe_customer_id) return json({ error: 'No Stripe customer on file' }, 400);
      const pm = String(payload.payment_method || '');
      if (!pm) return json({ error: 'Missing payment_method' }, 400);
      await stripe(`customers/${customer.stripe_customer_id}`, 'POST', {
        'invoice_settings[default_payment_method]': pm,
      });
      return json({ ok: true });
    }

    if (action === 'retry_charge') {
      // Customer recovers a failed off-session charge on-session (can fix/replace the card).
      const customer = await getCustomer(user.id);
      if (!customer) return json({ error: 'Not a customer account' }, 403);
      const bookingId = String(payload.booking_id || '');
      const { data: b } = await sb.from('bookings')
        .select('id,total_cents,provider_id,is_meet_and_greet,payment_status,cover_status')
        .eq('id', bookingId).eq('customer_id', customer.id).single();
      if (!b) return json({ error: 'Booking not found' }, 404);
      if (b.is_meet_and_greet || (b.total_cents || 0) <= 0) return json({ error: 'Nothing to pay' }, 400);
      if (b.payment_status !== 'failed') return json({ error: 'This booking is not awaiting payment' }, 400);
      if (!customer.stripe_customer_id) return json({ error: 'No payment profile on file' }, 400);
      // A covered walk completed by the Truffl backup is retained in full (TRU-139):
      // no destination transfer, no application fee — mirrors charge-booking.
      const covered = b.cover_status === 'reassigned';
      const piBody: Record<string, unknown> = {
        amount: b.total_cents,
        currency: 'aud',
        customer: customer.stripe_customer_id,
        'payment_method_types[]': 'card',
        setup_future_usage: 'off_session', // save the working card for future charges
        'metadata[booking_id]': bookingId,
      };
      let fee = 0;
      if (!covered) {
        const { data: pp } = await sb.from('provider_profiles').select('stripe_account_id').eq('id', b.provider_id).single();
        if (!pp?.stripe_account_id) return json({ error: 'Carer has no payout account' }, 400);
        piBody['transfer_data[destination]'] = pp.stripe_account_id;
        fee = Math.round((b.total_cents * PLATFORM_FEE_BPS) / 10000);
        if (fee > 0) piBody['application_fee_amount'] = fee;
      }
      // No confirm — the client confirms with the Payment Element so a new card / 3DS works.
      const pi = await stripe('payment_intents', 'POST', piBody);
      await sb.from('bookings').update({ stripe_payment_intent_id: pi.id, application_fee_cents: fee }).eq('id', bookingId);
      return json({ client_secret: pi.client_secret });
    }

    if (action === 'sync_payment') {
      // Reconcile a booking's payment from its PaymentIntent after the client confirms
      // (webhook-independent). Used by the retry flow.
      const customer = await getCustomer(user.id);
      if (!customer) return json({ error: 'Not a customer account' }, 403);
      const bookingId = String(payload.booking_id || '');
      const { data: b } = await sb.from('bookings')
        .select('id,stripe_payment_intent_id,payment_status')
        .eq('id', bookingId).eq('customer_id', customer.id).single();
      if (!b) return json({ error: 'Booking not found' }, 404);
      if (!b.stripe_payment_intent_id) return json({ payment_status: b.payment_status });
      const pi = await stripe(`payment_intents/${b.stripe_payment_intent_id}`, 'GET');
      if (pi.status === 'succeeded') {
        await sb.from('bookings')
          .update({ payment_status: 'paid', charged_at: new Date().toISOString() })
          .eq('id', bookingId).neq('payment_status', 'paid');
        // Make the card that worked the customer's default for future off-session charges.
        if (pi.payment_method && customer.stripe_customer_id) {
          try { await stripe(`customers/${customer.stripe_customer_id}`, 'POST', { 'invoice_settings[default_payment_method]': pi.payment_method }); } catch (_e) { /* non-fatal */ }
        }
        return json({ payment_status: 'paid' });
      }
      if (pi.status === 'requires_payment_method' || pi.status === 'canceled') {
        await sb.from('bookings').update({ payment_status: 'failed' }).eq('id', bookingId).neq('payment_status', 'paid');
        return json({ payment_status: 'failed' });
      }
      return json({ payment_status: b.payment_status, pi_status: pi.status });
    }

    if (action === 'list_recent_charges') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const { data } = await sb.from('bookings')
        .select('id,total_cents,payment_status,charged_at,refunded_at,scheduled_at,customer_id,provider_id')
        .in('payment_status', ['paid', 'failed', 'refunded'])
        .order('updated_at', { ascending: false })
        .limit(50);
      const rows = data || [];
      const NONE = ['00000000-0000-0000-0000-000000000000'];
      const custIds = [...new Set(rows.map((r) => r.customer_id))];
      const provIds = [...new Set(rows.map((r) => r.provider_id))];
      const [{ data: cps }, { data: pps }] = await Promise.all([
        sb.from('customer_profiles').select('id,user_id').in('id', custIds.length ? custIds : NONE),
        sb.from('provider_profiles').select('id,user_id').in('id', provIds.length ? provIds : NONE),
      ]);
      const custUser = Object.fromEntries((cps || []).map((c) => [c.id, c.user_id]));
      const provUser = Object.fromEntries((pps || []).map((p) => [p.id, p.user_id]));
      const userIds = [...new Set([...Object.values(custUser), ...Object.values(provUser)])] as string[];
      const { data: us } = await sb.from('users').select('id,first_name,last_name').in('id', userIds.length ? userIds : NONE);
      const nameBy = Object.fromEntries((us || []).map((u) => [u.id, `${u.first_name || ''} ${u.last_name || ''}`.trim()]));
      const charges = rows.map((r) => ({
        id: r.id,
        total_cents: r.total_cents,
        payment_status: r.payment_status,
        charged_at: r.charged_at,
        refunded_at: r.refunded_at,
        scheduled_at: r.scheduled_at,
        customer: nameBy[custUser[r.customer_id]] || 'Customer',
        carer: nameBy[provUser[r.provider_id]] || 'Carer',
      }));
      return json({ charges });
    }

    if (action === 'refund_booking') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const bookingId = String(payload.booking_id || '');
      const { data: b } = await sb.from('bookings')
        .select('id,payment_status,stripe_payment_intent_id')
        .eq('id', bookingId).single();
      if (!b) return json({ error: 'Booking not found' }, 404);
      if (b.payment_status !== 'paid' || !b.stripe_payment_intent_id) {
        return json({ error: 'Only a paid booking can be refunded' }, 400);
      }
      // Full refund: customer gets 100% back, the carer's transfer is reversed, and the
      // platform application fee is returned too.
      const refundBody: Record<string, unknown> = {
        payment_intent: b.stripe_payment_intent_id,
        reverse_transfer: true,
        refund_application_fee: true,
      };
      if (payload.reason) refundBody['metadata[reason]'] = String(payload.reason);
      const refund = await stripe('refunds', 'POST', refundBody);
      await sb.from('bookings')
        .update({ payment_status: 'refunded', refunded_at: new Date().toISOString(), stripe_refund_id: refund.id })
        .eq('id', bookingId);
      return json({ ok: true, refund_id: refund.id });
    }

    // ── Backup cover (TRU-139) — admin actions ──

    if (action === 'cover_list') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const { data } = await sb.from('bookings')
        .select('id,scheduled_at,window_end_at,duration_mins,total_cents,status,payment_status,cover_status,cancel_reason,cancelled_at,late_cancellation,customer_id,provider_id,original_provider_id,pet_id')
        .neq('cover_status', 'none')
        .order('scheduled_at', { ascending: false })
        .limit(30);
      const rows = data || [];
      const NONE = ['00000000-0000-0000-0000-000000000000'];
      const custIds = [...new Set(rows.map((r) => r.customer_id))];
      const provIds = [...new Set(rows.flatMap((r) => [r.provider_id, r.original_provider_id]).filter(Boolean))] as string[];
      const petIds = [...new Set(rows.map((r) => r.pet_id).filter(Boolean))] as string[];
      const [{ data: cps }, { data: pps }, { data: petsData }, { data: credits }] = await Promise.all([
        sb.from('customer_profiles').select('id,user_id').in('id', custIds.length ? custIds : NONE),
        sb.from('provider_profiles').select('id,user_id').in('id', provIds.length ? provIds : NONE),
        sb.from('pets').select('id,name').in('id', petIds.length ? petIds : NONE),
        sb.from('customer_credits').select('id,customer_id,amount_cents,reason,created_at,redeemed_at,redeemed_note,booking_id')
          .order('created_at', { ascending: false }).limit(30),
      ]);
      const custUser = Object.fromEntries((cps || []).map((c) => [c.id, c.user_id]));
      const provUser = Object.fromEntries((pps || []).map((p) => [p.id, p.user_id]));
      const petName = Object.fromEntries((petsData || []).map((p) => [p.id, p.name]));
      const creditCustIds = [...new Set((credits || []).map((c) => c.customer_id))];
      const { data: creditCps } = await sb.from('customer_profiles').select('id,user_id').in('id', creditCustIds.length ? creditCustIds : NONE);
      (creditCps || []).forEach((c) => { custUser[c.id] = c.user_id; });
      const userIds = [...new Set([...Object.values(custUser), ...Object.values(provUser)])] as string[];
      const { data: us } = await sb.from('users').select('id,first_name,last_name').in('id', userIds.length ? userIds : NONE);
      const nameBy = Object.fromEntries((us || []).map((u) => [u.id, `${u.first_name || ''} ${u.last_name || ''}`.trim()]));
      return json({
        cover: rows.map((r) => ({
          ...r,
          customer: nameBy[custUser[r.customer_id]] || 'Customer',
          walker: nameBy[provUser[r.original_provider_id || r.provider_id]] || 'Walker',
          pet: petName[r.pet_id] || 'Dog',
        })),
        credits: (credits || []).map((c) => ({ ...c, customer: nameBy[custUser[c.customer_id]] || 'Customer' })),
      });
    }

    if (action === 'cover_reassign') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const bookingId = String(payload.booking_id || '');
      const { data: b } = await sb.from('bookings')
        .select('id,status,cover_status,provider_id,original_provider_id,customer_id,pet_id')
        .eq('id', bookingId).maybeSingle();
      if (!b) return json({ error: 'Booking not found' }, 404);
      if (b.cover_status !== 'triggered' || b.status !== 'cancelled') {
        return json({ error: 'This booking is not awaiting cover' }, 400);
      }
      // The admin doing the reassign becomes the backup walker. Ensure they have a
      // provider profile — created inactive + unverified so it is never searchable;
      // it's just the identity the walk hangs off so tracking/completion work
      // unchanged (records: original_provider_id = booked, provider_id = actual).
      let { data: mypp } = await sb.from('provider_profiles').select('id').eq('user_id', user.id).maybeSingle();
      if (!mypp) {
        const ins = await sb.from('provider_profiles')
          .insert({ user_id: user.id, is_active: false, is_verified: false, bio: 'Truffl backup' })
          .select('id').single();
        if (ins.error || !ins.data) return json({ error: 'Could not create backup profile' }, 500);
        mypp = ins.data;
      }
      if (mypp.id === b.provider_id) return json({ error: 'Booking is already assigned to you' }, 400);
      const upd = await sb.from('bookings').update({
        original_provider_id: b.original_provider_id || b.provider_id,
        provider_id: mypp.id,
        status: 'confirmed',
        cover_status: 'reassigned',
      }).eq('id', bookingId).eq('cover_status', 'triggered').select('id');
      if (upd.error || !upd.data?.length) return json({ error: 'Reassign failed — booking may already be handled' }, 409);
      // Tell the owner in-app (one-way Truffl channel; service role writes directly).
      const { data: cp } = await sb.from('customer_profiles').select('user_id').eq('id', b.customer_id).single();
      const { data: pet } = b.pet_id ? await sb.from('pets').select('name').eq('id', b.pet_id).single() : { data: null };
      if (cp?.user_id) {
        await sb.from('system_messages').insert({
          recipient_user_id: cp.user_id,
          body: `Good news — your walker had to cancel, but backup cover kicked in. A Truffl backup will walk ${pet?.name || 'your dog'} as planned.`,
          link_url: `/track/?booking=${bookingId}`,
          link_label: 'View booking',
        });
      }
      return json({ ok: true });
    }

    if (action === 'cover_fell_through') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const bookingId = String(payload.booking_id || '');
      const creditCents = Math.max(0, Math.round(Number(payload.credit_cents ?? 1000)) || 0);
      const { data: b } = await sb.from('bookings')
        .select('id,status,cover_status,customer_id,pet_id')
        .eq('id', bookingId).maybeSingle();
      if (!b) return json({ error: 'Booking not found' }, 404);
      if (b.cover_status !== 'triggered' || b.status !== 'cancelled') {
        return json({ error: 'This booking is not awaiting cover' }, 400);
      }
      const upd = await sb.from('bookings').update({ cover_status: 'fell_through' })
        .eq('id', bookingId).eq('cover_status', 'triggered').select('id');
      if (upd.error || !upd.data?.length) return json({ error: 'Update failed — booking may already be handled' }, 409);
      // The walk was never charged (charging happens on completion), so "full
      // refund" needs no money movement — the credit is the goodwill on top.
      if (creditCents > 0) {
        await sb.from('customer_credits').insert({
          customer_id: b.customer_id,
          amount_cents: creditCents,
          reason: 'Backup cover fell through',
          booking_id: bookingId,
        });
      }
      const { data: cp } = await sb.from('customer_profiles').select('user_id').eq('id', b.customer_id).single();
      const { data: pet } = b.pet_id ? await sb.from('pets').select('name').eq('id', b.pet_id).single() : { data: null };
      if (cp?.user_id) {
        const creditLine = creditCents > 0 ? ` and we've added a $${(creditCents / 100).toFixed(0)} credit to your account for next time` : '';
        await sb.from('system_messages').insert({
          recipient_user_id: cp.user_id,
          body: `We're really sorry — we weren't able to cover ${pet?.name || 'your dog'}'s walk. You haven't been charged for it${creditLine}. No questions asked.`,
          link_url: '/profile/',
          link_label: 'View your bookings',
        });
      }
      return json({ ok: true, credit_cents: creditCents });
    }

    if (action === 'credit_redeem') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const creditId = String(payload.credit_id || '');
      const note = String(payload.note || '').slice(0, 300);
      const upd = await sb.from('customer_credits')
        .update({ redeemed_at: new Date().toISOString(), redeemed_note: note || null })
        .eq('id', creditId).is('redeemed_at', null).select('id');
      if (upd.error || !upd.data?.length) return json({ error: 'Credit not found or already applied' }, 409);
      return json({ ok: true });
    }

    // ── "Can't find a carer" requests (TRU-121) — admin actions ──

    if (action === 'requests_list') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const NONE = ['00000000-0000-0000-0000-000000000000'];
      // TRU-221: every non-terminal pipeline status stays on the board so nothing falls
      // through; terminal leads (transitioned/lost/closed) drop off.
      const { data: reqs } = await sb.from('carer_requests')
        .select('*')
        .in('status', ['captured', 'called', 'founder_walking', 'sourcing_walker', 'meet_greet_booked'])
        .order('created_at', { ascending: false })
        .limit(100);
      const rows = reqs || [];
      const custIds = [...new Set(rows.map((r) => r.customer_id).filter(Boolean))] as string[];
      const petIds = [...new Set(rows.map((r) => r.pet_id).filter(Boolean))] as string[];
      const [{ data: cps }, { data: petsData }] = await Promise.all([
        sb.from('customer_profiles').select('id,user_id').in('id', custIds.length ? custIds : NONE),
        sb.from('pets').select('id,name').in('id', petIds.length ? petIds : NONE),
      ]);
      const custUser = Object.fromEntries((cps || []).map((c) => [c.id, c.user_id]));
      const petName = Object.fromEntries((petsData || []).map((p) => [p.id, p.name]));
      const uIds = [...new Set(Object.values(custUser))] as string[];
      const { data: us } = await sb.from('users').select('id,first_name,last_name,email').in('id', uIds.length ? uIds : NONE);
      const userBy = Object.fromEntries((us || []).map((u) => [u.id, u]));

      // Passive signal — weekly unmet-search counts by suburb (TRU-222's rollup view),
      // last 8 weeks, biggest gaps first.
      const since = new Date(Date.now() - 56 * 864e5).toISOString().slice(0, 10);
      const { data: signal } = await sb.from('search_miss_weekly')
        .select('week_start,suburb,postcode,service_type,misses')
        .gte('week_start', since)
        .order('week_start', { ascending: false })
        .order('misses', { ascending: false })
        .limit(40);

      const now = Date.now();
      return json({
        requests: rows.map((r) => {
          const u = userBy[custUser[r.customer_id]];
          return {
            ...r,
            contact: r.contact_name || (u ? `${u.first_name || ''} ${u.last_name || ''}`.trim() : '') || (r.customer_id ? 'Customer' : 'Guest'),
            email: r.contact_email || (u ? u.email : '') || '',
            pet: r.pet_id ? (petName[r.pet_id] || 'Dog') : '',
            can_assign: !!(r.customer_id && r.pet_id),
            days_in_status: Math.floor((now - new Date(r.status_changed_at || r.created_at).getTime()) / 864e5),
          };
        }),
        signal: signal || [],
      });
    }

    if (action === 'request_find_carers') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const NONE = ['00000000-0000-0000-0000-000000000000'];
      const { data: rq } = await sb.from('carer_requests')
        .select('id,suburb,service_type,wanted_date,window_start')
        .eq('id', String(payload.request_id || '')).maybeSingle();
      if (!rq) return json({ error: 'Request not found' }, 404);
      const { data: carers, error } = await sb.rpc('search_carers', { p_suburb: rq.suburb, p_date: rq.wanted_date });
      if (error) return json({ error: error.message }, 500);
      const list = (carers || []) as Record<string, unknown>[];
      // Attach each carer's matching provider_services (id/price/duration) for the assign step.
      // Note: provider_services.provider_id references users.id (the carer's user_id).
      const userIds = list.map((c) => c.user_id as string).filter(Boolean);
      const { data: svcs } = await sb.from('provider_services')
        .select('id,provider_id,service_type,price_cents,duration_mins')
        .in('provider_id', userIds.length ? userIds : NONE)
        .eq('is_available', true);
      const svcByUser: Record<string, Record<string, unknown>[]> = {};
      (svcs || []).forEach((s) => { (svcByUser[s.provider_id] ||= []).push(s); });
      const carersOut = list.map((c) => {
        let services = svcByUser[c.user_id as string] || [];
        if (rq.service_type) services = services.filter((s) => s.service_type === rq.service_type);
        return {
          provider_id: c.id, user_id: c.user_id,
          name: `${c.first_name || ''} ${c.last_name || ''}`.trim() || 'Carer',
          suburb: c.suburb, distance_km: c.distance_km, is_verified: c.is_verified,
          avg_rating: c.avg_rating, total_reviews: c.total_reviews,
          services: services.map((s) => ({ id: s.id, service_type: s.service_type, price_cents: s.price_cents, duration_mins: s.duration_mins })),
        };
      }).filter((c) => !rq.service_type || c.services.length > 0);
      return json({ request: rq, carers: carersOut });
    }

    if (action === 'request_assign') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const reqId = String(payload.request_id || '');
      const providerId = String(payload.provider_id || ''); // provider_profiles.id
      const serviceId = String(payload.service_id || '');   // provider_services.id
      const scheduledAt = String(payload.scheduled_at || ''); // ISO timestamp
      if (!providerId || !serviceId || !scheduledAt) return json({ error: 'Missing carer, service or time' }, 400);
      const { data: rq } = await sb.from('carer_requests').select('*').eq('id', reqId).maybeSingle();
      if (!rq) return json({ error: 'Request not found' }, 404);
      if (['transitioned', 'lost', 'closed'].includes(rq.status)) return json({ error: 'Request already resolved' }, 409);
      if (!rq.customer_id || !rq.pet_id) return json({ error: 'This request has no linked customer/pet to assign' }, 400);

      const { data: svc } = await sb.from('provider_services').select('id,duration_mins').eq('id', serviceId).maybeSingle();
      if (!svc) return json({ error: 'Service not found' }, 404);

      // Mirror the customer's single-booking insert (book/index.html): status 'pending',
      // total_cents 0 (single bookings price on completion; series carry locked_price_cents).
      // The carer still accepts and the customer still confirms — nothing is forced. The
      // existing trg_email_booking_request trigger notifies the carer on insert.
      const ins = await sb.from('bookings').insert({
        customer_id: rq.customer_id,
        provider_id: providerId,
        pet_id: rq.pet_id,
        service_id: serviceId,
        status: 'pending',
        scheduled_at: scheduledAt,
        duration_mins: svc.duration_mins ?? null,
        total_cents: 0,
      }).select('id').single();
      if (ins.error || !ins.data) return json({ error: 'Could not create booking: ' + (ins.error?.message || '') }, 500);
      const bookingId = ins.data.id;
      await sb.from('booking_pets').insert({ booking_id: bookingId, pet_id: rq.pet_id });

      // TRU-221: an assigned lead is not terminal — it stays on the board as
      // meet_greet_booked until the admin moves it to transitioned/lost, so the
      // follow-through (first booking actually happening) is tracked.
      await sb.from('carer_requests').update({
        status: 'meet_greet_booked',
        assigned_provider_id: providerId,
        assigned_booking_id: bookingId,
      }).eq('id', reqId);

      // Tell the customer in-app (the carer's booking-request email is fired by the DB trigger).
      const { data: cp } = await sb.from('customer_profiles').select('user_id').eq('id', rq.customer_id).single();
      const { data: pp } = await sb.from('provider_profiles').select('user_id').eq('id', providerId).single();
      const { data: cu } = pp?.user_id ? await sb.from('users').select('first_name').eq('id', pp.user_id).single() : { data: null };
      if (cp?.user_id) {
        await sb.from('system_messages').insert({
          recipient_user_id: cp.user_id,
          body: `Good news — we found you a carer${cu?.first_name ? ` (${cu.first_name})` : ''} for your request. They'll confirm shortly.`,
          link_url: '/profile/',
          link_label: 'View my bookings',
        });
      }
      return json({ ok: true, booking_id: bookingId });
    }

    if (action === 'request_update') {
      if (!(await isAdmin(user.id))) return json({ error: 'Not authorised' }, 403);
      const reqId = String(payload.request_id || '');
      const status = String(payload.status || '');
      const adminNote = String(payload.admin_note || '').slice(0, 500);
      if (!['captured', 'called', 'founder_walking', 'sourcing_walker', 'meet_greet_booked',
            'transitioned', 'lost', 'closed'].includes(status)) return json({ error: 'Invalid status' }, 400);
      const resolved = ['transitioned', 'lost', 'closed'].includes(status);
      const upd = await sb.from('carer_requests').update({
        status,
        admin_note: adminNote || null,
        resolved_at: resolved ? new Date().toISOString() : null,
        resolved_by: resolved ? user.id : null,
      }).eq('id', reqId).select('id');
      if (upd.error || !upd.data?.length) return json({ error: 'Request not found' }, 404);
      return json({ ok: true });
    }

    return json({ error: `Unknown action: ${action}` }, 400);
  } catch (e) {
    console.error('stripe-api error', action, e);
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
