/**
 * Send a rendered Truffl email to one or more inboxes via the Resend API.
 *
 *   RESEND_API_KEY=re_xxx npm run send
 *
 * `npm run send` runs `email export` first, so out/layout-preview.html is fresh.
 * Override the sender or recipients with env vars if needed:
 *   EMAIL_FROM="Truffl Pets <hello@trufflpets.com>"
 *   EMAIL_TO="a@x.com,b@y.com"
 *
 * Sender must be on the Resend-verified domain (trufflpets.com — TRU-113).
 */
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

const API_KEY = process.env.RESEND_API_KEY;
if (!API_KEY) {
  console.error('Missing RESEND_API_KEY. Run:  RESEND_API_KEY=re_xxx npm run send');
  process.exit(1);
}

const FROM = process.env.EMAIL_FROM || 'Truffl Pets <hello@trufflpets.com>';
const RECIPIENTS = (process.env.EMAIL_TO ||
  'tom_farmery@hotmail.co.uk,tomfarmery17@googlemail.com')
  .split(',').map(s => s.trim()).filter(Boolean);
const SUBJECT = process.env.EMAIL_SUBJECT || 'Your booking is confirmed (Truffl email test)';

const html = await readFile(join(__dirname, 'out', 'layout-preview.html'), 'utf8');

let ok = 0;
for (const to of RECIPIENTS) {
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to, subject: SUBJECT, html }),
  });
  const data = await res.json().catch(() => ({}));
  if (res.ok) { console.log(`✓ sent to ${to}  (id ${data.id})`); ok++; }
  else console.error(`✗ failed for ${to}: ${res.status} ${JSON.stringify(data)}`);
}
console.log(`\nDone — ${ok}/${RECIPIENTS.length} sent.`);
process.exit(ok === RECIPIENTS.length ? 0 : 1);
