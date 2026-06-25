/**
 * Send rendered Truffl email(s) to one or more inboxes via the Resend API.
 *
 *   RESEND_API_KEY=re_xxx npm run send                      # the layout preview
 *   EMAIL_TEMPLATE=booking-confirmed ... npm run send       # one template
 *   EMAIL_TEMPLATE=all ... npm run send                     # every exported template
 *   node send.mjs booking-confirmed                         # one template (arg form)
 *
 * `npm run send` runs `email export` first so out/*.html is fresh.
 * Override sender/recipients:
 *   EMAIL_FROM="Truffl Pets <hello@trufflpets.com>"   EMAIL_TO="a@x.com,b@y.com"
 *
 * Sender must be on the Resend-verified domain (trufflpets.com — TRU-113).
 */
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dirname, 'out');

const API_KEY = process.env.RESEND_API_KEY;
if (!API_KEY) {
  console.error('Missing RESEND_API_KEY. Run:  RESEND_API_KEY=re_xxx npm run send');
  process.exit(1);
}

const FROM = process.env.EMAIL_FROM || 'Truffl Pets <hello@trufflpets.com>';
const RECIPIENTS = (process.env.EMAIL_TO ||
  'tom_farmery@hotmail.co.uk,tomfarmery17@googlemail.com')
  .split(',').map(s => s.trim()).filter(Boolean);

// Per-template subject lines (falls back to a generic one).
const SUBJECTS = {
  'booking-request': 'New booking request (Truffl test)',
  'booking-confirmed': 'Your booking is confirmed (Truffl test)',
  'walk-started': "Your dog's walk has started (Truffl test)",
  'walk-completed': "Your dog's walk is complete (Truffl test)",
  'new-message': 'New message (Truffl test)',
  'layout-preview': 'Truffl email test',
};

const selected = process.env.EMAIL_TEMPLATE || process.argv[2] || 'layout-preview';
let templates;
if (selected === 'all') {
  templates = (await readdir(OUT_DIR)).filter(f => f.endsWith('.html')).map(f => f.replace(/\.html$/, ''));
} else {
  templates = [selected];
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// Resend free tier allows 2 requests/sec, so pace sends and retry on 429.
async function sendOne(payload) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (res.status !== 429) return res;
    await sleep(1200 * (attempt + 1)); // back off, then retry
  }
  return null;
}

let ok = 0, total = 0;
for (const tpl of templates) {
  const html = await readFile(join(OUT_DIR, `${tpl}.html`), 'utf8');
  const subject = process.env.EMAIL_SUBJECT || SUBJECTS[tpl] || `Truffl: ${tpl}`;
  console.log(`\n● ${tpl}`);
  for (const to of RECIPIENTS) {
    total++;
    const res = await sendOne({ from: FROM, to, subject, html });
    const data = res ? await res.json().catch(() => ({})) : {};
    if (res && res.ok) { console.log(`  ✓ ${to}  (id ${data.id})`); ok++; }
    else console.error(`  ✗ ${to}: ${res ? res.status : 'rate-limited'} ${JSON.stringify(data)}`);
    await sleep(600); // stay under 2 req/sec
  }
}
console.log(`\nDone — ${ok}/${total} sent across ${templates.length} template(s).`);
process.exit(ok === total ? 0 : 1);
