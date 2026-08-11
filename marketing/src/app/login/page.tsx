import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { APP_LOGIN_REDIRECT_URL } from '@/config/site';

export const metadata: Metadata = {
  robots: { index: false, follow: true },
};

export default function LoginRedirectPage() {
  redirect(APP_LOGIN_REDIRECT_URL);
}

