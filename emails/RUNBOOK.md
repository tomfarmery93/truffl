# Email runbook (TRU-120)

Operational reference for Truffl's email: where it actually sends from, how to QA
it, and what's still manual. None of this was written down before — it had to be
read off live DNS and the deployed function.

## Where email actually renders — read this first

There are **two** rendering paths and they are not the same code:

| | Renders | Used for |
|---|---|---|
| `supabase/functions/send-notification/index.ts` | inline `layout()` / `p()` / `detailsTable()` helpers | **all production transactional email** |
| `emails/` (React Email) | `components/TrufflEmailLayout.tsx` | design preview + the **auth** email HTML that gets pasted into Supabase |

Nothing imports `emails/lib/render.ts` — `renderEmail` has zero callers. So
**QA'ing the React previews checks HTML that never ships.** Always QA via the
sweep below, which sends through the production path.

Brand tokens therefore live in two runtimes that can't share a module:
`emails/lib/theme.ts` and `supabase/functions/_shared/email-theme.ts`. They had
already drifted once (the edge function's body font had lost `'DM Sans'`). CI job
**"Email brand tokens in sync"** fails the build if they stop matching — if you
change a colour or font, change both files.

## Sending setup (verified live)

- **Provider:** Resend. `FROM = Truffl Pets <notifications@trufflpets.com>`,
  `REPLY_TO = support@trufflpets.com` (both in `index.ts`).
- **Free tier:** 3,000/month, **100/day**. A full QA sweep is ~10 emails, so
  don't loop it. `sendEmail()` retries only on HTTP 429, 4 attempts, linear backoff.
- **Every message now ships `html` + `text`** (TRU-120). The text part is derived
  from the HTML by `_shared/email-text.ts`.

### DNS (nameservers: Porkbun — *not* Cloudflare)

| Record | Value | Purpose |
|---|---|---|
| `MX trufflpets.com` | `1 smtp.google.com` | **Inbound** → Google Workspace. This is why `support@` reaches the founder inbox. |
| `TXT trufflpets.com` | `v=spf1 include:_spf.porkbun.com ~all` | Apex SPF. Does **not** list Resend — correct, see below. |
| `TXT resend._domainkey.trufflpets.com` | `p=MIGfMA0…` | Resend DKIM, signs `d=trufflpets.com`. |
| `TXT send.trufflpets.com` | `v=spf1 include:amazonses.com ~all` | SPF for the **Return-Path** domain. |
| `MX send.trufflpets.com` | `10 feedback-smtp.ap-northeast-1.amazonses.com` | Bounce/complaint handling. |
| `TXT _dmarc.trufflpets.com` | `v=DMARC1; p=none;` | Monitor only, **no reporting address**. |

Why the apex SPF doesn't mention Resend, and why that's fine: Resend sends with a
Return-Path on `send.trufflpets.com`, so SPF is evaluated against *that* domain
(→ `amazonses.com`, passes). DMARC then aligns via **DKIM**, which signs for the
apex and matches the `From:` header domain. So SPF, DKIM and DMARC all pass.

**Recommended next (Tom's DNS):** add a reporting address so failures are visible
before tightening policy —
`v=DMARC1; p=none; rua=mailto:dmarc@trufflpets.com; fo=1` — then consider
`p=quarantine` once reports look clean for a few weeks.

## Running the QA sweep

Fires **every** production message body at one address, rendered by the real
production code. It reuses existing rows and **writes nothing**, so there is no
test data to clean up afterwards.

Recipients are allowlisted: the address must belong to a `users.is_admin = true`
user, or appear in the optional `QA_EMAIL_ALLOWLIST` function secret
(comma-separated). Anything else returns 400 — so a leaked `WEBHOOK_SECRET`
still can't turn this into an open relay. Subjects are prefixed `[QA]`.

From the SQL editor (no secret handling — it reads the config row):

```sql
select net.http_post(
  url     := (select function_url from private.email_config where id = 1),
  headers := jsonb_build_object(
               'Content-Type', 'application/json',
               'x-webhook-secret', (select webhook_secret from private.email_config where id = 1)
             ),
  body    := jsonb_build_object('type', 'preview', 'to', 'you@example.com'),
  -- REQUIRED: the sweep sends ~10 emails sequentially and takes 10-15s.
  -- pg_net's default timeout is 5s, so without this the call is recorded as a
  -- client-side timeout even though the function ran fine and the mail went out.
  timeout_milliseconds := 60000
);
-- then, ~15s later (pg_net only writes the response after the calling txn commits):
select status_code, content from net._http_response order by created desc limit 1;
```

The response reports `sent`, `allOk`, and a `skipped` list. HTTP **200 is only
returned when every send succeeded**; a partial failure returns 502 with the
per-message detail. A type is skipped when no source row exists yet (e.g.
`cover_cancellation` before any walk has gone through the cover flow) — that's
expected, not a failure.

Because the sweep sends one message per production body, it costs ~10 of the
100/day Resend allowance. Don't loop it.

### What to check in each client (Gmail, Outlook, Apple Mail)

- Layout holds; wordmark, terracotta button and cream background render.
- **Headings fall back to Georgia** — Gmail strips web fonts, so Cormorant
  Garamond will not load. That's by design; it must still look right.
- Details tables align; CTA button is tappable on mobile width.
- Message lands in the **primary inbox**, not Promotions/Spam.
- View source → confirm a `text/plain` part exists alongside the HTML.
- Received headers → `spf=pass`, `dkim=pass`, `dmarc=pass`.

## Still manual (not code)

- **TRU-115 — Supabase custom SMTP → Resend.** Dashboard-only; `supabase/config.toml`
  has no `[auth]` block to change. In Supabase → Project Settings → Authentication →
  SMTP Settings: host `smtp.resend.com`, port `465`, username `resend`, password =
  a Resend API key, sender `notifications@trufflpets.com`, sender name `Truffl Pets`.
  Without this, auth email uses Supabase's built-in sender, which is rate-limited to
  a couple of emails an hour and only delivers to team addresses — unusable in production.
- **Auth email templates** are exported from `emails/` and pasted by hand into
  Supabase → Authentication → Email Templates (TRU-119). They are **not** versioned
  or covered by CI; re-paste after any layout change. Supabase's `{{ .ConfirmationURL }}`
  style variables must survive the paste intact.
- **DMARC `rua=` / `p=quarantine`** — see above.
