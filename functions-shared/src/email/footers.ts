export function escapeHtml(text: string): string {
  const map: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;',
  };
  return text.replace(/[&<>"']/g, (m) => map[m]);
}

export function buildFacilityFooter(
  facilityName: string,
  facilityAddress?: string | null,
  facilityPhone?: string | null,
  compliance?: { unsubscribeUrl?: string } | null,
): { html: string; text: string } {
  const lines: string[] = [];
  if (facilityAddress) lines.push(facilityAddress);
  if (facilityPhone) lines.push(facilityPhone);

  let htmlFooter = '<hr style="margin:16px 0;border:none;border-top:1px solid #e0e0e0;"/>';
  htmlFooter += '<div style="font-size:14px;line-height:1.4;color:#666;margin-top:16px;">';
  htmlFooter += `<strong>${escapeHtml(facilityName)}</strong>`;
  if (lines.length > 0) {
    htmlFooter += '<br/>';
    htmlFooter += lines.map((line) => escapeHtml(line)).join('<br/>');
  }
  htmlFooter += '</div>';

  if (compliance?.unsubscribeUrl) {
    const u = compliance.unsubscribeUrl;
    htmlFooter += '<p style="font-size:12px;color:#888;margin-top:14px;line-height:1.5;">';
    htmlFooter +=
      'You are receiving this email in connection with your business relationship with this facility. ';
    htmlFooter += `<a href="${escapeHtml(u)}" style="color:#555;text-decoration:underline;">Unsubscribe</a> `;
    htmlFooter +=
      'from non-essential facility emails. Time-sensitive or legally required notices may still be sent.</p>';
  }

  let textFooter = '\n--\n';
  textFooter += facilityName;
  if (lines.length > 0) {
    textFooter += '\n' + lines.join('\n');
  }
  if (compliance?.unsubscribeUrl) {
    textFooter +=
      '\n\nUnsubscribe from non-essential facility emails: ' +
      compliance.unsubscribeUrl +
      '\n(Time-sensitive or legally required notices may still be sent.)';
  }

  return { html: htmlFooter, text: textFooter };
}

export function appendPlatformSecurityEmailFooter(html: string, text: string): { html: string; text: string } {
  const htmlFooter =
    '<hr style="margin:24px 0;border:none;border-top:1px solid #e0e0e0;"/>' +
    '<p style="font-size:12px;color:#666;line-height:1.5;">This is an automated security message from Storage Facility Creator. ' +
    'These messages are not promotional and are sent only to protect your account.</p>';
  const textFooter =
    '\n\n---\nThis is an automated security message from Storage Facility Creator. ' +
    'These messages are not promotional and are sent only to protect your account.';
  return { html: html + htmlFooter, text: text + textFooter };
}

export function appendPlatformAdminBroadcastFooter(html: string, text: string): { html: string; text: string } {
  const htmlFooter =
    '<hr style="margin:24px 0;border:none;border-top:1px solid #e0e0e0;"/>' +
    '<p style="font-size:12px;color:#666;line-height:1.5;">You are receiving this because your account owns at least one facility on Storage Facility Creator. ' +
    'This is an administrative message from the platform, not billing or marketing from an individual site.</p>';
  const textFooter =
    '\n\n---\nYou are receiving this because your account owns at least one facility on Storage Facility Creator. ' +
    'This is an administrative message from the platform, not billing or marketing from an individual site.';
  return { html: html + htmlFooter, text: text + textFooter };
}
