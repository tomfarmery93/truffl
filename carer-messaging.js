/* Truffl carer messaging (GitHub #162): templates with merge fields, sent through the channels
 * carers already use (WhatsApp, SMS, email) as deep links, with a per-carer template editor
 * and a send log. Shared by /schedule/, /clients/ and /walk/, which are standalone pages, so
 * this is a plain script that attaches window.TrufflMessaging (the session.js precedent).
 *
 *   TrufflMessaging.init({ supabaseUrl, anonKey, token, uid, carerFirstName })
 *   TrufflMessaging.open({ client, job, pets, reportLink, invoice })
 *     client:     { id, first_name, last_name, phone, email }         (required)
 *     job:        { id, starts_at, ends_at, service_type, price_cents } (optional)
 *     pets:       'Rex, Milo'                                           (optional string)
 *     reportLink: async () => 'https://…'                              (optional; walk_done)
 *     invoice:    { id, number, total_cents, due_on, link }             (optional; GitHub #166)
 *   TrufflMessaging.openEditor()
 *
 * Merge fields: {client_first} {client_name} {dog} {dogs} {time} {date} {duration} {price}
 *               {service} {carer_first} {report_link} {invoice_number} {amount_due} {due_date}
 *               {invoice_link}
 */
(function () {
  'use strict';

  const DEFAULTS = [
    { key: 'on_my_way',    label: 'On my way',        needs: 'job', body: "Hi {client_first}, on my way to pick up {dog} now. See you at about {time}!" },
    { key: 'running_late', label: 'Running late',     needs: 'job', body: "Hi {client_first}, running about 10 minutes late for {dog}, sorry! See you shortly." },
    { key: 'walk_done',    label: 'Walk done',        needs: 'job', body: "Hi {client_first}, {dog} is home and happy after {duration} today. Here's how it went: {report_link}" },
    { key: 'reminder',     label: 'See you tomorrow', needs: 'job', body: "Hi {client_first}, just a reminder I'll be by for {dog} at {time} on {date}. Anything I should know?" },
    { key: 'invoice',      label: 'Payment reminder', needs: 'job', body: "Hi {client_first}, here's what's outstanding for {dog}'s {service} on {date}: {price}. Bank transfer or cash whenever suits, thank you!" },
    { key: 'invoice_send', label: 'Send invoice',     needs: 'invoice', body: "Hi {client_first}, here's your invoice {invoice_number} for {amount_due}, due {due_date}: {invoice_link} Payment details are on the invoice. Thanks so much!" },
    { key: 'invoice_overdue', label: 'Invoice overdue', needs: 'invoice', body: "Hi {client_first}, a gentle nudge that invoice {invoice_number} ({amount_due}) was due {due_date}: {invoice_link} Let me know if anything's amiss. Thank you!" },
    { key: 'hello',        label: 'Say hello',        needs: null,  body: "Hi {client_first}, it's {carer_first}. Just checking in about {dog}. When would suit for the next {service}?" },
    { key: 'photo',        label: 'Quick photo note', needs: null,  body: "Hi {client_first}, {dog} had a great time today. Photo to follow!" },
  ];
  const SERVICE_WORD = { dog_walking: 'walk', dog_sitting: 'visit', dog_boarding: 'stay', pet_sitting: 'visit' };

  let cfg = null;
  let custom = null;          // rows from message_templates, loaded lazily
  let ctx = null;             // current open() context
  let selectedKey = null;
  let stylesInjected = false;

  /* ── helpers ── */
  const esc = s => (s == null ? '' : String(s)).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const attr = s => esc(s).replace(/'/g, '&#39;');
  function headers() {
    const h = { 'Content-Type': 'application/json', 'apikey': cfg.anonKey, 'Authorization': `Bearer ${cfg.anonKey}` };
    if (cfg.token) h['Authorization'] = `Bearer ${cfg.token}`;
    return h;
  }
  async function api(method, path, body, prefer) {
    const r = await fetch(`${cfg.supabaseUrl}/rest/v1/${path}`, { method, headers: Object.assign(headers(), prefer ? { 'Prefer': prefer } : {}), body: body ? JSON.stringify(body) : undefined });
    if (!r.ok) { const e = await r.json().catch(() => ({})); throw new Error(e.message || `Request failed (${r.status})`); }
    if (r.status === 204) return null;
    return await r.json();
  }
  function e164(phone) {
    let d = (phone || '').replace(/[^\d+]/g, '');
    if (!d) return '';
    if (d.startsWith('+')) return d;
    if (d.startsWith('0') && d.length === 10) return '+61' + d.slice(1);
    if (d.startsWith('61') && d.length === 11) return '+' + d;
    return '+' + d;
  }
  function fmtTime(iso) { return new Date(iso).toLocaleTimeString('en-AU', { hour: 'numeric', minute: '2-digit' }).replace(' ', '').toLowerCase(); }
  function fmtDate(iso) { return new Date(iso).toLocaleDateString('en-AU', { weekday: 'short', day: 'numeric', month: 'short' }); }
  function fmtDur(a, b) { const m = Math.round((new Date(b) - new Date(a)) / 60000); if (m >= 60) return `${Math.floor(m / 60)}h${m % 60 ? ' ' + (m % 60) + 'm' : ''}`; return `${m} min`; }
  function money(c) { return '$' + ((c || 0) / 100).toFixed(2).replace(/\.00$/, ''); }
  function isIos() { return /iPad|iPhone|iPod/.test(navigator.userAgent); }
  function track(name, params) { try { if (typeof gtag === 'function') gtag('event', name, params || {}); } catch (e) {} }

  function fields(reportLink) {
    const c = ctx.client || {}, j = ctx.job || null, inv = ctx.invoice || null;
    const dogs = (ctx.pets || '').split(',').map(s => s.trim()).filter(Boolean);
    return {
      client_first: c.first_name || 'there',
      client_name: `${c.first_name || ''} ${c.last_name || ''}`.trim() || 'there',
      dog: dogs[0] || 'your dog',
      dogs: dogs.length ? dogs.join(' and ') : 'your dog',
      time: j ? fmtTime(j.starts_at) : '',
      date: j ? fmtDate(j.starts_at) : '',
      duration: j ? fmtDur(j.starts_at, j.ends_at) : '',
      price: j && j.price_cents ? money(j.price_cents) : '',
      service: j ? (SERVICE_WORD[j.service_type] || 'visit') : 'walk',
      carer_first: cfg.carerFirstName || 'your carer',
      report_link: reportLink || '',
      invoice_number: inv ? (inv.number || '') : '',
      amount_due: inv ? money(inv.total_cents) : '',
      due_date: inv && inv.due_on ? new Date(inv.due_on + 'T12:00:00').toLocaleDateString('en-AU', { day: 'numeric', month: 'short' }) : '',
      invoice_link: inv ? (inv.link || '') : '',
    };
  }
  function merge(body, f) {
    let out = body.replace(/\{(\w+)\}/g, (m, k) => (k in f ? f[k] : m));
    // Tidy a missing report link so the message never ends with a dangling colon.
    return out.replace(/:\s*$/, '.').replace(/\s{2,}/g, ' ').trim();
  }

  function allTemplates() {
    const overrides = {}; (custom || []).forEach(r => { overrides[r.key] = r; });
    const list = DEFAULTS.map(d => overrides[d.key] ? { ...d, body: overrides[d.key].body, label: overrides[d.key].label || d.label, overridden: true, row: overrides[d.key] } : { ...d });
    (custom || []).filter(r => !DEFAULTS.some(d => d.key === r.key)).forEach(r => list.push({ key: r.key, label: r.label || 'Custom', body: r.body, needs: null, custom: true, row: r }));
    return list;
  }
  async function loadCustom() {
    if (custom) return;
    try { custom = await api('GET', `message_templates?provider_user_id=eq.${cfg.uid}&select=*&order=sort_order.asc,created_at.asc`); }
    catch (e) { custom = []; }
  }

  /* ── styles ── */
  function injectStyles() {
    if (stylesInjected) return; stylesInjected = true;
    const css = `
      .tm-overlay{position:fixed;inset:0;background:rgba(61,43,31,.45);z-index:300;display:flex;align-items:flex-end;justify-content:center;}
      .tm-sheet{background:var(--cream,#FAF7F2);width:100%;max-width:560px;max-height:92vh;overflow-y:auto;border-radius:18px 18px 0 0;padding:1.1rem 1.1rem 1.6rem;font-family:'DM Sans',sans-serif;color:var(--text-primary,#3D2B1F);animation:tmUp .2s ease;}
      @media(min-width:700px){.tm-overlay{align-items:center;padding:2rem}.tm-sheet{border-radius:18px;max-height:88vh}}
      @keyframes tmUp{from{transform:translateY(24px);opacity:0}to{transform:none;opacity:1}}
      .tm-head{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:.8rem}
      .tm-title{font-family:'Cormorant Garamond',serif;font-weight:500;font-size:1.4rem;color:var(--brown,#3D2B1F)}
      .tm-sub{font-size:.8rem;color:var(--text-muted,#9B8B7E)}
      .tm-close{width:32px;height:32px;border-radius:50%;border:1px solid var(--border,#E8E0D6);background:var(--warm-white,#FFFDF9);cursor:pointer;color:var(--text-secondary,#6B5B4E);font-size:1rem}
      .tm-chips{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:.7rem}
      .tm-chip{padding:7px 12px;border-radius:999px;font-size:.78rem;font-weight:500;border:1px solid var(--border,#E8E0D6);background:var(--warm-white,#FFFDF9);color:var(--text-secondary,#6B5B4E);cursor:pointer;font-family:inherit}
      .tm-chip.on{background:var(--brown,#3D2B1F);color:#fff;border-color:var(--brown,#3D2B1F)}
      .tm-text{width:100%;min-height:110px;padding:10px 12px;border:1px solid var(--border,#E8E0D6);border-radius:12px;background:var(--warm-white,#FFFDF9);font:inherit;font-size:.92rem;line-height:1.5;color:inherit;resize:vertical}
      .tm-channels{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:.8rem}
      @media(max-width:420px){.tm-channels{grid-template-columns:repeat(2,1fr)}}
      .tm-ch{display:flex;flex-direction:column;align-items:center;gap:6px;padding:12px 8px;border-radius:12px;border:1px solid var(--border,#E8E0D6);background:var(--warm-white,#FFFDF9);cursor:pointer;font-family:inherit;font-size:.78rem;font-weight:600;color:var(--brown,#3D2B1F);text-decoration:none}
      .tm-ch:disabled{opacity:.4;cursor:default}
      .tm-ch svg{width:20px;height:20px}
      .tm-ch.wa{color:#1f8f4e}.tm-ch.sms{color:#3b6ea5}.tm-ch.mail{color:var(--terracotta,#C4755B)}
      .tm-foot{display:flex;justify-content:space-between;align-items:center;margin-top:.9rem;font-size:.78rem;color:var(--text-muted,#9B8B7E);flex-wrap:wrap;gap:8px}
      .tm-link{background:none;border:none;color:var(--terracotta,#C4755B);font-size:.8rem;font-weight:600;cursor:pointer;padding:0;font-family:inherit}
      .tm-note{font-size:.76rem;color:var(--text-muted,#9B8B7E);margin-top:6px}
      .tm-tpl{background:var(--warm-white,#FFFDF9);border:1px solid var(--border,#E8E0D6);border-radius:12px;padding:12px;margin-bottom:8px}
      .tm-tpl input,.tm-tpl textarea{width:100%;padding:8px 10px;border:1px solid var(--border,#E8E0D6);border-radius:8px;background:#fff;font:inherit;font-size:.86rem;color:inherit}
      .tm-tpl textarea{min-height:64px;resize:vertical;margin-top:6px}
      .tm-tpl-row{display:flex;gap:8px;align-items:center;justify-content:space-between;margin-top:8px;flex-wrap:wrap}
      .tm-btn{padding:7px 12px;border-radius:999px;border:1px solid var(--border,#E8E0D6);background:var(--warm-white,#FFFDF9);font-size:.78rem;font-weight:600;cursor:pointer;font-family:inherit;color:var(--brown,#3D2B1F)}
      .tm-btn.primary{background:var(--terracotta,#C4755B);color:#fff;border-color:transparent}
      .tm-status{font-size:.76rem;color:var(--text-muted,#9B8B7E)}
    `;
    const el = document.createElement('style'); el.textContent = css; document.head.appendChild(el);
  }
  function mount(html) {
    injectStyles();
    let root = document.getElementById('tmRoot');
    if (!root) { root = document.createElement('div'); root.id = 'tmRoot'; document.body.appendChild(root); }
    root.innerHTML = `<div class="tm-overlay" onclick="if(event.target===this)TrufflMessaging.close()"><div class="tm-sheet">${html}</div></div>`;
    document.body.style.overflow = 'hidden';
  }
  function close() { const root = document.getElementById('tmRoot'); if (root) root.innerHTML = ''; document.body.style.overflow = ''; ctx = null; }

  const ICON = {
    wa: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.5 14.4c-.3-.1-1.8-.9-2-1-.3-.1-.5-.1-.7.1-.2.3-.8 1-.9 1.2-.2.2-.3.2-.6.1-.3-.1-1.3-.5-2.4-1.5-.9-.8-1.5-1.8-1.7-2.1-.2-.3 0-.5.1-.6l.4-.5c.1-.2.2-.3.3-.5.1-.2 0-.4 0-.5l-.9-2.2c-.2-.6-.5-.5-.7-.5h-.6c-.2 0-.5.1-.8.4-.3.3-1 1-1 2.5s1.1 2.9 1.2 3.1c.1.2 2.1 3.2 5.1 4.5.7.3 1.3.5 1.7.6.7.2 1.4.2 1.9.1.6-.1 1.8-.7 2-1.4.2-.7.2-1.3.2-1.4-.1-.2-.3-.3-.6-.4zM12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2c-1.5 0-3-.4-4.3-1.2l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2z"/></svg>',
    sms: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>',
    mail: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/></svg>',
    copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>',
  };

  /* ── chooser ── */
  async function open(options) {
    if (!cfg) throw new Error('TrufflMessaging.init() first');
    ctx = Object.assign({ client: {}, job: null, pets: '', reportLink: null, invoice: null }, options || {});
    ctx._report = null;
    await loadCustom();
    const list = allTemplates().filter(t => !t.needs || (t.needs === 'job' && ctx.job) || (t.needs === 'invoice' && ctx.invoice));
    selectedKey = (list.find(t => t.key === (ctx.preselect || '')) || list[0] || {}).key || null;
    render();
    // Resolve the report link in the background so "Walk done" can include it.
    if (ctx.reportLink) {
      try { ctx._report = await ctx.reportLink(); } catch (e) { ctx._report = null; }
      if (ctx && selectedKey === 'walk_done') setText(currentBody());
    }
  }
  function currentBody() {
    const t = allTemplates().find(x => x.key === selectedKey);
    return t ? merge(t.body, fields(ctx._report)) : '';
  }
  function setText(v) { const ta = document.getElementById('tmText'); if (ta) ta.value = v; }
  function render() {
    const c = ctx.client || {};
    const list = allTemplates().filter(t => !t.needs || (t.needs === 'job' && ctx.job) || (t.needs === 'invoice' && ctx.invoice));
    const phone = e164(c.phone), email = (c.email || '').trim();
    mount(`
      <div class="tm-head"><div><div class="tm-title">Message ${esc(c.first_name || 'client')}</div><div class="tm-sub">${phone ? esc(c.phone) : 'No mobile on file'}${email ? ' · ' + esc(email) : ''}${ctx.pets ? ' · ' + esc(ctx.pets) : ''}</div></div><button class="tm-close" onclick="TrufflMessaging.close()" aria-label="Close">×</button></div>
      <div class="tm-chips">${list.map(t => `<button type="button" class="tm-chip ${t.key === selectedKey ? 'on' : ''}" onclick="TrufflMessaging._pick('${attr(t.key)}')">${esc(t.label)}</button>`).join('')}</div>
      <textarea class="tm-text" id="tmText" aria-label="Message">${esc(currentBody())}</textarea>
      <div class="tm-note">Edit the text before sending. It opens in the app you choose; nothing is sent from Truffl itself.</div>
      <div class="tm-channels">
        <button type="button" class="tm-ch wa" ${phone ? '' : 'disabled'} onclick="TrufflMessaging._send('whatsapp')">${ICON.wa}WhatsApp</button>
        <button type="button" class="tm-ch sms" ${phone ? '' : 'disabled'} onclick="TrufflMessaging._send('sms')">${ICON.sms}SMS</button>
        <button type="button" class="tm-ch mail" ${email ? '' : 'disabled'} onclick="TrufflMessaging._send('email')">${ICON.mail}Email</button>
        <button type="button" class="tm-ch" onclick="TrufflMessaging._send('copy')">${ICON.copy}Copy</button>
      </div>
      <div class="tm-foot"><span>${ctx.invoice ? 'The link opens the invoice; no sign-in needed.' : (ctx.job ? 'Fields like time and price come from this job.' : 'Open from a job to fill in times and prices.')}</span><button class="tm-link" onclick="TrufflMessaging.openEditor()">Edit templates</button></div>`);
  }
  function pick(key) { selectedKey = key; const ta = document.getElementById('tmText'); const body = currentBody(); if (ta) ta.value = body; document.querySelectorAll('.tm-chip').forEach(el => el.classList.toggle('on', el.textContent === (allTemplates().find(t => t.key === key) || {}).label)); }
  async function send(channel) {
    const ta = document.getElementById('tmText'); const text = (ta ? ta.value : currentBody()).trim();
    if (!text) return;
    const c = ctx.client || {}; const phone = e164(c.phone); const email = (c.email || '').trim();
    const enc = encodeURIComponent(text);
    let href = null;
    if (channel === 'whatsapp' && phone) href = `https://wa.me/${phone.replace('+', '')}?text=${enc}`;
    else if (channel === 'sms' && phone) href = `sms:${phone}${isIos() ? '&' : '?'}body=${enc}`;
    else if (channel === 'email' && email) href = `mailto:${email}?subject=${encodeURIComponent(ctx.invoice ? 'Invoice ' + (ctx.invoice.number || '') + ' from ' + (cfg.carerFirstName || 'your carer') : (ctx.job ? 'About ' + (ctx.pets || 'your dog') : 'From ' + (cfg.carerFirstName || 'your carer')))}&body=${enc}`;
    else if (channel === 'copy') {
      try { await navigator.clipboard.writeText(text); } catch (e) { if (ta) { ta.select(); document.execCommand('copy'); } }
    }
    // Log first (fire and forget), then hand off to the app.
    const snapshot = { provider_user_id: cfg.uid, client_id: c.id || null, job_id: ctx.job ? ctx.job.id : null, invoice_id: ctx.invoice ? ctx.invoice.id : null, channel, template_key: selectedKey, body: text };
    api('POST', 'message_log', snapshot, 'return=minimal').catch(() => {});
    track('message_sent', { channel, template: selectedKey || 'custom' });
    if (href) {
      if (channel === 'whatsapp') window.open(href, '_blank', 'noopener'); else window.location.href = href;
    }
    const note = document.querySelector('.tm-note');
    if (channel === 'copy' && note) { note.textContent = 'Copied. Paste it wherever you like.'; return; }
    close();
  }

  /* ── template editor ── */
  async function openEditor() {
    await loadCustom();
    renderEditor();
  }
  function renderEditor(status) {
    const list = allTemplates();
    mount(`
      <div class="tm-head"><div><div class="tm-title">Message templates</div><div class="tm-sub">Fields: {client_first} {dog} {dogs} {time} {date} {duration} {price} {service} {carer_first} {report_link} {invoice_number} {amount_due} {due_date} {invoice_link}</div></div><button class="tm-close" onclick="TrufflMessaging.close()" aria-label="Close">×</button></div>
      ${list.map(t => `<div class="tm-tpl" data-key="${attr(t.key)}">
        <input value="${attr(t.label)}" aria-label="Template name" ${t.custom || t.overridden ? '' : ''}>
        <textarea aria-label="Template text">${esc(t.body)}</textarea>
        <div class="tm-tpl-row">
          <span class="tm-status">${t.custom ? 'Custom' : (t.overridden ? 'Edited default' : 'Default')}</span>
          <span style="display:flex;gap:6px;">
            ${t.overridden ? `<button class="tm-btn" onclick="TrufflMessaging._reset('${attr(t.key)}')">Reset</button>` : ''}
            ${t.custom ? `<button class="tm-btn" onclick="TrufflMessaging._remove('${attr(t.key)}')">Delete</button>` : ''}
            <button class="tm-btn primary" onclick="TrufflMessaging._save('${attr(t.key)}')">Save</button>
          </span>
        </div></div>`).join('')}
      <div class="tm-tpl-row"><span class="tm-status">${esc(status || '')}</span><button class="tm-btn" onclick="TrufflMessaging._add()">+ New template</button></div>`);
  }
  function readTpl(key) {
    const box = document.querySelector(`.tm-tpl[data-key="${CSS.escape(key)}"]`); if (!box) return null;
    return { label: box.querySelector('input').value.trim() || 'Template', body: box.querySelector('textarea').value.trim() };
  }
  async function saveTpl(key) {
    const v = readTpl(key); if (!v || !v.body) return;
    try {
      const rows = await api('POST', 'message_templates?on_conflict=provider_user_id,key', { provider_user_id: cfg.uid, key, label: v.label, body: v.body }, 'return=representation,resolution=merge-duplicates');
      const row = rows[0]; custom = (custom || []).filter(r => r.key !== key).concat([row]);
      renderEditor('Saved.');
    } catch (e) { renderEditor('Could not save: ' + e.message); }
  }
  async function resetTpl(key) {
    const row = (custom || []).find(r => r.key === key); if (!row) return;
    try { await api('DELETE', `message_templates?id=eq.${row.id}`); custom = custom.filter(r => r.id !== row.id); renderEditor('Reset to default.'); }
    catch (e) { renderEditor('Could not reset: ' + e.message); }
  }
  async function removeTpl(key) {
    const row = (custom || []).find(r => r.key === key); if (!row) return;
    if (!confirm('Delete this template?')) return;
    try { await api('DELETE', `message_templates?id=eq.${row.id}`); custom = custom.filter(r => r.id !== row.id); renderEditor('Deleted.'); }
    catch (e) { renderEditor('Could not delete: ' + e.message); }
  }
  async function addTpl() {
    const key = 'custom_' + Math.random().toString(36).slice(2, 10);
    try {
      const rows = await api('POST', 'message_templates', { provider_user_id: cfg.uid, key, label: 'New template', body: 'Hi {client_first}, ' }, 'return=representation');
      custom = (custom || []).concat(rows); renderEditor('Added. Edit and save.');
      const box = document.querySelector(`.tm-tpl[data-key="${CSS.escape(key)}"] textarea`); if (box) { box.focus(); box.scrollIntoView({ block: 'center' }); }
    } catch (e) { renderEditor('Could not add: ' + e.message); }
  }

  window.TrufflMessaging = {
    init(options) { cfg = Object.assign({}, options); custom = null; },
    open, openEditor, close,
    e164,
    _pick: pick, _send: send, _save: saveTpl, _reset: resetTpl, _remove: removeTpl, _add: addTpl,
  };
})();
