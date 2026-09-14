# Google Calendar sync: one-time setup

What Truffl needs from Google Cloud before a carer can press "Connect Google Calendar"
(GitHub #160). Everything else (tables, triggers, cron, the edge function) ships with the
repo. Allow twenty minutes.

## 1. Google Cloud project and the Auth Platform

Google Cloud itself is free and none of this needs a billing account; the Calendar API is
quota-limited, not metered.

1. Open https://console.cloud.google.com/ and create a project called `Truffl` (or reuse
   an existing one; the Maps key can live in the same project).
2. **APIs & Services → Library**: search for and enable **Google Calendar API**.
3. Open **Google Auth Platform** (search for it in the top bar; it replaced the old "OAuth
   consent screen" page). It shows "Google Auth Platform not configured yet" with a
   **Get started** button. Press it and fill in the four steps:
   - App information: app name `Truffl`, your support email.
   - Audience: **External**.
   - Contact information: your email.
   - Finish: tick the agreement, press **Create**.
4. **Branding** (left menu): the logo if you want it on the consent screen, app domain
   `trufflpets.com`, privacy policy `https://trufflpets.com/privacy/`, terms
   `https://trufflpets.com/terms/`, and under Authorised domains add `trufflpets.com`
   and `supabase.co` (the redirect lives on the Supabase project domain).
5. **Data Access** (left menu): press **Add or remove scopes**, search "calendar" and tick
   - `https://www.googleapis.com/auth/calendar.app.created` (non-sensitive: lets Truffl
     create and manage the calendars it created, which is the "Truffl" calendar)
   - `https://www.googleapis.com/auth/calendar.events.readonly` (sensitive: only asked
     for when a carer opts in to "also bring in events from my main calendar")

   then tick `openid` and `.../auth/userinfo.email` from the list, Update, Save.
6. **Audience** (left menu): publishing status stays **Testing** for the pilot. Under
   **Test users** add each pilot carer's Google address (up to 100). In Testing, Google
   expires refresh tokens after seven days, so pilot carers see a "Reconnect Google"
   button weekly; the sync page copes with that. Before launch, press **Publish app**.
   With only the `calendar.app.created` scope in use, publishing needs no verification
   review; the `events.readonly` scope is the one that triggers the review (Verification
   Center), so start it early.

## 2. OAuth client

1. **Clients** (left menu) → **Create client**.
2. Application type **Web application**, name `Truffl web`.
3. Authorised redirect URI, exactly:

   ```
   https://gadflsntbnbnnxbpiral.supabase.co/functions/v1/google-calendar/callback
   ```

4. Press Create and copy the **Client ID** and **Client secret** (the secret is shown
   once; download the JSON if you want a copy).

## 3. Supabase secrets

Supabase dashboard → Edge Functions → Secrets (or the CLI):

```
supabase secrets set GOOGLE_CLIENT_ID=...apps.googleusercontent.com
supabase secrets set GOOGLE_CLIENT_SECRET=GOCSPX-...
```

`WEBHOOK_SECRET` is already set (it is the shared secret in `private.stripe_config` that
the charge and email triggers use; the Google push trigger and the ten-minute poll reuse
it). `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected.

## 4. Deploy

```
supabase functions deploy google-calendar --no-verify-jwt
```

(`verify_jwt = false` is also recorded in `supabase/config.toml`.) The migration
`20260913000000_supply_google_calendar_sync.sql` creates the tables, the push triggers and
the `google-calendar-poll` cron job.

## 5. Try it

1. Sign in as a carer, open `/schedule/`, press **Sync calendar**, then **Connect Google
   Calendar**. Google shows the consent screen (with an "unverified app" interstitial
   while the app is in Testing; press Continue).
2. Back on `/schedule/` the message reads "Google Calendar connected". A calendar called
   **Truffl** now exists in that Google account with the carer's jobs and bookings in it.
3. Add an event to the Truffl calendar in Google. Within ten minutes (or straight away
   with **Sync now**) it appears on `/schedule/` with a **Google** tag.
4. Edit a job's time in Truffl; the Google event moves within seconds.

## What is stored, and where

| Data | Where | Who can read it |
|---|---|---|
| Refresh and access tokens | `private.google_tokens` | service role only, via `google_tokens_*` RPCs |
| Google account email, Truffl calendar id, sync tokens, status | `public.google_calendar_connections` | the carer (their own row) and the service role |
| Event id, etag and content hash per mirrored row | `public.calendar_event_links` | the carer (their own row) and the service role |

Disconnecting revokes the grant with Google, deletes all three, and leaves the Truffl
calendar in the carer's Google account (it is theirs). Account deletion does the same
through `admin_delete_account`.
