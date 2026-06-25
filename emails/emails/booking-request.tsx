import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph, Details } from '../components/TrufflEmailLayout';

// Trigger: a customer requests a booking → sent to the provider.
interface Props {
  carerName?: string;
  customerName?: string;
  petName?: string;
  serviceLabel?: string;
  whenText?: string;
  dashboardUrl?: string;
}

export default function BookingRequest({
  carerName = 'Olivia',
  customerName = 'Sarah',
  petName = 'Biscuit',
  serviceLabel = 'Dog walking · 30 min',
  whenText = 'Tomorrow, 9:00–9:30 AM',
  dashboardUrl = 'https://trufflpets.com/dashboard/',
}: Props) {
  return (
    <TrufflEmailLayout
      preview={`New booking request from ${customerName}`}
      cta={{ label: 'Review request', href: dashboardUrl }}
      footnote="You're receiving this because you're a carer on Truffl Pets. Responding promptly helps you win the booking."
    >
      <Heading>You have a new booking request</Heading>
      <Paragraph>
        Hi {carerName}, {customerName} would like to book you for {petName}. Have a look and
        accept it from your dashboard:
      </Paragraph>
      <Details
        rows={[
          ['Customer', customerName],
          ['Pet', petName],
          ['Service', serviceLabel],
          ['When', whenText],
        ]}
      />
      <Paragraph>The sooner you respond, the better the experience for the owner.</Paragraph>
    </TrufflEmailLayout>
  );
}
