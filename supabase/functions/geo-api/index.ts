// TRU-156: carer service-area management (travel-time isochrones + radius).
// verify_jwt is DISABLED (the browser CORS preflight carries no JWT — same
// reasoning as stripe-api); the caller is authenticated in-function via
// auth.getUser. The OpenRouteService key lives in private.geo_config and is
// read through a service_role-only definer fn — the private schema is not
// REST-exposed (the TRU-138 lesson).
//
// The isochrone is computed ONCE per settings save and stored as a polygon on
// provider_profiles; search_carers does ST_Covers against it with a radius
// fallback, so search itself never calls a routing API.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

const TRAVEL_MINUTES = [10, 15, 20, 30, 45, 60];

Deno.serve(async (req) => {
  // Per-request CORS (origin allow-list) — TRU-200. Local `json` closes over it.
  const CORS = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: { user }, error: uerr } = await sb.auth.getUser(jwt);
  if (uerr || !user) return json({ error: 'Not authenticated' }, 401);

  let payload: Record<string, unknown> = {};
  try { payload = await req.json(); } catch { /* empty body ok */ }
  const action = String(payload.action || '');

  try {
    if (action === 'set_service_area') {
      const mode = String(payload.mode || '');

      if (mode === 'radius') {
        const km = Math.round(Number(payload.radius_km));
        if (!(km >= 1 && km <= 30)) return json({ error: 'Radius must be between 1 and 30 km' }, 400);
        const { data, error } = await sb.rpc('apply_radius_area', { p_user_id: user.id, p_radius_km: km });
        if (error) return json({ error: error.message }, 500);
        return json(data);
      }

      if (mode === 'travel') {
        const mins = Math.round(Number(payload.minutes));
        if (!TRAVEL_MINUTES.includes(mins)) {
          return json({ error: `Travel time must be one of ${TRAVEL_MINUTES.join('/')} minutes` }, 400);
        }
        const { data: lnglat } = await sb.rpc('provider_lnglat', { p_user_id: user.id });
        if (!lnglat) return json({ error: 'Set your suburb first so we know where home is' }, 400);
        const { data: key } = await sb.rpc('get_geo_config');
        if (!key) return json({ error: 'Travel-time areas are not configured yet' }, 503);

        const res = await fetch('https://api.openrouteservice.org/v2/isochrones/driving-car', {
          method: 'POST',
          headers: { Authorization: key as string, 'Content-Type': 'application/json' },
          body: JSON.stringify({ locations: [lnglat], range: [mins * 60] }),
        });
        const iso = await res.json();
        const geometry = iso?.features?.[0]?.geometry;
        if (!res.ok || !geometry) {
          console.error('ORS error', res.status, JSON.stringify(iso).slice(0, 300));
          return json({ error: 'Could not compute your travel-time area — try again shortly' }, 502);
        }
        const { data, error } = await sb.rpc('apply_service_area', { p_user_id: user.id, p_geojson: geometry, p_minutes: mins });
        if (error) return json({ error: error.message }, 500);
        return json(data);
      }

      return json({ error: 'Unknown mode' }, 400);
    }

    return json({ error: `Unknown action: ${action}` }, 400);
  } catch (e) {
    console.error('geo-api error', action, e);
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
