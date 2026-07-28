// Truffl Pets email brand tokens — the Deno-side source of truth (TRU-120).
//
// Production transactional email is rendered by send-notification's own layout()
// helpers, NOT by the React Email workspace in emails/ (nothing imports
// renderEmail — see emails/RUNBOOK.md). That leaves two places defining the
// brand, and they had already drifted: the edge function's body font stack was
// missing 'DM Sans'. This module is the single place the edge function reads
// tokens from, and CI (.github/workflows/ci.yml, "Email brand tokens in sync")
// fails the build if these values stop matching emails/lib/theme.ts.
//
// Keep in lockstep with emails/lib/theme.ts. If you change a token, change both.

export const colors = {
  cream: '#F7F3EE',
  warm: '#EDE7DC',
  sage: '#C8D5C0',
  sageDark: '#8A9E82',
  blush: '#E8D5CC',
  terracotta: '#C4866A',
  terracottaDark: '#B8795C',
  brown: '#5C4033',
  brownDeep: '#3A2E28',
  text: '#3A2E28',
  textMid: '#7A6860',
  textLight: '#A8978E',
  border: '#E7DFD6', // solid equivalent of rgba(92,64,51,0.12) for email clients
  white: '#FFFFFF',
} as const;

// Heading: brand serif, falling back to Georgia (a near-universal serif).
export const fontHeading =
  "'Cormorant Garamond', Georgia, 'Times New Roman', serif";

// Body: brand sans, falling back to a robust system sans stack.
export const fontBody =
  "'DM Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";
