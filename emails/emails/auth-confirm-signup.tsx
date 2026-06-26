import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Supabase auth template: "Confirm signup". Paste rendered HTML into
// Authentication → Email Templates → Confirm signup. {{ .ConfirmationURL }} is
// substituted by Supabase at send time.
export default function AuthConfirmSignup() {
  return (
    <TrufflEmailLayout
      preview="Confirm your email to finish setting up your Truffl account"
      cta={{ label: 'Confirm email', href: '{{ .ConfirmationURL }}' }}
      footnote="If you didn't create a Truffl Pets account, you can safely ignore this email."
    >
      <Heading>Confirm your email</Heading>
      <Paragraph>
        Welcome to Truffl Pets! Tap the button below to confirm your email address and finish
        setting up your account.
      </Paragraph>
      <Paragraph>This link will expire shortly, so it's best to confirm now.</Paragraph>
    </TrufflEmailLayout>
  );
}
