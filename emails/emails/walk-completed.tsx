import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph, Details } from '../components/TrufflEmailLayout';

// Trigger: a carer ends a walk → sent to BOTH the customer and the carer.
// `forCarer` switches the wording for the carer's copy.
interface Props {
  recipientName?: string;
  otherName?: string; // the carer (for the owner) or the owner (for the carer)
  petName?: string;
  distanceText?: string;
  durationText?: string;
  summaryUrl?: string;
  forCarer?: boolean;
}

export default function WalkCompleted({
  recipientName = 'Sarah',
  otherName = 'Olivia',
  petName = 'Biscuit',
  distanceText = '2.4 km',
  durationText = '32 min',
  summaryUrl = 'https://trufflpets.com/track/',
  forCarer = false,
}: Props) {
  return (
    <TrufflEmailLayout
      preview={`${petName}'s walk is complete`}
      cta={{ label: 'See the walk', href: summaryUrl }}
      footnote="You're receiving this because a walk on your booking has finished."
    >
      <Heading>{petName}'s walk is complete</Heading>
      <Paragraph>
        Hi {recipientName},{' '}
        {forCarer
          ? `nice work — you've wrapped up ${petName}'s walk. Here's the summary the owner sees:`
          : `${otherName} has brought ${petName} home safe and sound. Here's how the walk went:`}
      </Paragraph>
      <Details
        rows={[
          ['Pet', petName],
          [forCarer ? 'Owner' : 'Carer', otherName],
          ['Distance', distanceText],
          ['Duration', durationText],
        ]}
      />
      <Paragraph>
        {forCarer
          ? 'Thanks for the great care.'
          : 'You can view the full route and any photos from the walk anytime.'}
      </Paragraph>
    </TrufflEmailLayout>
  );
}
