import * as React from 'react';
import {
  Body,
  Button,
  Container,
  Font,
  Head,
  Hr,
  Html,
  Link,
  Preview,
  Section,
  Text,
} from '@react-email/components';
import { colors, fontBody, fontHeading } from '../lib/theme';

export interface TrufflEmailLayoutProps {
  /** Short summary shown in the inbox preview line (hidden in the body). */
  preview: string;
  /** Main body content (Text/Section/etc.). */
  children: React.ReactNode;
  /** Optional call-to-action rendered as a branded button. */
  cta?: { label: string; href: string };
  /** Optional footer note above the standard footer (e.g. "You're receiving this because…"). */
  footnote?: string;
}

const SITE_URL = 'https://trufflpets.com';

/**
 * The shared branded shell every Truffl email reuses (notifications + auth).
 * Provides the header wordmark, palette, typography, button, and footer; callers
 * supply the heading/body via children and an optional CTA.
 */
export function TrufflEmailLayout({
  preview,
  children,
  cta,
  footnote,
}: TrufflEmailLayoutProps) {
  return (
    <Html lang="en">
      <Head>
        {/* Progressive enhancement only — clients that ignore @font-face fall back to Georgia / system sans. */}
        <Font
          fontFamily="Cormorant Garamond"
          fallbackFontFamily="Georgia"
          webFont={{
            url: 'https://fonts.gstatic.com/s/cormorantgaramond/v16/co3bmX5slCNuHLi8bLeY9MK7whWMhyjornFLsS6V7w.woff2',
            format: 'woff2',
          }}
          fontWeight={400}
          fontStyle="normal"
        />
      </Head>
      <Preview>{preview}</Preview>
      <Body style={body}>
        <Container style={container}>
          {/* Header */}
          <Section style={header}>
            <Link href={SITE_URL} style={wordmarkLink}>
              <span style={wordmark}>truffl</span>
              <span style={wordmarkPets}>PETS</span>
            </Link>
          </Section>

          {/* Card */}
          <Section style={card}>{children}</Section>

          {/* CTA */}
          {cta ? (
            <Section style={ctaWrap}>
              <Button href={cta.href} style={button}>
                {cta.label}
              </Button>
            </Section>
          ) : null}

          {/* Footnote */}
          {footnote ? <Text style={footnoteText}>{footnote}</Text> : null}

          <Hr style={hr} />

          {/* Footer */}
          <Section style={footer}>
            <Text style={footerText}>
              <Link href={SITE_URL} style={footerLink}>
                Truffl Pets
              </Link>
              {' '}· Sydney's trusted pet care
            </Text>
            <Text style={footerMuted}>
              <Link href={`${SITE_URL}/trust-and-safety/`} style={footerLink}>
                Trust &amp; safety
              </Link>
              {'  ·  '}
              <Link href={`${SITE_URL}/privacy/`} style={footerLink}>
                Privacy
              </Link>
            </Text>
            <Text style={footerMuted}>© Truffl Pets · Sydney, NSW</Text>
          </Section>
        </Container>
      </Body>
    </Html>
  );
}

export default TrufflEmailLayout;

/* ── Reusable content helpers so individual templates stay consistent ── */

export function Heading({ children }: { children: React.ReactNode }) {
  return <Text style={heading}>{children}</Text>;
}

export function Paragraph({ children }: { children: React.ReactNode }) {
  return <Text style={paragraph}>{children}</Text>;
}

/** A simple key/value details block (e.g. booking summary). */
export function Details({ rows }: { rows: Array<[string, string]> }) {
  return (
    <Section style={detailsBox}>
      {rows.map(([label, value]) => (
        <table key={label} width="100%" style={detailRow} cellPadding={0} cellSpacing={0}>
          <tbody>
            <tr>
              <td style={detailLabel}>{label}</td>
              <td style={detailValue}>{value}</td>
            </tr>
          </tbody>
        </table>
      ))}
    </Section>
  );
}

/* ── Styles ── */

const body: React.CSSProperties = {
  backgroundColor: colors.cream,
  fontFamily: fontBody,
  margin: 0,
  padding: '24px 0',
};

const container: React.CSSProperties = {
  width: '100%',
  maxWidth: '560px',
  margin: '0 auto',
  padding: '0 16px',
};

const header: React.CSSProperties = {
  padding: '8px 0 20px',
  textAlign: 'center' as const,
};

const wordmarkLink: React.CSSProperties = {
  textDecoration: 'none',
  display: 'inline-block',
};

const wordmark: React.CSSProperties = {
  fontFamily: fontHeading,
  fontStyle: 'italic',
  fontSize: '30px',
  color: colors.brown,
  letterSpacing: '-0.5px',
  verticalAlign: 'middle',
};

const wordmarkPets: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '11px',
  fontWeight: 600,
  letterSpacing: '4px',
  color: colors.textLight,
  marginLeft: '8px',
  verticalAlign: 'middle',
};

const card: React.CSSProperties = {
  backgroundColor: colors.white,
  border: `1px solid ${colors.border}`,
  borderRadius: '16px',
  padding: '32px 28px',
};

const heading: React.CSSProperties = {
  fontFamily: fontHeading,
  fontWeight: 500,
  fontSize: '26px',
  lineHeight: '1.2',
  color: colors.brown,
  margin: '0 0 14px',
};

const paragraph: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '15px',
  lineHeight: '1.65',
  color: colors.text,
  margin: '0 0 14px',
};

const detailsBox: React.CSSProperties = {
  backgroundColor: colors.cream,
  borderRadius: '12px',
  padding: '8px 16px',
  margin: '8px 0 4px',
};

const detailRow: React.CSSProperties = {
  borderBottom: `1px solid ${colors.border}`,
};

const detailLabel: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '13px',
  color: colors.textMid,
  padding: '10px 0',
  textAlign: 'left' as const,
};

const detailValue: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '14px',
  fontWeight: 500,
  color: colors.brown,
  padding: '10px 0',
  textAlign: 'right' as const,
};

const ctaWrap: React.CSSProperties = {
  textAlign: 'center' as const,
  padding: '24px 0 4px',
};

const button: React.CSSProperties = {
  backgroundColor: colors.terracotta,
  color: colors.white,
  fontFamily: fontBody,
  fontSize: '15px',
  fontWeight: 500,
  textDecoration: 'none',
  padding: '14px 32px',
  borderRadius: '999px',
  display: 'inline-block',
};

const footnoteText: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '13px',
  lineHeight: '1.6',
  color: colors.textMid,
  textAlign: 'center' as const,
  padding: '18px 8px 0',
  margin: 0,
};

const hr: React.CSSProperties = {
  borderColor: colors.border,
  margin: '28px 0 18px',
};

const footer: React.CSSProperties = {
  textAlign: 'center' as const,
};

const footerText: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '13px',
  color: colors.textMid,
  margin: '0 0 6px',
};

const footerMuted: React.CSSProperties = {
  fontFamily: fontBody,
  fontSize: '12px',
  color: colors.textLight,
  margin: '0 0 6px',
};

const footerLink: React.CSSProperties = {
  color: colors.terracottaDark,
  textDecoration: 'none',
};
