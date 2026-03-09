import { redirect } from 'next/navigation';
import { APP_LOGIN_REDIRECT_URL } from '@/config/site';

export default function LoginRedirectPage() {
  redirect(APP_LOGIN_REDIRECT_URL);
}

