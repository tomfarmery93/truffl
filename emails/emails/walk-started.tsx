import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Trigger: a carer starts a walk → sent to the customer.
interface Props {
  customerName?: string;
  carerName?: string;
  petName?: string;
  trackUrl?: string;
}

export default function WalkStarted({
  customerName = 'Sarah',
  carerName = 'Olivia',
  petName = 'Biscuit',
  trackUrl = 'https://trufflpets.com/track/',
}: Props) {
  return (
    <TrufflEmailLayout
      preview={`${carerName} has started ${petName}'s walk`}
      cta={{ label: 'Follow along live', href: trackUrl }}
      footnote="You're receiving this because a walk is in progress for your booking."
    >
      <Heading>{petName}'s walk has started</Heading>
      <Paragraph>
        Hi {customerName}, {carerName} has just set off with {petName}. You can watch the route
        live on the map and you'll see photo updates along the way.
      </Paragraph>
      <Paragraph>We'll send a summary once they're safely home.</Paragraph>
    </TrufflEmailLayout>
  );
}
