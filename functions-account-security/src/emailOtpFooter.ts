/** Non-promotional platform mail (OTP, etc.) — no List-Unsubscribe. */
export function appendPlatformSecurityEmailFooter(html: string, text: string): { html: string; text: string } {
  const htmlFooter =
    '<hr style="margin:24px 0;border:none;border-top:1px solid #e0e0e0"/>' +
    '<p style="font-size:12px;color:#666;line-height:1.5;">This is an automated security message from Storage Facility Creator. ' +
    'These messages are not promotional and are sent only to protect your account.</p>';
  const textFooter =
    '\n\n---\nThis is an automated security message from Storage Facility Creator. ' +
    'These messages are not promotional and are sent only to protect your account.';
  return { html: html + htmlFooter, text: text + textFooter };
}
