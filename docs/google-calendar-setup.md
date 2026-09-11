# Google Calendar sync: one-time setup

What Truffl needs from Google Cloud before a carer can press "Connect Google Calendar"
(GitHub #160). Everything else (tables, triggers, cron, the edge function) ships with the
repo. Allow twenty minutes.

## 1. Google Cloud project and consent screen

1. Open https://console.cloud.google.com/ and create a project called `Truffl` (or reuse
   an existing one; the Maps key can live in the same project).
2. **APIs & Services → Library**: enable **Google Calendar API**.
3. **APIs & Services → OAuth consent screen** (Google now calls this "Google Auth
   Platform → Branding / Audience"):
   - User type: **External**.
   - App name `Truffl`, support email, and the logo if you want it on the consent screen.
   - App domain `trufflpets.com`, privacy policy `https://trufflpets.com/privacy/`, terms
     `https://trufflpets.com/terms/`.
   - Authorised domain: `trufflpets.com` and `supabase.co` (the redirect lives on the
     Supabase project domain).
4. **Scopes**: add
   - `https://www.googleapis.com/auth/calendar.app.created` (non-sensitive: lets Truffl
     create and manage the calendars it created, which is the "Truffl" calendar)
   - `https://www.googleapis.com/auth/calendar.events.readonly` (sensitive: only asked
     for when a carer opts in to "also bring in events from my main calendar")
   - `openid`, `email`
5. **Audience / Test users**: the app stays in **Testing** for the pilot. Add each pilot
   carer's Google address here (up to 100). In Testing, Google expires refresh tokens
   after seven days, so pilot carers see a "Reconnect Google" button weekly; the sync
   page copes with that. Before launch, press **Publish app**. With only the
   `calendar.app.created` scope in use, publishing needs no verification review; the
   `events.readonly` scope is the one that triggers the review, so start it early.

## 2. OAuth client

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type **Web application**, name `Truffl web`.
3. Authorised redirect URI, exactly:

   ```
   https://gadflsntbnbnnxbpiral.supabase.co/functions/v1/google-calendar/callback
   ```

4. Copy the **Client ID** and **Client secret**.

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
