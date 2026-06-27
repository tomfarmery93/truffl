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
//
// Required function secrets (Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY   - sk_test_… (platform secret key)
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITE = 'https://trufflpets.com';

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

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

Deno.serve(async (req) => {
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
        refresh_url: `${SITE}/dashboard/?payouts=refresh`,
        return_url: `${SITE}/dashboard/?payouts=return`,
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

    return json({ error: `Unknown action: ${action}` }, 400);
  } catch (e) {
    console.error('stripe-api error', action, e);
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
