'use client';

import { useState } from 'react';
import { Section } from '@/components/Section';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SUPPORT_EMAIL, SUPPORT_PHONE } from '@/config/site';

const UNIT_RANGES = [
  { value: '', label: 'Select range (optional)' },
  { value: '1-25', label: '1–25 units' },
  { value: '26-50', label: '26–50 units' },
  { value: '51-100', label: '51–100 units' },
  { value: '101-250', label: '101–250 units' },
  { value: '251+', label: '251+ units' },
];

export default function ContactPage() {
  const [status, setStatus] = useState<'idle' | 'sending' | 'success' | 'error'>('idle');
  const [errorMessage, setErrorMessage] = useState('');

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const data = new FormData(form);
    const body = Object.fromEntries(data.entries());

    setStatus('sending');
    setErrorMessage('');

    try {
      const res = await fetch('/api/contact', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const json = await res.json().catch(() => ({}));

      if (res.ok) {
        setStatus('success');
        form.reset();
      } else {
        setStatus('error');
        setErrorMessage(json.message || 'Something went wrong. Please try again or email us.');
      }
    } catch {
      setStatus('error');
      setErrorMessage('Network error. Please try again or email us directly.');
    }
  }

  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Contact</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          Schedule a demo or get in touch. We’ll respond as soon as we can.
        </p>
      </Section>

      <Section tint>
        <div className="max-w-xl mx-auto">
          <h2 className="text-2xl font-bold text-slate-900 mb-6">Schedule a Demo</h2>

          {status === 'success' && (
            <div className="mb-6 p-4 rounded-lg bg-green-50 text-green-800 border border-green-200" role="status">
              Thanks! We’ve received your request and will be in touch soon.
            </div>
          )}
          {status === 'error' && (
            <div className="mb-6 p-4 rounded-lg bg-red-50 text-red-800 border border-red-200" role="alert">
              {errorMessage}{' '}
              <a href={`mailto:${SUPPORT_EMAIL}`} className="underline">Email us</a> if you prefer.
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-5">
            <div>
              <label htmlFor="name" className="block text-sm font-medium text-slate-700">
                Name <span className="text-red-600">*</span>
              </label>
              <input
                id="name"
                name="name"
                type="text"
                required
                autoComplete="name"
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              />
            </div>
            <div>
              <label htmlFor="email" className="block text-sm font-medium text-slate-700">
                Email <span className="text-red-600">*</span>
              </label>
              <input
                id="email"
                name="email"
                type="email"
                required
                autoComplete="email"
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              />
            </div>
            <div>
              <label htmlFor="facilityName" className="block text-sm font-medium text-slate-700">
                Facility Name <span className="text-red-600">*</span>
              </label>
              <input
                id="facilityName"
                name="facilityName"
                type="text"
                required
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              />
            </div>
            <div>
              <label htmlFor="facilityAddress" className="block text-sm font-medium text-slate-700">
                Facility Address (optional)
              </label>
              <input
                id="facilityAddress"
                name="facilityAddress"
                type="text"
                autoComplete="street-address"
                placeholder="123 Main St, City, State ZIP"
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              />
            </div>
            <div>
              <label htmlFor="phone" className="block text-sm font-medium text-slate-700">
                Phone (optional)
              </label>
              <input
                id="phone"
                name="phone"
                type="tel"
                autoComplete="tel"
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              />
            </div>
            <div>
              <label htmlFor="unitCount" className="block text-sm font-medium text-slate-700">
                Number of units (optional)
              </label>
              <select
                id="unitCount"
                name="unitCount"
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              >
                {UNIT_RANGES.map(({ value, label }) => (
                  <option key={value || 'empty'} value={value}>
                    {label}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="message" className="block text-sm font-medium text-slate-700">
                Message (optional)
              </label>
              <textarea
                id="message"
                name="message"
                rows={4}
                className="mt-1 block w-full rounded-lg border border-slate-300 px-3 py-2 text-slate-900 shadow-xs focus:border-primary focus:ring-1 focus:ring-primary"
              />
            </div>
            <button
              type="submit"
              disabled={status === 'sending'}
              className="w-full rounded-lg bg-primary px-4 py-3 text-sm font-medium text-white hover:bg-primary-dark disabled:opacity-60 transition-colors"
            >
              {status === 'sending' ? 'Sending…' : 'Submit'}
            </button>
          </form>
        </div>
      </Section>

      <Section>
        <h2 className="text-lg font-bold text-slate-900">Support & SMS</h2>
        <p className="mt-2 text-slate-600">
          For support: <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>
          {SUPPORT_PHONE && (
            <> · <a href={`tel:${SUPPORT_PHONE.replace(/\D/g, '')}`} className="text-primary hover:underline">{SUPPORT_PHONE}</a></>
          )}
        </p>
        <div className="mt-4">
          <A2pSnippet />
        </div>
      </Section>
    </>
  );
}
