// Shared helpers for edge functions (seeds TRU-190's supabase/functions/_shared/).

// Constant-time string comparison for shared-secret header checks (TRU-199).
// Mirrors the constant-time HMAC compare already used in stripe-webhook, replacing the
// timing-unsafe `!==` checks in send-notification and charge-booking. The length check can
// leak the secret's length, which is not sensitive for a fixed-length shared secret.
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
