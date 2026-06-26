import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Supabase auth template: "Magic Link". {{ .ConfirmationURL }} substituted at send time.
export default function AuthMagicLink() {
  return (
    <TrufflEmailLayout
      preview="Your Truffl Pets sign-in link"
      cta={{ label: 'Sign in to Truffl', href: '{{ .ConfirmationURL }}' }}
      footnote="If you didn't request this link, you can safely ignore this email — no one can sign in without it."
    >
      <Heading>Your sign-in link</Heading>
      <Paragraph>Tap the button below to sign in to Truffl Pets. For your security, this link expires shortly and can only be used once.</Paragraph>
    </TrufflEmailLayout>
  );
}
