import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { Header } from '@/components/Header';
import { Footer } from '@/components/Footer';
import { SITE_NAME } from '@/config/site';

const inter = Inter({ subsets: ['latin'], variable: '--font-sans' });

export const metadata: Metadata = {
  title: {
    default: `${SITE_NAME} | Self-Storage Management Software`,
    template: `%s | ${SITE_NAME}`,
  },
  description:
    'Flat-rate self-storage management: tenants, units, billing, payments, and opt-in SMS reminders. $75/month, no onboarding fee, 30-day trial.',
  openGraph: {
    title: `${SITE_NAME} | Self-Storage Management Software`,
    description:
      'Flat-rate self-storage management: tenants, units, billing, payments, and opt-in SMS reminders. $75/month, no onboarding fee, 30-day trial.',
    type: 'website',
  },
  robots: { index: true, follow: true },
  icons: { icon: '/logo.png' },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={inter.variable}>
      <body className="min-h-screen flex flex-col antialiased font-sans">
        <Header />
        <main className="flex-1">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
