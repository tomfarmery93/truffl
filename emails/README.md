# Truffl Pets — email templates (React Email)

Branded [React Email](https://react.email) templates for Truffl's transactional
notifications and auth emails. This is an isolated workspace — it has its own
`package.json` and is **not** part of the static site or the GitHub Pages deploy.

## Develop

```bash
cd emails
npm install
npm run dev      # local preview at http://localhost:3000
```

The preview lists every template in `emails/`. `layout-preview.tsx` shows the
shared layout in use.

## Structure

- `components/TrufflEmailLayout.tsx` — the shared branded shell (header wordmark,
  palette, typography, button, footer) plus `Heading` / `Paragraph` / `Details`
  content helpers. Every template imports this.
- `lib/theme.ts` — brand colour + font tokens (mirrors the marketing palette).
- `lib/render.ts` — `renderEmail(element)` → HTML string. Used when exporting
  auth-email HTML to paste into Supabase; **not** used by the sending pipeline.
- `emails/` — individual templates (one default-exported component each).
- `RUNBOOK.md` — how production email actually sends, the DNS/deliverability
  picture, and how to run the QA sweep. **Read this before QA'ing anything.**

## What this workspace is (and isn't) used for

It is the design surface and the source of the **auth** email HTML (TRU-119).

It is **not** what sends your transactional email. The pipeline built in TRU-118
renders its own branded HTML inline inside
`supabase/functions/send-notification/index.ts` — a Deno port of the layout below —
because edge functions can't import this npm/React workspace. Nothing in
`supabase/` imports `renderEmail`.

Two practical consequences:

1. **Previewing a template here does not QA production email.** Use the sweep in
   `RUNBOOK.md`, which sends through the real path.
2. **Brand tokens exist twice** — here in `lib/theme.ts` and in
   `supabase/functions/_shared/email-theme.ts`. Change one, change the other; the
   CI job "Email brand tokens in sync" fails the build if they diverge.

Four production emails (`payment_failed`, `cover_cancellation`, and both
`carer_request` messages) have no React template here at all — they exist only in
the edge function.

## Fonts

The brand serif (Cormorant Garamond) is loaded as **progressive enhancement**
via `<Font>`. Gmail and most clients strip web fonts, so the layout is designed
to look right on the fallbacks — **Georgia** for headings, a system sans stack
for body. Never rely on the brand font loading.

## Render to HTML

```ts
import { renderEmail } from './lib/render';
import BookingConfirmed from './emails/booking-confirmed';

const html = await renderEmail(<BookingConfirmed /* props */ />);
// pass { plainText: true } for the text/plain alternative
```

## Status

Shipped: TRU-116 (this layout), TRU-117 (the 5 transactional templates),
TRU-118 (sending pipeline — note it renders inline, see above), TRU-119 (auth
email rebrand), TRU-120 (plain-text alternatives, token drift guard, QA sweep).

Open follow-ups:

- React templates for the four emails that currently exist only as inline HTML in
  the edge function.
- Auth email HTML is still pasted into the Supabase dashboard by hand — unversioned
  and invisible to CI (`RUNBOOK.md` → "Still manual").
- TRU-115 — point Supabase custom SMTP at Resend (dashboard task).
