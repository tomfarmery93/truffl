import * as React from 'react';
import {
  TrufflEmailLayout,
  Heading,
  Paragraph,
  Details,
} from '../components/TrufflEmailLayout';

/**
 * Preview/example showing the shared layout in use. Not a production template —
 * the five transactional templates (TRU-117) and auth rebrand (TRU-119) will
 * each import TrufflEmailLayout the same way this does.
 */
export default function LayoutPreview() {
  return (
    <TrufflEmailLayout
      preview="Your walk with Olivia is confirmed for tomorrow"
      cta={{ label: 'View booking', href: 'https://trufflpets.com/track/' }}
      footnote="You're receiving this because you have a booking with Truffl Pets."
    >
      <Heading>Your booking is confirmed</Heading>
      <Paragraph>
        Hi Sarah, good news — Olivia has confirmed your dog walk. Here are the details:
      </Paragraph>
      <Details
        rows={[
          ['Service', 'Dog walking · 30 min'],
          ['Carer', 'Olivia W.'],
          ['Pet', 'Biscuit'],
          ['When', 'Tomorrow, 9:00–9:30 AM'],
        ]}
      />
      <Paragraph>
        You'll be able to follow along live once the walk starts. Any questions,
        just reply in your Truffl messages.
      </Paragraph>
    </TrufflEmailLayout>
  );
}
