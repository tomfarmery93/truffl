import * as React from 'react';
import { TrufflEmailLayout, Heading, Paragraph } from '../components/TrufflEmailLayout';

// Trigger: a new message is sent → sent to the other party (owner or carer).
interface Props {
  recipientName?: string;
  senderName?: string;
  snippet?: string;
  messagesUrl?: string;
}

export default function NewMessage({
  recipientName = 'Sarah',
  senderName = 'Olivia',
  snippet = 'Hi! Just checking which gate you’d like me to use for pickup tomorrow?',
  messagesUrl = 'https://trufflpets.com/messages/',
}: Props) {
  return (
    <TrufflEmailLayout
      preview={`New message from ${senderName}`}
      cta={{ label: 'Reply in Truffl', href: messagesUrl }}
      footnote="You're receiving this because you have an active conversation on Truffl Pets. Please keep messages on Truffl so there's a record."
    >
      <Heading>New message from {senderName}</Heading>
      <Paragraph>Hi {recipientName}, you have a new message:</Paragraph>
      <Paragraph>
        <em style={{ color: '#5C4033' }}>“{snippet}”</em>
      </Paragraph>
      <Paragraph>Reply directly in your Truffl messages to keep everything in one place.</Paragraph>
    </TrufflEmailLayout>
  );
}
