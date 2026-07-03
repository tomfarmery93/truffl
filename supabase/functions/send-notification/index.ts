// TRU-118: transactional email sending pipeline.
// DB triggers (pg_net) POST an event here; this function resolves the recipients/data,
// renders the branded HTML, and sends via Resend. Called server-to-server only, so it
// authenticates with a shared secret header (verify_jwt is disabled for this function).
//
// Required function secrets (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY     - Resend API key
//   WEBHOOK_SECRET     - shared secret the triggers send as x-webhook-secret
//   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('WEBHOOK_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const FROM = 'Truffl Pets <notifications@trufflpets.com>';
const REPLY_TO = 'support@trufflpets.com'; // TRU-114 forwarding
const SITE = 'https://trufflpets.com';

const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

const SERVICE_LABELS: Record<string, string> = {
  dog_walking: 'Dog walking', dog_boarding: 'Dog boarding', dog_sitting: 'Dog sitting',
  dog_daycare: 'Dog daycare', drop_in: 'Drop-in visit', pet_sitting: 'Pet sitting',
};

function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"]/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
}

function fmtWhen(iso: string | null, mins?: number | null): string {
  if (!iso) return 'To be arranged';
  try {
    const d = new Date(iso);
    const base = d.toLocaleString('en-AU', {
      weekday: 'short', day: 'numeric', month: 'short',
      hour: 'numeric', minute: '2-digit', timeZone: 'Australia/Sydney',
    });
    return mins ? `${base} · ${mins} min` : base;
  } catch { return iso; }
}

// ── Branded layout (Deno port of TrufflEmailLayout; keep visually in sync) ──
function layout(opts: { preview: string; heading: string; body: string; cta?: { label: string; href: string }; footnote?: string }): string {
  const C = { cream: '#F7F3EE', white: '#FFFFFF', border: '#E7DFD6', brown: '#5C4033', terracotta: '#C4866A', terracottaDark: '#B8795C', text: '#3A2E28', textMid: '#7A6860', textLight: '#A8978E' };
  const headingFont = "'Cormorant Garamond', Georgia, 'Times New Roman', serif";
  const bodyFont = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";
  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:24px 0;background:${C.cream};font-family:${bodyFont};">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${esc(opts.preview)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;margin:0 auto;padding:0 16px;">
  <tr><td style="text-align:center;padding:8px 0 20px;">
    <a href="${SITE}" style="text-decoration:none;">
      <span style="font-family:${headingFont};font-style:italic;font-size:30px;color:${C.brown};letter-spacing:-0.5px;vertical-align:middle;">truffl</span>
      <span style="font-size:11px;font-weight:600;letter-spacing:4px;color:${C.textLight};margin-left:8px;vertical-align:middle;">PETS</span>
    </a>
  </td></tr>
  <tr><td style="background:${C.white};border:1px solid ${C.border};border-radius:16px;padding:32px 28px;">
    <h1 style="font-family:${headingFont};font-weight:500;font-size:26px;line-height:1.2;color:${C.brown};margin:0 0 14px;">${opts.heading}</h1>
    ${opts.body}
  </td></tr>
  ${opts.cta ? `<tr><td style="text-align:center;padding:24px 0 4px;">
    <a href="${esc(opts.cta.href)}" style="background:${C.terracotta};color:${C.white};font-size:15px;font-weight:500;text-decoration:none;padding:14px 32px;border-radius:999px;display:inline-block;">${esc(opts.cta.label)}</a>
  </td></tr>` : ''}
  ${opts.footnote ? `<tr><td style="text-align:center;font-size:13px;line-height:1.6;color:${C.textMid};padding:18px 8px 0;">${esc(opts.footnote)}</td></tr>` : ''}
  <tr><td style="padding:18px 0;"><hr style="border:none;border-top:1px solid ${C.border};margin:0;"></td></tr>
  <tr><td style="text-align:center;">
    <p style="font-size:13px;color:${C.textMid};margin:0 0 6px;"><a href="${SITE}" style="color:${C.terracottaDark};text-decoration:none;">Truffl Pets</a> · Sydney's trusted pet care</p>
    <p style="font-size:12px;color:${C.textLight};margin:0 0 6px;"><a href="${SITE}/trust-and-safety/" style="color:${C.terracottaDark};text-decoration:none;">Trust &amp; safety</a> &nbsp;·&nbsp; <a href="${SITE}/privacy/" style="color:${C.terracottaDark};text-decoration:none;">Privacy</a></p>
    <p style="font-size:12px;color:${C.textLight};margin:0;">© Truffl Pets · Sydney, NSW</p>
  </td></tr>
</table></body></html>`;
}

function p(text: string): string {
  return `<p style="font-size:15px;line-height:1.65;color:#3A2E28;margin:0 0 14px;">${text}</p>`;
}
function detailsTable(rows: [string, string][]): string {
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F7F3EE;border-radius:12px;padding:8px 16px;margin:8px 0 4px;">
    ${rows.map(([k, v]) => `<tr>
      <td style="font-size:13px;color:#7A6860;padding:10px 0;border-bottom:1px solid #E7DFD6;">${esc(k)}</td>
      <td style="font-size:14px;font-weight:500;color:#5C4033;padding:10px 0;border-bottom:1px solid #E7DFD6;text-align:right;">${esc(v)}</td>
    </tr>`).join('')}
  </table>`;
}

// ── Recipient/data resolution ──
async function loadBooking(bookingId: string) {
  const { data: b } = await sb.from('bookings').select('*').eq('id', bookingId).single();
  if (!b) throw new Error('booking not found: ' + bookingId);
  const [cp, pp, pet, svc] = await Promise.all([
    sb.from('customer_profiles').select('user_id').eq('id', b.customer_id).single(),
    sb.from('provider_profiles').select('user_id').eq('id', b.provider_id).single(),
    b.pet_id ? sb.from('pets').select('name').eq('id', b.pet_id).single() : Promise.resolve({ data: null }),
    b.service_id ? sb.from('provider_services').select('service_type,duration_mins').eq('id', b.service_id).single() : Promise.resolve({ data: null }),
  ]);
  const [customer, provider] = await Promise.all([
    sb.from('users').select('email,first_name').eq('id', cp.data?.user_id).single(),
    sb.from('users').select('email,first_name').eq('id', pp.data?.user_id).single(),
  ]);
  return {
    booking: b,
    customer: customer.data, provider: provider.data,
    petName: pet.data?.name || 'your pet',
    serviceLabel: svc.data ? (SERVICE_LABELS[svc.data.service_type] || svc.data.service_type) : 'Service',
    durationMins: svc.data?.duration_mins ?? null,
  };
}

// ── Build the email for an event → { to[], subject, html } messages ──
async function buildMessages(type: string, payload: Record<string, unknown>) {
  const out: { to: string; subject: string; html: string }[] = [];

  if (type === 'booking_request') {
    const d = await loadBooking(payload.booking_id as string);
    if (!d.provider?.email) return out;
    out.push({
      to: d.provider.email,
      subject: `New booking request from ${d.customer?.first_name || 'a customer'}`,
      html: layout({
        preview: `New booking request from ${d.customer?.first_name || 'a customer'}`,
        heading: 'You have a new booking request',
        body: p(`Hi ${esc(d.provider.first_name || 'there')}, ${esc(d.customer?.first_name || 'a customer')} would like to book you for ${esc(d.petName)}.`) +
          detailsTable([['Customer', d.customer?.first_name || 'Customer'], ['Pet', d.petName], ['Service', d.serviceLabel], ['When', fmtWhen(d.booking.scheduled_at, d.durationMins)]]) +
          p('The sooner you respond, the better the experience for the owner.'),
        cta: { label: 'Review request', href: `${SITE}/dashboard/` },
        footnote: "You're receiving this because you're a carer on Truffl Pets.",
      }),
    });
  } else if (type === 'booking_confirmed') {
    const d = await loadBooking(payload.booking_id as string);
    if (!d.customer?.email) return out;
    out.push({
      to: d.customer.email,
      subject: `Your booking with ${d.provider?.first_name || 'your carer'} is confirmed`,
      html: layout({
        preview: 'Your booking is confirmed',
        heading: 'Your booking is confirmed',
        body: p(`Hi ${esc(d.customer.first_name || 'there')}, good news — ${esc(d.provider?.first_name || 'your carer')} has confirmed your booking for ${esc(d.petName)}.`) +
          detailsTable([['Service', d.serviceLabel], ['Carer', d.provider?.first_name || 'Carer'], ['Pet', d.petName], ['When', fmtWhen(d.booking.scheduled_at, d.durationMins)]]) +
          p("We'll let you know the moment the walk starts so you can follow along live."),
        cta: { label: 'View booking', href: `${SITE}/track/?booking=${d.booking.id}` },
        footnote: "You're receiving this because you have a booking with Truffl Pets.",
      }),
    });
  } else if (type === 'payment_failed') {
    const d = await loadBooking(payload.booking_id as string);
    if (!d.customer?.email) return out;
    const amount = d.booking.total_cents ? `$${(d.booking.total_cents / 100).toFixed(2)}` : 'the amount due';
    out.push({
      to: d.customer.email,
      subject: `Payment didn't go through for ${d.petName}'s ${d.serviceLabel.toLowerCase()}`,
      html: layout({
        preview: "We couldn't process your payment",
        heading: "We couldn't process your payment",
        body: p(`Hi ${esc(d.customer.first_name || 'there')}, we tried to charge ${amount} for ${esc(d.petName)}'s ${esc(d.serviceLabel.toLowerCase())} with ${esc(d.provider?.first_name || 'your carer')}, but it didn't go through — usually a small card issue.`) +
          p('Pop back in and retry whenever you’re ready — it only takes a moment.'),
        cta: { label: 'Retry payment', href: `${SITE}/profile/` },
        footnote: 'Your carer has already provided the service, so please retry soon.',
      }),
    });
  } else if (type === 'cover_cancellation') {
    // TRU-138: a covered walk was cancelled by its walker — page every admin
    // immediately with everything needed to act. This is the ONE operational
    // surface where stored access detail (TRU-135) appears; the footnote asks
    // for the email to be deleted once the walk is covered.
    const d = await loadBooking(payload.booking_id as string);
    const { data: admins } = await sb.from('users').select('email,first_name').eq('is_admin', true);
    if (!admins?.length) return out;
    const { data: cover } = await sb.rpc('get_cover_details', { p_booking_id: d.booking.id });
    const c = (cover ?? {}) as Record<string, string | null>;

    // Per-dog handling notes, linked from the pet profile (booking_pets with the
    // legacy single-pet fallback). The service client bypasses RLS.
    const { data: bps } = await sb.from('booking_pets').select('pet_id').eq('booking_id', d.booking.id);
    const petIds = (bps?.length ? bps.map((r: { pet_id: string }) => r.pet_id) : [d.booking.pet_id]).filter(Boolean);
    const { data: petRows } = petIds.length
      ? await sb.from('pets').select('name,breed,behaviour_notes,medical_notes,vet_name,vet_phone').in('id', petIds)
      : { data: [] as never[] };
    const dogs = (petRows ?? []) as { name: string; breed: string | null; behaviour_notes: string | null; medical_notes: string | null; vet_name: string | null; vet_phone: string | null }[];
    const dogNames = dogs.map((p) => p.name).join(' & ') || d.petName;

    const windowStr = d.booking.window_end_at
      ? `${fmtWhen(d.booking.scheduled_at, null)}–${new Date(d.booking.window_end_at).toLocaleTimeString('en-AU', { hour: 'numeric', minute: '2-digit', timeZone: 'Australia/Sydney' })}${d.durationMins ? ` · ${d.durationMins} min` : ''}`
      : fmtWhen(d.booking.scheduled_at, d.durationMins);

    const rows: [string, string][] = [
      ['Dog', dogs.map((p) => p.breed ? `${p.name} (${p.breed})` : p.name).join(' & ') || d.petName],
      ['Window', windowStr],
      ['Address', [c.address, c.suburb, c.postcode].filter(Boolean).join(', ') || '⚠ missing'],
      ['Lockbox', c.access_location || '⚠ missing — contact owner'],
      ['Code', c.access_code || '⚠ missing'],
    ];
    if (c.access_notes) rows.push(['Access notes', c.access_notes]);
    rows.push(
      ['Owner', c.owner_name || 'Owner'],
      ['Owner phone', c.owner_phone || '—'],
      ['Owner email', c.owner_email || '—'],
      ['Original walker', d.provider?.first_name || '—'],
      ['Reason', d.booking.cancel_reason || '—'],
      ['Late (<3h notice)', d.booking.late_cancellation ? 'YES' : 'no'],
    );

    const notesHtml = dogs
      .map((pet) => {
        const bits = [];
        if (pet.behaviour_notes) bits.push(`Behaviour: ${esc(pet.behaviour_notes)}`);
        if (pet.medical_notes) bits.push(`Medical: ${esc(pet.medical_notes)}`);
        if (pet.vet_name || pet.vet_phone) bits.push(`Vet: ${esc([pet.vet_name, pet.vet_phone].filter(Boolean).join(' · '))}`);
        return bits.length ? p(`<b>${esc(pet.name)}</b> — ${bits.join(' · ')}`) : '';
      })
      .filter(Boolean)
      .join('');

    for (const admin of admins) {
      if (!admin.email) continue;
      out.push({
        to: admin.email,
        subject: `🚨 Cover needed — ${dogNames} · ${fmtWhen(d.booking.scheduled_at, null)}`,
        html: layout({
          preview: `Covered walk cancelled — ${dogNames} needs cover`,
          heading: 'A covered walk needs you',
          body: p(`${esc(d.provider?.first_name || 'The walker')} cancelled a covered ${esc(d.serviceLabel.toLowerCase())}. Everything you need is below.`) +
            detailsTable(rows) +
            (notesHtml || p('No handling notes on file.')),
          cta: { label: 'Open the admin console', href: `${SITE}/admin/` },
          footnote: 'This email contains entry access details — delete it once the walk is covered.',
        }),
      });
    }
  } else if (type === 'walk_started') {
    const { data: ws } = await sb.from('walk_sessions').select('booking_id').eq('id', payload.walk_session_id as string).single();
    if (!ws) return out;
    const d = await loadBooking(ws.booking_id);
    if (!d.customer?.email) return out;
    out.push({
      to: d.customer.email,
      subject: `${d.provider?.first_name || 'Your carer'} has started ${d.petName}'s walk`,
      html: layout({
        preview: `${d.petName}'s walk has started`,
        heading: `${esc(d.petName)}'s walk has started`,
        body: p(`Hi ${esc(d.customer.first_name || 'there')}, ${esc(d.provider?.first_name || 'your carer')} has just set off with ${esc(d.petName)}. You can watch the route live and you'll see photo updates along the way.`),
        cta: { label: 'Follow along live', href: `${SITE}/track/?booking=${d.booking.id}` },
        footnote: 'You can stop these notifications in your account settings.',
      }),
    });
  } else if (type === 'walk_completed') {
    const { data: ws } = await sb.from('walk_sessions').select('booking_id,distance_metres,duration_seconds').eq('id', payload.walk_session_id as string).single();
    if (!ws) return out;
    const d = await loadBooking(ws.booking_id);
    const dist = ws.distance_metres ? (ws.distance_metres >= 1000 ? (ws.distance_metres / 1000).toFixed(1) + ' km' : ws.distance_metres + ' m') : '—';
    const dur = ws.duration_seconds ? Math.round(ws.duration_seconds / 60) + ' min' : '—';
    const url = `${SITE}/track/?booking=${d.booking.id}`;
    if (d.customer?.email) {
      out.push({
        to: d.customer.email,
        subject: `${d.petName}'s walk is complete`,
        html: layout({
          preview: `${d.petName}'s walk is complete`,
          heading: `${esc(d.petName)}'s walk is complete`,
          body: p(`Hi ${esc(d.customer.first_name || 'there')}, ${esc(d.provider?.first_name || 'your carer')} has brought ${esc(d.petName)} home safe and sound. Here's how the walk went:`) +
            detailsTable([['Pet', d.petName], ['Carer', d.provider?.first_name || 'Carer'], ['Distance', dist], ['Duration', dur]]) +
            p('You can view the full route and any photos from the walk anytime.'),
          cta: { label: 'See the walk', href: url },
        }),
      });
    }
    if (d.provider?.email) {
      out.push({
        to: d.provider.email,
        subject: `Walk complete — ${d.petName}`,
        html: layout({
          preview: `${d.petName}'s walk is complete`,
          heading: `${esc(d.petName)}'s walk is complete`,
          body: p(`Hi ${esc(d.provider.first_name || 'there')}, nice work — you've wrapped up ${esc(d.petName)}'s walk.`) +
            detailsTable([['Pet', d.petName], ['Owner', d.customer?.first_name || 'Owner'], ['Distance', dist], ['Duration', dur]]) +
            p('Thanks for the great care.'),
          cta: { label: 'View summary', href: url },
        }),
      });
    }
  } else if (type === 'new_message') {
    const { data: m } = await sb.from('messages').select('booking_id,sender_id,body').eq('id', payload.message_id as string).single();
    if (!m) return out;
    const d = await loadBooking(m.booking_id);
    const { data: cp } = await sb.from('customer_profiles').select('user_id').eq('id', d.booking.customer_id).single();
    const senderIsCustomer = cp?.user_id === m.sender_id;
    const recipient = senderIsCustomer ? d.provider : d.customer;
    const sender = senderIsCustomer ? d.customer : d.provider;
    if (!recipient?.email) return out;
    const snippet = (m.body || '').slice(0, 140);
    out.push({
      to: recipient.email,
      subject: `New message from ${sender?.first_name || 'Truffl'}`,
      html: layout({
        preview: `New message from ${sender?.first_name || 'someone'}`,
        heading: `New message from ${esc(sender?.first_name || 'Truffl')}`,
        body: p(`Hi ${esc(recipient.first_name || 'there')}, you have a new message:`) +
          p(`<em style="color:#5C4033;">“${esc(snippet)}”</em>`) +
          p('Reply directly in your Truffl messages to keep everything in one place.'),
        cta: { label: 'Reply in Truffl', href: `${SITE}/messages/?booking=${d.booking.id}` },
        footnote: 'Please keep messages on Truffl so there is a record.',
      }),
    });
  }
  return out;
}

// ── Resend send with retry on 429 ──
async function sendEmail(msg: { to: string; subject: string; html: string }) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM, reply_to: REPLY_TO, to: msg.to, subject: msg.subject, html: msg.html }),
    });
    if (res.status !== 429) {
      const data = await res.json().catch(() => ({}));
      return { ok: res.ok, status: res.status, id: (data as { id?: string }).id, error: res.ok ? null : data };
    }
    await new Promise((r) => setTimeout(r, 1200 * (attempt + 1)));
  }
  return { ok: false, status: 429, error: 'rate limited' };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if (req.headers.get('x-webhook-secret') !== WEBHOOK_SECRET) {
    return new Response('Unauthorized', { status: 401 });
  }
  let payload: Record<string, unknown>;
  try { payload = await req.json(); } catch { return new Response('Bad JSON', { status: 400 }); }

  const type = String(payload.type || '');
  try {
    const messages = await buildMessages(type, payload);
    if (!messages.length) {
      return new Response(JSON.stringify({ skipped: true, type }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    const results = [];
    for (const m of messages) {
      results.push(await sendEmail(m));
    }
    const allOk = results.every((r) => r.ok);
    return new Response(JSON.stringify({ type, sent: results.length, allOk, results }), {
      status: allOk ? 200 : 502, headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    console.error('send-notification error', type, e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
