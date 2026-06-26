import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Supabase auth template: "Reset Password". {{ .ConfirmationURL }} substituted at send time.
export default function AuthResetPassword() {
  return (
    <TrufflEmailLayout
      preview="Reset your Truffl Pets password"
      cta={{ label: 'Reset password', href: '{{ .ConfirmationURL }}' }}
      footnote="If you didn't request a password reset, you can safely ignore this email — your password won't change."
    >
      <Heading>Reset your password</Heading>
      <Paragraph>
        We received a request to reset the password for your Truffl Pets account. Tap the button
        below to choose a new one.
      </Paragraph>
      <Paragraph>This link will expire shortly.</Paragraph>
    </TrufflEmailLayout>
  );
}
