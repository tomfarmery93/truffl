// TRU-146: Stripe webhook — reconcile charge + connected-account outcomes.
// verify_jwt off; we verify Stripe's signature ourselves (HMAC-SHA256 over `${t}.${rawBody}`)
// with STRIPE_WEBHOOK_SIGNING_SECRET, so no SDK is needed.
//
// Handles:
//   payment_intent.succeeded       -> booking.payment_status = paid
//   payment_intent.payment_failed  -> booking.payment_status = failed
//   account.updated                -> provider_profiles payout/charge readiness (so a carer
//                                     finishing onboarding flips payouts_enabled automatically)
//
// Required function secrets:
//   STRIPE_WEBHOOK_SIGNING_SECRET  (whsec_…, from the registered webhook endpoint)
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injected automatically)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SIGNING_SECRET = Deno.env.get('STRIPE_WEBHOOK_SIGNING_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

// Verify Stripe's signature header: "t=<ts>,v1=<hex hmac>".
async function verifySignature(rawBody: string, sigHeader: string | null, secret: string): Promise<boolean> {
  if (!sigHeader) return false;
  const parts: Record<string, string> = {};
  for (const seg of sigHeader.split(',')) {
    const i = seg.indexOf('=');
    if (i > 0) parts[seg.slice(0, i)] = seg.slice(i + 1);
  }
  const t = parts['t'], v1 = parts['v1'];
  if (!t || !v1) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${rawBody}`));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  if (expected.length !== v1.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ v1.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const raw = await req.text();
  if (!(await verifySignature(raw, req.headers.get('Stripe-Signature'), SIGNING_SECRET))) {
    return new Response('Bad signature', { status: 400 });
  }

  let evt: Record<string, unknown>;
  try { evt = JSON.parse(raw); } catch { return new Response('Bad JSON', { status: 400 }); }

  const type = String(evt.type || '');
  const obj = ((evt.data as Record<string, unknown>)?.object || {}) as Record<string, unknown>;

  try {
    if (type === 'payment_intent.succeeded') {
      const bid = (obj.metadata as Record<string, string>)?.booking_id;
      if (bid) {
        await sb.from('bookings')
          .update({ payment_status: 'paid', stripe_payment_intent_id: obj.id as string, charged_at: new Date().toISOString() })
          .eq('id', bid).neq('payment_status', 'paid');
      }
    } else if (type === 'payment_intent.payment_failed') {
      const bid = (obj.metadata as Record<string, string>)?.booking_id;
      if (bid) {
        await sb.from('bookings')
          .update({ payment_status: 'failed', stripe_payment_intent_id: obj.id as string })
          .eq('id', bid).neq('payment_status', 'paid');
      }
    } else if (type === 'account.updated') {
      await sb.from('provider_profiles')
        .update({ payouts_enabled: !!obj.payouts_enabled, charges_enabled: !!obj.charges_enabled })
        .eq('stripe_account_id', obj.id as string);
    }
    return new Response(JSON.stringify({ received: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  } catch (e) {
    console.error('stripe-webhook error', type, e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
