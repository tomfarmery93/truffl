import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Supabase auth template: "Invite user". {{ .ConfirmationURL }} substituted at send time.
export default function AuthInvite() {
  return (
    <TrufflEmailLayout
      preview="You've been invited to Truffl Pets"
      cta={{ label: 'Accept invitation', href: '{{ .ConfirmationURL }}' }}
      footnote="If you weren't expecting this invitation, you can ignore this email."
    >
      <Heading>You've been invited to Truffl Pets</Heading>
      <Paragraph>
        You've been invited to join Truffl Pets — Sydney's trusted pet care. Tap below to accept
        and set up your account.
      </Paragraph>
    </TrufflEmailLayout>
  );
}
