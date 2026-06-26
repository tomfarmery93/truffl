import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Supabase auth template: "Change Email Address". {{ .Email }} / {{ .NewEmail }} /
// {{ .ConfirmationURL }} substituted at send time.
export default function AuthChangeEmail() {
  return (
    <TrufflEmailLayout
      preview="Confirm your new Truffl Pets email address"
      cta={{ label: 'Confirm new email', href: '{{ .ConfirmationURL }}' }}
      footnote="If you didn't request this change, please contact us at support@trufflpets.com straight away."
    >
      <Heading>Confirm your new email</Heading>
      <Paragraph>
        Tap below to confirm changing your Truffl Pets email from {'{{ .Email }}'} to{' '}
        {'{{ .NewEmail }}'}.
      </Paragraph>
      <Paragraph>Until you confirm, your account keeps using your current email.</Paragraph>
    </TrufflEmailLayout>
  );
}
