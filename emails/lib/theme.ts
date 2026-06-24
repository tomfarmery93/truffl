/**
 * Truffl Pets email brand tokens.
 *
 * Mirrors the marketing-site palette (see the public pages' :root variables).
 * Email clients (esp. Gmail) strip web fonts, so fonts are declared as a
 * progressive enhancement: the brand serif first, with a solid fallback stack
 * that must look good on its own.
 */

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

export const spacing = {
  page: '24px',
  section: '24px',
} as const;
