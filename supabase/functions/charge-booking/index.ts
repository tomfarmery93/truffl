// TRU-146: charge a completed booking off-session via a Stripe destination charge.
// Invoked server-to-server by the DB trigger (pg_net) — authenticates with the shared
// x-webhook-secret header (verify_jwt off), same pattern as send-notification.
//
// Cadence-agnostic engine: charges one booking now (triggered on completion). A later
// fortnightly per-(customer,carer) batch job can reuse the same Stripe call by summing
// bookings and stamping the same PaymentIntent id on each.
//
// Required function secrets:
//   STRIPE_SECRET_KEY, WEBHOOK_SECRET  (+ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injected)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Platform take rate in basis points. 1500 = 15%. Set to 0 for the 0%-commission launch
// period — the application fee is then omitted entirely (Stripe requires it to be positive).
const PLATFORM_FEE_BPS = 1500;
const CURRENCY = 'aud';

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

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

async function stripe(path: string, method: 'GET' | 'POST', body?: Record<string, unknown>, idempotencyKey?: string) {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
    'Content-Type': 'application/x-www-form-urlencoded',
  };
  if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
  const res = await fetch(`https://api.stripe.com/v1/${path}`, { method, headers, body: body ? encode(body) : undefined });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || `Stripe ${path} failed (${res.status})`);
  return data;
}

async function markFailed(bookingId: string, piId?: string) {
  await sb.from('bookings')
    .update({ payment_status: 'failed', payment_processing_at: null, ...(piId ? { stripe_payment_intent_id: piId } : {}) })
    .eq('id', bookingId);
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (req.headers.get('x-webhook-secret') !== WEBHOOK_SECRET) return json({ error: 'Unauthorized' }, 401);

  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return json({ error: 'Bad JSON' }, 400); }
  const bookingId = String(payload.booking_id || '');
  if (!bookingId) return json({ error: 'Missing booking_id' }, 400);

  try {
    const { data: b } = await sb.from('bookings')
      .select('id,total_cents,customer_id,provider_id,is_meet_and_greet,payment_status,cover_status')
      .eq('id', bookingId).single();
    if (!b) return json({ error: 'booking not found' }, 404);
    if (b.is_meet_and_greet || (b.total_cents || 0) <= 0) return json({ skipped: 'not chargeable' });
    // TRU-139: a covered walk completed by the Truffl backup. Owner pays the full
    // original price; NO destination transfer and NO application fee — the share
    // that would have gone to the original walker is retained by the platform
    // (they cancelled; they are not paid for this booking).
    const covered = b.cover_status === 'reassigned';

    // Atomic claim: only one invocation may move unpaid/failed -> processing.
    // TRU-173: stamp the claim time so the reaper cron can detect bookings stranded in
    // 'processing' (e.g. if this function crashes after the claim) and retry them.
    const { data: claimed } = await sb.from('bookings')
      .update({ payment_status: 'processing', payment_processing_at: new Date().toISOString() })
      .eq('id', bookingId).in('payment_status', ['unpaid', 'failed'])
      .select('id');
    if (!claimed || !claimed.length) return json({ skipped: 'already processing or paid' });

    const { data: cp } = await sb.from('customer_profiles').select('stripe_customer_id').eq('id', b.customer_id).single();
    if (!cp?.stripe_customer_id) { await markFailed(bookingId); return json({ error: 'customer has no Stripe customer' }, 400); }

    const cust = await stripe(`customers/${cp.stripe_customer_id}`, 'GET');
    const pm = cust?.invoice_settings?.default_payment_method;
    if (!pm) { await markFailed(bookingId); return json({ error: 'no saved card on file' }, 400); }

    const piBody: Record<string, unknown> = {
      amount: b.total_cents,
      currency: CURRENCY,
      customer: cp.stripe_customer_id,
      payment_method: pm,
      off_session: true,
      confirm: true,
      'metadata[booking_id]': bookingId,
    };
    let fee = 0;
    if (!covered) {
      const { data: pp } = await sb.from('provider_profiles').select('stripe_account_id').eq('id', b.provider_id).single();
      if (!pp?.stripe_account_id) { await markFailed(bookingId); return json({ error: 'carer has no payout account' }, 400); }
      piBody['transfer_data[destination]'] = pp.stripe_account_id;
      fee = Math.round((b.total_cents * PLATFORM_FEE_BPS) / 10000);
      if (fee > 0) piBody['application_fee_amount'] = fee; // omitted at 0% — Stripe requires it positive
    }

    let pi;
    try {
      // Idempotency guard against a pg_net retry double-charging the same booking.
      pi = await stripe('payment_intents', 'POST', piBody, `charge_${bookingId}`);
    } catch (e) {
      await markFailed(bookingId);
      return json({ ok: false, error: 'charge failed', detail: String((e as Error)?.message || e) }, 402);
    }

    if (pi.status === 'succeeded') {
      await sb.from('bookings').update({
        payment_status: 'paid',
        stripe_payment_intent_id: pi.id,
        application_fee_cents: fee,
        charged_at: new Date().toISOString(),
        payment_processing_at: null,
      }).eq('id', bookingId);
      return json({ ok: true, payment_intent: pi.id, amount: b.total_cents, application_fee_cents: fee, covered });
    }

    // requires_action etc. — an off-session charge can't complete; flag for follow-up.
    await sb.from('bookings').update({ payment_status: 'failed', stripe_payment_intent_id: pi.id, payment_processing_at: null }).eq('id', bookingId);
    return json({ ok: false, status: pi.status, payment_intent: pi.id });
  } catch (e) {
    console.error('charge-booking error', bookingId, e);
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
