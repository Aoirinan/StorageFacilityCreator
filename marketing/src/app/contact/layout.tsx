import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Contact',
  description: 'Schedule a demo or contact Storage Facility Creator. We respond promptly.',
};

export default function ContactLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
