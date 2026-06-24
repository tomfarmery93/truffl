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
- `lib/render.ts` — `renderEmail(element)` → HTML string for the send call
  (Resend / Supabase auth / the sending Edge Function in TRU-118).
- `emails/` — individual templates (one default-exported component each).

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

## Next

- TRU-117 — the 5 transactional templates on top of this layout.
- TRU-119 — auth email rebrand (paste rendered HTML into Supabase auth template
  fields, keeping Supabase's `{{ .ConfirmationURL }}` etc.).
- TRU-118 — sending pipeline (Supabase webhook → Edge Function → Resend) that
  calls `renderEmail`.
