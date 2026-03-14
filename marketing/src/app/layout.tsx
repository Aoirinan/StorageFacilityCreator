import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { Header } from '@/components/Header';
import { Footer } from '@/components/Footer';
import { DEFAULT_OG_IMAGE, LOGO_PATH, SITE_DOMAIN, SITE_NAME } from '@/config/site';

const inter = Inter({ subsets: ['latin'], variable: '--font-sans' });

export const metadata: Metadata = {
  metadataBase: new URL(SITE_DOMAIN),
  title: {
    default: `${SITE_NAME} | Self-Storage Management Software`,
    template: `%s | ${SITE_NAME}`,
  },
  description:
    'Modern self-storage management software for independent and multi-facility operators. Operations, billing, delinquency, messaging, reporting, and practical integrations.',
  openGraph: {
    title: `${SITE_NAME} | Self-Storage Management Software`,
    description:
      'Modern self-storage management software for independent and multi-facility operators. Operations, billing, delinquency, messaging, reporting, and practical integrations.',
    type: 'website',
    url: SITE_DOMAIN,
    images: [{ url: DEFAULT_OG_IMAGE, width: 1200, height: 630, alt: `${SITE_NAME} dashboard` }],
  },
  twitter: {
    card: 'summary_large_image',
    title: `${SITE_NAME} | Self-Storage Management Software`,
    description:
      'Modern self-storage management software for independent and multi-facility operators. Operations, billing, delinquency, messaging, reporting, and practical integrations.',
    images: [DEFAULT_OG_IMAGE],
  },
  robots: { index: true, follow: true },
  icons: { icon: LOGO_PATH },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={inter.variable}>
      <body className="min-h-screen flex flex-col antialiased font-sans">
        <a href="#main-content" className="skip-link">
          Skip to content
        </a>
        <Header />
        <main id="main-content" className="flex-1">
          {children}
        </main>
        <Footer />
      </body>
    </html>
  );
}
