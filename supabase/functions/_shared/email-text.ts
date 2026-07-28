// Plain-text alternative for outgoing email (TRU-120).
//
// Every production email was sending `html` only. A missing text/plain part is a
// real spam-score signal (and the only thing plain-text clients and some
// accessibility tooling can read), so sendEmail() now derives one from the same
// HTML it ships.
//
// This is a deliberately small converter, not a general-purpose one: it only has
// to handle the markup our own layout()/p()/detailsTable() helpers emit —
// headings, paragraphs, a details table, a CTA button, and the footer links.

const NAMED_ENTITIES: Record<string, string> = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
  nbsp: ' ', mdash: '—', ndash: '–', middot: '·', hellip: '…',
  lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”',
  copy: '©', reg: '®', trade: '™', pound: '£', euro: '€', deg: '°',
};

function decode(s: string): string {
  return s.replace(/&(#x[0-9A-Fa-f]+|#\d+|[A-Za-z][A-Za-z0-9]*);/g, (m, body: string) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X'
        ? parseInt(body.slice(2), 16)
        : parseInt(body.slice(1), 10);
      return Number.isFinite(code) && code > 0 ? String.fromCodePoint(code) : m;
    }
    return NAMED_ENTITIES[body.toLowerCase()] ?? m; // leave anything unknown as-is
  });
}

// Strip tags to a SPACE, not to nothing: the layout puts the wordmark in two
// adjacent <span>s, which would otherwise read as "trufflPETS".
function stripTags(s: string): string {
  return s.replace(/<[^>]+>/g, ' ');
}

export function htmlToText(html: string): string {
  let s = html;

  // Drop anything that has no readable text content.
  s = s.replace(/<!DOCTYPE[^>]*>/gi, '');
  s = s.replace(/<(head|style|script|title)\b[^>]*>[\s\S]*?<\/\1>/gi, '');
  // The preview-text div is hidden in clients; it would read as a duplicate heading.
  s = s.replace(/<div style="display:none[^"]*"[^>]*>[\s\S]*?<\/div>/gi, '');

  // Keep links as "label (url)" so the CTA is still actionable in plain text.
  s = s.replace(
    /<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi,
    (_m, href: string, label: string) => {
      const text = decode(stripTags(label)).replace(/\s+/g, ' ').trim();
      const url = decode(href).trim();
      if (!url || url === text) return text;
      return text ? `${text} (${url})` : url;
    },
  );

  // Table rows become "label: value" lines; other block ends become newlines.
  s = s.replace(/<\/t[dh]>\s*<t[dh]\b[^>]*>/gi, ': ');
  s = s.replace(/<\/(tr|p|h[1-6]|div|table|li)>/gi, '\n');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<hr\s*\/?>/gi, '\n---\n');

  s = decode(stripTags(s));

  // Tidy whitespace: collapse runs of spaces, trim each line, cap blank lines.
  s = s.split('\n').map((line) => line.replace(/[^\S\n]+/g, ' ').trim()).join('\n');
  s = s.replace(/\n{3,}/g, '\n\n').trim();

  return s;
}
