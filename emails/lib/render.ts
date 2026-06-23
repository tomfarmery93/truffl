import * as React from 'react';
import { render } from '@react-email/render';

/**
 * Render a React Email element to an HTML string for the send call
 * (Resend / Supabase auth templates / the sending Edge Function).
 *
 *   const html = await renderEmail(<BookingConfirmed name="Sarah" />);
 *
 * Pass `plainText: true` to get the text/plain alternative instead.
 */
export function renderEmail(
  element: React.ReactElement,
  opts: { plainText?: boolean } = {},
): Promise<string> {
  return render(element, { plainText: opts.plainText });
}

export default renderEmail;
