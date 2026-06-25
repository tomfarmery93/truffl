import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph, Details } from '../components/TrufflEmailLayout';

// Trigger: a provider accepts a booking → sent to the customer.
interface Props {
  customerName?: string;
  carerName?: string;
  petName?: string;
  serviceLabel?: string;
  whenText?: string;
  bookingUrl?: string;
}

export default function BookingConfirmed({
  customerName = 'Sarah',
  carerName = 'Olivia W.',
  petName = 'Biscuit',
  serviceLabel = 'Dog walking · 30 min',
  whenText = 'Tomorrow, 9:00–9:30 AM',
  bookingUrl = 'https://trufflpets.com/track/',
}: Props) {
  return (
    <TrufflEmailLayout
      preview={`Your booking with ${carerName} is confirmed`}
      cta={{ label: 'View booking', href: bookingUrl }}
      footnote="You're receiving this because you have a booking with Truffl Pets."
    >
      <Heading>Your booking is confirmed</Heading>
      <Paragraph>
        Hi {customerName}, good news — {carerName} has confirmed your booking for {petName}.
        Here are the details:
      </Paragraph>
      <Details
        rows={[
          ['Service', serviceLabel],
          ['Carer', carerName],
          ['Pet', petName],
          ['When', whenText],
        ]}
      />
      <Paragraph>
        We'll let you know the moment the walk starts so you can follow along live.
      </Paragraph>
    </TrufflEmailLayout>
  );
}
