// TRU-228: in-app account deletion.
//
// Apple guideline 5.1.1(v) requires deletion to be initiated AND completed in-app.
// This is the only thing that can complete it: the sweep needs the service role, and
// deleting the auth user needs the admin API — neither is safe to expose to a browser.
//
// verify_jwt is DISABLED, same reason as stripe-api and geo-api: the browser CORS
// preflight (OPTIONS) carries no JWT, so the platform gate would reject it and the call
// would never reach us. We authenticate in-function via auth.getUser instead.
//
// ORDER MATTERS AND IS NOT INTERCHANGEABLE. public.users has NO foreign key to
// auth.users (both ids are populated by the handle_new_user trigger), so deleting the
// auth user first would orphan the entire public graph with no way to find it again:
//   1. admin_delete_account()   — anonymise + purge, and re-check the blockers
//   2. storage objects           — the actual files, not just the DB rows
//   3. auth.admin.deleteUser()   — last, and only if 1 and 2 succeeded
//
// If step 1 raises (future bookings, unsettled payments), we return 409 and the account
// is left completely untouched — the function is a no-op on the failure path.
//
// Required secrets: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const sb = createClient(SUPABASE_URL, SERVICE_ROLE, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// Both buckets key objects by the owner's auth uid: `${authUid}/avatar_…`,
// `${authUid}/pet_…`, and the same prefix for walk photos.
const BUCKETS = ['profile-photos', 'walk-photos'];

/** Remove every object under `<userId>/` in a bucket. Returns how many were removed. */
async function purgeBucket(bucket: string, userId: string): Promise<number> {
  const { data, error } = await sb.storage.from(bucket).list(userId, { limit: 1000 });
  if (error || !data || data.length === 0) return 0;

  const paths = data.map((f) => `${userId}/${f.name}`);
  const { error: rmErr } = await sb.storage.from(bucket).remove(paths);
  if (rmErr) throw new Error(`storage cleanup failed for ${bucket}: ${rmErr.message}`);
  return paths.length;
}

Deno.serve(async (req) => {
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

  // A deliberate speed bump. The UI asks the user to type DELETE; requiring it here too
  // means a stray POST to this endpoint cannot wipe an account by accident.
  if (String(payload.confirm || '').trim().toUpperCase() !== 'DELETE') {
    return json({ error: 'Confirmation phrase missing' }, 400);
  }

  // 1. The sweep. Raises on blockers, in which case nothing has been changed.
  const { data: sweep, error: sweepErr } = await sb.rpc('admin_delete_account', { p_user_id: user.id });
  if (sweepErr) {
    const msg = sweepErr.message || 'Deletion failed';
    // Blocker messages are written to be shown to the user as-is.
    const isBlocked = /^Cannot delete:/i.test(msg);
    return json({ error: msg, blocked: isBlocked }, isBlocked ? 409 : 500);
  }

  // 2. Storage. After the sweep (which already nulled the URLs pointing here) and before
  //    the auth user is deleted, so a failure here still leaves a recoverable account.
  let filesRemoved = 0;
  try {
    for (const bucket of BUCKETS) filesRemoved += await purgeBucket(bucket, user.id);
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }

  // 3. The auth user, last. Past this point the account cannot sign in again.
  const { error: delErr } = await sb.auth.admin.deleteUser(user.id);
  if (delErr) {
    // The public-side data is already anonymised and the user is delisted, so this is
    // not a security hole — but the login still works, so it must be surfaced loudly.
    return json({
      error: 'Your data was removed but the login could not be closed. Please contact support@trufflpets.com.',
      detail: delErr.message,
    }, 500);
  }

  return json({ ok: true, ...(sweep as Record<string, unknown>), files_removed: filesRemoved });
});
