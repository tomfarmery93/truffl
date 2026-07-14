// Shared CORS config for browser-facing edge functions (TRU-200).
//
// Replaces `Access-Control-Allow-Origin: *` with an allow-list. The website and the Capacitor
// mobile app both load from https://trufflpets.com (capacitor.config.json `server.url`), so that
// is the primary browser origin; www and the Capacitor localhost shells are included for
// completeness / local dev. An unknown origin falls back to the apex domain (i.e. it is not
// reflected), so the browser's origin-protection layer is preserved. `Vary: Origin` keeps caches
// from serving one origin's ACAO header to another.
const ALLOWED_ORIGINS = new Set([
  'https://trufflpets.com',
  'https://www.trufflpets.com',
  'capacitor://localhost',
  'http://localhost',
]);

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('Origin') ?? '';
  const allowOrigin = ALLOWED_ORIGINS.has(origin) ? origin : 'https://trufflpets.com';
  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
}
