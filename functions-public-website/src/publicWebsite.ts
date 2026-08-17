import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

function normalizeDomain(raw: string): string {
  return raw.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/^www\./, '').split('/')[0];
}

function asNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Allow http(s) links only — blocks javascript: and malformed URLs. */
function safeHttpUrl(raw: string): string {
  const t = raw.trim();
  if (!t) return '';
  try {
    const u = new URL(t);
    if (u.protocol === 'https:' || u.protocol === 'http:') return u.toString();
  } catch {
    /* ignore */
  }
  return '';
}

/** Force rental links into lightweight embedded mode. */
function withEmbedMode(raw: string): string {
  const t = raw.trim();
  if (!t) return '';
  if (t.includes('/#/')) {
    if (t.includes('embed=1')) return t;
    const hashIndex = t.indexOf('#');
    if (hashIndex === -1) return t;
    const prefix = t.slice(0, hashIndex + 1);
    const hash = t.slice(hashIndex + 1);
    const sep = hash.includes('?') ? '&' : '?';
    return `${prefix}${hash}${sep}embed=1`;
  }
  try {
    const u = new URL(t);
    if (u.searchParams.get('embed') !== '1') {
      u.searchParams.set('embed', '1');
    }
    return u.toString();
  } catch {
    return t;
  }
}

/** Merge query params into a Flutter hash URL (`/#/path?a=b`). */
function appendHashQueryParams(raw: string, extra: Record<string, string>): string {
  const t = raw.trim();
  if (t.includes('/#/')) {
    const hashIndex = t.indexOf('#');
    if (hashIndex === -1) return t;
    const prefix = t.slice(0, hashIndex + 1);
    const hash = t.slice(hashIndex + 1);
    const q = hash.indexOf('?');
    const pathPart = q === -1 ? hash : hash.slice(0, q);
    const existing = q === -1 ? '' : hash.slice(q + 1);
    const params = new URLSearchParams(existing);
    for (const [k, v] of Object.entries(extra)) {
      if (v) params.set(k, v);
    }
    const newQs = params.toString();
    return newQs ? `${prefix}${pathPart}?${newQs}` : `${prefix}${pathPart}`;
  }
  try {
    const u = new URL(t);
    for (const [k, v] of Object.entries(extra)) {
      if (v) u.searchParams.set(k, v);
    }
    return u.toString();
  } catch {
    return t;
  }
}

function slugToDomId(raw: string): string {
  return raw.replace(/[^a-zA-Z0-9_-]/g, '-').replace(/-+/g, '-').toLowerCase();
}

function titleCaseWords(slug: string): string {
  return slug
    .split('-')
    .filter((p) => p.length > 0)
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join(' ');
}

/** Hero / logo images: https only to avoid mixed content and odd schemes. */
function safeHttpsImageUrl(raw: string): string | null {
  const t = raw.trim();
  if (!t.startsWith('https://')) return null;
  try {
    const u = new URL(t);
    if (u.protocol !== 'https:') return null;
    if (!u.hostname) return null;
    return u.toString();
  } catch {
    return null;
  }
}

/** Google Maps embed iframe src only. Accepts a raw URL or a full `<iframe>` tag. */
function safeGoogleMapsEmbedUrl(raw: string): string | null {
  let t = raw.trim();
  if (!t) return null;
  const srcMatch = t.match(/src\s*=\s*["']([^"']+)["']/i);
  if (srcMatch) t = srcMatch[1].trim();
  if (!t.startsWith('https://')) return null;
  try {
    const u = new URL(t);
    if (u.protocol !== 'https:') return null;
    const host = u.hostname.toLowerCase();
    if (host !== 'www.google.com' && host !== 'google.com' && !host.endsWith('.google.com')) return null;
    if (!u.pathname.toLowerCase().includes('/maps/embed')) return null;
    return u.toString();
  } catch {
    return null;
  }
}

function parseTestimonialLine(line: string): { quote: string; author: string } {
  const trimmed = line.trim();
  const sep = '---';
  const idx = trimmed.indexOf(sep);
  if (idx === -1) return { quote: trimmed, author: '' };
  return {
    quote: trimmed.slice(0, idx).trim(),
    author: trimmed.slice(idx + sep.length).trim(),
  };
}

function markdownToSafeHtml(raw: string): string {
  const text = escapeHtml(raw || '');
  // Lightweight markdown support for this template pass.
  return text
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\[([^\]]+)\]\((https:\/\/[^\s)]+)\)/g, '<a href="$2" rel="noopener noreferrer">$1</a>')
    .replace(/\n/g, '<br />');
}

function safeAmenityIcon(raw: string): string {
  const allowed = new Set([
    'clock',
    'truck',
    'shield',
    'key',
    'camera',
    'wifi',
    'zap',
    'snowflake',
    'door-open',
    'map-pin',
    'package',
    'lock',
    'car',
    'building',
  ]);
  const normalized = String(raw || '').trim().toLowerCase();
  return allowed.has(normalized) ? normalized : 'check';
}

function toHtml(payload: {
  title: string;
  description: string;
  marketingContent: string;
  heroHeadline: string;
  heroSubheadline: string;
  primaryCtaLabel: string;
  secondaryCtaLabel: string;
  paymentUrl: string;
  tenantPortalUrl: string;
  address: string;
  officeHours: string;
  amenities: string[];
  testimonials: string[];
  facilityName: string;
  facilityPhone: string;
  facilityLogoUrl: string | null;
  heroImageUrl: string | null;
  tagline: string;
  contactEmail: string;
  mapEmbedUrl: string | null;
  promoTitle: string;
  promoBody: string;
  promoCtaLabel: string;
  promoCtaUrl: string;
  promiseSecurity: string;
  promiseService: string;
  promiseConvenience: string;
  reviewUrl: string;
  startingAt: number | null;
  availableCount: number;
  facilitySlug: string;
  rentUrl: string;
  unitsUrl: string;
  categories: Array<{ name: string; count: number; startingAt: number | null }>;
  unitRows: Array<{
    unitId: string;
    unitNumber: string;
    categorySlug: string;
    categoryLabel: string;
    monthlyRate: number | null;
    sizeLabel: string;
    rentHref: string;
  }>;
  logoImageUrl?: string | null;
  phoneNumber?: string;
  showPaymentLoginButtonInHeader?: boolean;
  officeHoursStructured?: Record<string, { open?: string; close?: string; closed?: boolean }> | null;
  unitCategories?: Array<{
    slug: string;
    name: string;
    shortBlurb?: string;
    longDescription?: string;
    heroImageUrl?: string;
    startingPrice?: number | null;
    ctaLabel?: string;
    displayOrder?: number | null;
  }>;
  amenitiesStructured?: Array<{ label: string; icon?: string }>;
  testimonialsStructured?: Array<{ quote: string; reviewer?: string; rating?: number; source?: string }>;
  partnershipBand?: { title?: string; body?: string; imageUrl?: string; ctaLabel?: string; ctaUrl?: string } | null;
  footerTagline?: string;
  socialLinks?: { facebook?: string; instagram?: string; google?: string } | null;
  footerLegalText?: string;
  metaKeywords?: string;
  ogImageUrl?: string;
  canonicalUrl?: string;
  aboutSectionTitle?: string;
  aboutSectionBody?: string;
  aboutSectionImageUrl?: string;
  faqs?: Array<{ question: string; answer: string }>;
  pageUrl?: string;
  stepChooseIconUrl?: string;
  stepDetailsIconUrl?: string;
  stepReserveIconUrl?: string;
  promiseSecurityIconUrl?: string;
  promiseServiceIconUrl?: string;
  promiseConvenienceIconUrl?: string;
  categoryPage?: {
    slug: string;
    name: string;
    shortBlurb?: string;
    longDescription?: string;
    heroImageUrl?: string;
    startingPrice?: number | null;
    ctaLabel?: string;
  } | null;
}): string {
  // "Make a Payment/Login" is for existing tenants, not prospective renters — it must never
  // fall back to the rental flow (rentUrl/unitsUrl) or the operator admin login. Default to
  // the tenant portal unless the operator has set an explicit override in Website Setup.
  const paymentHref =
    safeHttpUrl(payload.paymentUrl) || safeHttpUrl(payload.tenantPortalUrl) || '#';
  // Keep rental navigation in-page for a smooth single-page flow.
  const unitsHref = '#unit-list';
  const promoCtaHref = safeHttpUrl(payload.promoCtaUrl);
  const reviewHref = safeHttpUrl(payload.reviewUrl);

  const logoSrc = safeHttpsImageUrl(payload.logoImageUrl || '') || safeHttpsImageUrl(payload.facilityLogoUrl || '');
  const heroBg = safeHttpsImageUrl(payload.heroImageUrl || '');

  const categorySlugListForNav = [
    ...new Set(payload.unitRows.map((u) => u.categorySlug).filter((s) => s.trim().length > 0)),
  ].sort((a, b) => a.localeCompare(b));

  const browseStripHtml =
    categorySlugListForNav.length > 0
      ? `<div class="browse-strip">
  <div class="wrap browse-pills">
    <a class="browse-pill" href="#home">Home</a>
    <a class="browse-pill" href="#about">About</a>
    ${categorySlugListForNav
      .map(
        (cat) =>
          `<a class="browse-pill" href="#${escapeHtml(`cat-${slugToDomId(cat)}`)}">${escapeHtml(
            titleCaseWords(cat),
          )}</a>`,
      )
      .join('')}
    <a class="browse-pill" href="#map">Map</a>
    <a class="browse-pill" href="#contact">Contact us</a>
  </div>
</div>`
      : '';

  const amenityList = payload.amenities.length
    ? payload.amenities.slice(0, 14)
    : ['Online rentals', 'Online bill pay', 'Secure access', 'Variety of unit sizes'];
  const amenityChips = amenityList.map((a) => `<span class="chip">${escapeHtml(a)}</span>`).join('');

  const visibleUnitRows =
    payload.categoryPage?.slug
      ? payload.unitRows.filter((u) => u.categorySlug === payload.categoryPage?.slug)
      : payload.unitRows;

  const buildLegendUnitGrid = (): string => {
    if (!visibleUnitRows.length) {
      return `<div class="legend-empty"><p class="muted">Units will appear as inventory is published.</p></div>`;
    }
    const amenityPick = amenityList.slice(0, 2);
    const byKey = new Map<string, typeof payload.unitRows>();
    for (const u of visibleUnitRows) {
      const size = (u.sizeLabel || '').trim() || 'Size varies';
      const key = `${u.categorySlug}|||${size}`;
      const arr = byKey.get(key) || [];
      arr.push(u);
      byKey.set(key, arr);
    }
    const rows = [...byKey.entries()].sort(([a], [b]) => a.localeCompare(b));
    return `<div class="legend-grid">${rows
      .map(([key, units]) => {
        const first = units[0];
        const catSlug = first.categorySlug || 'storage-units';
        const catPretty = titleCaseWords(catSlug);
        const size = (first.sizeLabel || '').trim() || 'Size varies';
        const title = `${size} · ${catPretty}`;
        const bullets: string[] = [`${size} storage unit`, `${catPretty} inventory`];
        for (const a of amenityPick) bullets.push(a);
        const rates = units.map((u) => u.monthlyRate).filter((r): r is number => r != null);
        const minRate = rates.length ? Math.min(...rates) : null;
        const priceText = minRate == null ? 'Call for rates' : `$${minRate.toFixed(0)} / month`;
        const cycleText =
          minRate == null
            ? 'Ask for monthly pricing'
            : `1 Month for $${minRate.toFixed(2)} ($${minRate.toFixed(2)} / month)`;
        const scarcity =
          units.length > 0 && units.length <= 3 ? `Only ${units.length} left!` : '';
        const rentBase = withEmbedMode(
          `https://app.storagefacilitycreator.com/#/f/${encodeURIComponent(
            payload.facilitySlug,
          )}/${encodeURIComponent(catSlug)}`,
        );
        const opts = units.map((u) => ({
          label: u.unitNumber,
          href: appendHashQueryParams(rentBase, { unitId: u.unitId, embed: '1' }),
        }));
        const optionsEnc = encodeURIComponent(JSON.stringify(opts));
        const bulletsEnc = encodeURIComponent(JSON.stringify(bullets));
        const domId = `cat-${slugToDomId(key)}`;
        return `<article class="legend-card" id="${escapeHtml(domId)}">
  <div class="legend-card-grid">
    <div class="legend-card-main">
      <h3 class="legend-card-title">${escapeHtml(title)}</h3>
      <ul class="legend-card-bullets">${bullets.map((b) => `<li>${escapeHtml(b)}</li>`).join('')}</ul>
    </div>
    <aside class="legend-card-aside">
      <div class="legend-thumb" aria-hidden="true"></div>
      <div class="legend-card-price-row">
        <span class="legend-price">${escapeHtml(priceText)}</span>
        ${scarcity ? `<span class="legend-scarcity">${escapeHtml(scarcity)}</span>` : ''}
      </div>
      <button type="button" class="legend-rent-btn" data-modal-open="1" data-rent-base="${escapeHtml(
        rentBase,
      )}" data-title="${escapeHtml(title)}" data-bullets-json="${bulletsEnc}" data-cycle="${escapeHtml(
        cycleText,
      )}" data-options="${optionsEnc}">Rent now</button>
    </aside>
  </div>
</article>`;
      })
      .join('')}</div>`;
  };

  const unitRowsHtml = buildLegendUnitGrid();

  const defaultFeatures = [
    'Online rentals',
    'Online bill pay',
    'Variety of unit sizes',
    'Secure facility access',
    'Live availability',
    'Fast move-in flow',
  ];
  const featureMerged = [...new Set([...defaultFeatures, ...amenityList])].slice(0, 8);
  const featureCells = featureMerged
    .map((f) => `<div class="feature-cell"><span class="tick" aria-hidden="true">✓</span>${escapeHtml(f)}</div>`)
    .join('');

  const structuredTestimonials = Array.isArray(payload.testimonialsStructured)
    ? payload.testimonialsStructured.filter((t) => String(t?.quote || '').trim().length > 0)
    : [];
  const testimonialsHtml = (structuredTestimonials.length
    ? structuredTestimonials.slice(0, 8).map((item) => {
        const rating = Math.max(1, Math.min(5, Number(item.rating || 5)));
        const stars = '★'.repeat(rating) + '☆'.repeat(5 - rating);
        const reviewer = String(item.reviewer || '').trim();
        const source = String(item.source || '').trim();
        const byline = [reviewer, source].filter((v) => v.length > 0).join(' • ');
        return `<article class="quote-card"><p class="quote-text">“${escapeHtml(
          String(item.quote || ''),
        )}”</p><div class="stars" aria-hidden="true">${escapeHtml(stars)}</div>${
          byline ? `<footer class="quote-author">— ${escapeHtml(byline)}</footer>` : ''
        }</article>`;
      })
    : (payload.testimonials.length ? payload.testimonials.slice(0, 4) : ['Great facility and easy online rentals.']).map(
        (raw) => {
          const { quote, author } = parseTestimonialLine(raw);
          const q = escapeHtml(quote);
          const a = author ? `<footer class="quote-author">— ${escapeHtml(author)}</footer>` : '';
          return `<article class="quote-card"><p class="quote-text">“${q}”</p><div class="stars" aria-hidden="true">★★★★★</div>${a}</article>`;
        },
      ))
    .join('');

  const addressDisplay =
    payload.address.trim().length > 0 ? payload.address : 'Contact us for facility address details.';
  const structuredHours = payload.officeHoursStructured && typeof payload.officeHoursStructured === 'object'
    ? payload.officeHoursStructured
    : null;
  const officeHoursHtml = structuredHours
    ? ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday']
        .map((day) => {
          const entry = structuredHours[day] || {};
          const label = day.charAt(0).toUpperCase() + day.slice(1);
          if (entry.closed) return `<li><strong>${escapeHtml(label)}:</strong> Closed</li>`;
          const open = String(entry.open || '').trim();
          const close = String(entry.close || '').trim();
          if (!open || !close) return `<li><strong>${escapeHtml(label)}:</strong> Closed</li>`;
          return `<li><strong>${escapeHtml(label)}:</strong> ${escapeHtml(open)} - ${escapeHtml(close)}</li>`;
        })
        .join('')
    : payload.officeHours
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => line.length > 0)
        .map((line) => `<li>${escapeHtml(line)}</li>`)
        .join('');

  const phoneDisplay = (payload.phoneNumber || '').trim() || (payload.facilityPhone || '').trim() || 'Call for details';
  const phoneDigits = phoneDisplay.replace(/\D/g, '');
  const phoneTelHref = phoneDigits.length >= 10 ? `tel:${escapeHtml(phoneDigits)}` : '';
  const emailDisplay = (payload.contactEmail || '').trim();
  const emailRow =
    emailDisplay.length > 0
      ? `<p class="contact-line"><a href="mailto:${escapeHtml(emailDisplay)}">${escapeHtml(emailDisplay)}</a></p>`
      : '';

  const mapSrc = safeGoogleMapsEmbedUrl(payload.mapEmbedUrl || '');
  const mapBlock = mapSrc
    ? `<div class="map-frame" role="region" aria-label="Map"><iframe title="Facility map" loading="lazy" referrerpolicy="no-referrer-when-downgrade" src="${escapeHtml(mapSrc)}"></iframe></div>`
    : `<div class="map-placeholder"><p class="muted">Add a Google Maps embed URL in Website Setup to show your map here.</p></div>`;

  const taglineHtml =
    payload.tagline.trim().length > 0
      ? `<p class="site-tagline">${escapeHtml(payload.tagline)}</p>`
      : `<p class="site-tagline">Self storage with online rentals</p>`;

  const promiseS =
    payload.promiseSecurity.trim().length > 0
      ? escapeHtml(payload.promiseSecurity)
      : 'Robust security measures help keep your belongings protected while they are stored with us.';
  const promiseSv =
    payload.promiseService.trim().length > 0
      ? escapeHtml(payload.promiseService)
      : 'Clean, move-in ready units and a friendly team focused on a smooth rental experience.';
  const promiseC =
    payload.promiseConvenience.trim().length > 0
      ? escapeHtml(payload.promiseConvenience)
      : 'Manage your storage online anytime—browse availability, rent, and stay on top of payments.';

  const promoSection =
    payload.promoTitle.trim().length > 0 || payload.promoBody.trim().length > 0
      ? `<section class="section promo-band" id="promo">
  <div class="wrap promo-inner">
    <div>
      <h2 class="section-title promo-title">${escapeHtml(payload.promoTitle.trim() || 'Special services')}</h2>
      <p class="promo-body">${escapeHtml(payload.promoBody)}</p>
    </div>
    ${
      promoCtaHref && payload.promoCtaLabel.trim().length > 0
        ? `<a class="btn btn-light" href="${escapeHtml(promoCtaHref)}">${escapeHtml(payload.promoCtaLabel)}</a>`
        : ''
    }
  </div>
</section>`
      : '';
  const partnershipBand = payload.partnershipBand || null;
  const hasPartnershipBand = !!partnershipBand &&
    (String(partnershipBand.title || '').trim().length > 0 ||
      String(partnershipBand.body || '').trim().length > 0 ||
      String(partnershipBand.imageUrl || '').trim().length > 0);
  const partnershipCtaUrl = safeHttpUrl(String(partnershipBand?.ctaUrl || ''));
  const partnershipImageUrl = safeHttpsImageUrl(String(partnershipBand?.imageUrl || ''));
  const partnershipSection = hasPartnershipBand
    ? `<section class="section">
  <div class="wrap">
    <div class="banner" style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:18px;align-items:center">
      <div>
        <h2 class="section-title" style="margin:0 0 8px">${escapeHtml(String(partnershipBand?.title || ''))}</h2>
        <p class="muted" style="margin:0">${escapeHtml(String(partnershipBand?.body || ''))}</p>
        ${
          partnershipCtaUrl && String(partnershipBand?.ctaLabel || '').trim().length > 0
            ? `<div style="margin-top:12px"><a class="btn btn-light" href="${escapeHtml(partnershipCtaUrl)}">${escapeHtml(
                String(partnershipBand?.ctaLabel || ''),
              )}</a></div>`
            : ''
        }
      </div>
      ${partnershipImageUrl ? `<img src="${escapeHtml(partnershipImageUrl)}" alt="${escapeHtml(String(partnershipBand?.title || payload.facilityName))}" loading="lazy" style="width:160px;max-width:100%;border-radius:12px;border:1px solid var(--line)" />` : ''}
    </div>
  </div>
</section>`
    : '';

  const hasAboutSection = String(payload.aboutSectionBody || '').trim().length > 0;
  const aboutImage = safeHttpsImageUrl(String(payload.aboutSectionImageUrl || ''));
  const aboutSection = hasAboutSection
    ? `<section class="section" id="about-story">
  <div class="wrap">
    <div class="banner" style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:18px;align-items:center">
      <div>
        <h2 class="section-title" style="margin:0 0 8px">${escapeHtml(String(payload.aboutSectionTitle || 'Our story'))}</h2>
        <p class="muted" style="margin:0;font-size:1rem">${markdownToSafeHtml(String(payload.aboutSectionBody || ''))}</p>
      </div>
      ${aboutImage ? `<img src="${escapeHtml(aboutImage)}" alt="About ${escapeHtml(payload.facilityName)}" loading="lazy" style="width:180px;max-width:100%;border-radius:12px;border:1px solid var(--line)" />` : ''}
    </div>
  </div>
</section>`
    : '';

  const configuredCategories = Array.isArray(payload.unitCategories)
    ? payload.unitCategories
        .map((item) => ({
          slug: String(item.slug || '').trim().toLowerCase(),
          name: String(item.name || '').trim(),
          shortBlurb: String(item.shortBlurb || '').trim(),
          longDescription: String(item.longDescription || '').trim(),
          heroImageUrl: String(item.heroImageUrl || '').trim(),
          startingPrice: item.startingPrice == null ? null : Number(item.startingPrice),
          ctaLabel: String(item.ctaLabel || '').trim(),
          displayOrder: item.displayOrder == null ? Number.MAX_SAFE_INTEGER : Number(item.displayOrder),
        }))
        .filter((item) => item.slug && item.name)
        .sort((a, b) => a.displayOrder - b.displayOrder)
    : [];
  const categoryGridSection = configuredCategories.length > 0
    ? `<section class="section">
  <div class="wrap">
    <div class="section-head">
      <h2 class="section-title">Browse by category</h2>
    </div>
    <div class="cat-grid">
      ${configuredCategories
        .map((cat) => {
          const cta = cat.ctaLabel || 'Learn More';
          const price = Number.isFinite(cat.startingPrice || NaN) ? `Starting at $${Number(cat.startingPrice).toFixed(0)}` : '';
          return `<article class="cat-card">
  <h3>${escapeHtml(cat.name)}</h3>
  <p class="cat-meta">${escapeHtml(cat.shortBlurb || '')}</p>
  ${price ? `<p class="cat-meta">${escapeHtml(price)}</p>` : ''}
  <div class="cat-actions">
    <a class="text-link" href="/w/${encodeURIComponent(payload.facilitySlug)}/c/${encodeURIComponent(cat.slug)}">${escapeHtml(cta)}</a>
  </div>
</article>`;
        })
        .join('')}
    </div>
  </div>
</section>`
    : '';

  const structuredAmenities = Array.isArray(payload.amenitiesStructured)
    ? payload.amenitiesStructured
        .map((item) => ({
          label: String(item.label || '').trim(),
          icon: safeAmenityIcon(String(item.icon || '')),
        }))
        .filter((item) => item.label.length > 0)
    : [];
  const amenitiesSection = structuredAmenities.length > 0
    ? `<section class="section alt">
  <div class="wrap">
    <h2 class="section-title" style="margin-bottom:16px">All the convenience and security you need</h2>
    <div class="feature-grid">
      ${structuredAmenities
        .map(
          (item) =>
            `<div class="feature-cell"><i data-lucide="${escapeHtml(item.icon)}" class="tick" style="width:16px;height:16px"></i>${escapeHtml(
              item.label,
            )}</div>`,
        )
        .join('')}
    </div>
  </div>
</section>`
    : `<section class="section alt">
  <div class="wrap">
    <h2 class="section-title" style="margin-bottom:16px">All the convenience and security you need</h2>
    <div class="feature-grid">${featureCells}</div>
  </div>
</section>`;

  const faqs = Array.isArray(payload.faqs)
    ? payload.faqs
        .map((f) => ({
          question: String(f.question || '').trim(),
          answer: String(f.answer || '').trim(),
        }))
        .filter((f) => f.question && f.answer)
    : [];
  const faqSection = faqs.length > 0
    ? `<section class="section">
  <div class="wrap">
    <h2 class="section-title" style="margin-bottom:16px">Frequently asked questions</h2>
    ${faqs
      .map(
        (f) =>
          `<details class="unit-dropdown"><summary>${escapeHtml(f.question)}</summary><div style="padding:4px 2px 10px;color:var(--muted)">${markdownToSafeHtml(
            f.answer,
          )}</div></details>`,
      )
      .join('')}
  </div>
</section>`
    : '';

  const categoryPage = payload.categoryPage || null;
  const isCategoryPage = !!categoryPage;
  const categoryHeroImage = safeHttpsImageUrl(String(categoryPage?.heroImageUrl || ''));
  const categoryIntroSection = isCategoryPage
    ? `<section class="section">
  <div class="wrap">
    <a class="text-link" href="/w/${encodeURIComponent(payload.facilitySlug)}">&larr; Back to all categories</a>
    <div class="banner" style="margin-top:12px;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:18px;align-items:center">
      <div>
        <h2 class="section-title" style="margin:0 0 8px">${escapeHtml(String(categoryPage?.name || 'Category'))}</h2>
        <p class="muted" style="margin:0">${markdownToSafeHtml(String(categoryPage?.longDescription || categoryPage?.shortBlurb || ''))}</p>
      </div>
      ${categoryHeroImage ? `<img src="${escapeHtml(categoryHeroImage)}" alt="${escapeHtml(String(categoryPage?.name || payload.facilityName))} storage" loading="lazy" style="width:190px;max-width:100%;border-radius:12px;border:1px solid var(--line)" />` : ''}
    </div>
  </div>
</section>`
    : '';

  const stepChooseIcon = safeHttpsImageUrl(String(payload.stepChooseIconUrl || ''));
  const stepDetailsIcon = safeHttpsImageUrl(String(payload.stepDetailsIconUrl || ''));
  const stepReserveIcon = safeHttpsImageUrl(String(payload.stepReserveIconUrl || ''));
  const promiseSecurityIcon = safeHttpsImageUrl(String(payload.promiseSecurityIconUrl || ''));
  const promiseServiceIcon = safeHttpsImageUrl(String(payload.promiseServiceIconUrl || ''));
  const promiseConvenienceIcon = safeHttpsImageUrl(String(payload.promiseConvenienceIconUrl || ''));
  /** Renders an operator-uploaded icon image if set, otherwise a default Lucide icon. */
  const cardIcon = (uploadedUrl: string | null, lucideName: string, alt: string): string =>
    uploadedUrl
      ? `<img class="card-icon-img" src="${escapeHtml(uploadedUrl)}" alt="${escapeHtml(alt)}" width="28" height="28" loading="lazy" />`
      : `<i class="card-icon-glyph" data-lucide="${escapeHtml(lucideName)}" aria-hidden="true"></i>`;

  const howItWorksSection = isCategoryPage
    ? ''
    : `<section class="section" id="how-it-works">
  <div class="wrap">
    <div class="section-head">
      <h2 class="section-title">How it works</h2>
    </div>
    <div class="steps-grid">
      <article class="step-card">
        <div class="card-icon-badge">${cardIcon(stepChooseIcon, 'search', 'Choose your unit')}</div>
        <h3>1. Choose your unit</h3>
        <p>Browse live availability and pick the size that fits.</p>
      </article>
      <article class="step-card">
        <div class="card-icon-badge">${cardIcon(stepDetailsIcon, 'clipboard-list', 'Enter your details')}</div>
        <h3>2. Enter your details</h3>
        <p>A quick online form — no office visit required.</p>
      </article>
      <article class="step-card">
        <div class="card-icon-badge">${cardIcon(stepReserveIcon, 'key-round', 'Reserve online')}</div>
        <h3>3. Reserve online</h3>
        <p>Move in on your schedule with instant confirmation.</p>
      </article>
    </div>
  </div>
</section>`;

  const startingLabel = payload.startingAt == null ? 'Call for rates' : `$${payload.startingAt.toFixed(2)}`;
  // Quoted url("...") — not escapeHtml, and not a bare url(...) — is deliberate: heroBg is
  // already a validated https:// URL (safeHttpsImageUrl), whose serialization can still
  // contain a literal ")" (parentheses aren't in the URL spec's percent-encode set), which
  // would otherwise close the CSS url() early and let the rest of the string be interpreted
  // as CSS inside this rule. Quoting closes that hole (a literal '"' cannot survive URL
  // serialization). escapeHtml is wrong here regardless: this is a CSS value, not HTML, so it
  // would mangle a legitimate "&" in a query string into a literal "&amp;" in the URL.
  const heroStyle = heroBg
    ? `--hero-image:url("${heroBg}");`
    : `--hero-image:linear-gradient(135deg,#0f7669 0%,#134e4a 55%,#0f172a 100%);`;

  const logoBlock = logoSrc
    ? `<img class="brand-logo" src="${escapeHtml(logoSrc)}" alt="${escapeHtml(payload.facilityName)} logo" width="48" height="48" />`
    : `<div class="brand-mark" aria-hidden="true">${escapeHtml(payload.facilityName.trim().charAt(0) || 'S')}</div>`;

  const topPhone =
    phoneTelHref.length > 0
      ? `<a class="top-link" href="${phoneTelHref}">${escapeHtml(phoneDisplay)}</a>`
      : `<span class="top-muted">${escapeHtml(phoneDisplay)}</span>`;

  const reviewFooter =
    reviewHref.length > 0
      ? `<a class="footer-link" href="${escapeHtml(reviewHref)}" rel="noopener noreferrer">Leave us a review</a>`
      : '';

  const socialLinks = payload.socialLinks || {};
  const socialLinkItems = [
    { key: 'facebook', href: safeHttpUrl(String(socialLinks.facebook || '')), icon: 'facebook' },
    { key: 'instagram', href: safeHttpUrl(String(socialLinks.instagram || '')), icon: 'instagram' },
    { key: 'google', href: safeHttpUrl(String(socialLinks.google || '')), icon: 'search' },
  ].filter((item) => item.href.length > 0);
  const socialLinksHtml = socialLinkItems
    .map(
      (item) =>
        `<a class="footer-link" href="${escapeHtml(item.href)}" rel="noopener noreferrer" aria-label="${escapeHtml(
          item.key,
        )}"><i data-lucide="${escapeHtml(item.icon)}" style="width:16px;height:16px"></i></a>`,
    )
    .join('');

  const footerLegalText =
    String(payload.footerLegalText || '').trim() || 'Powered by Storage Facility Creator';
  const footerTagline = String(payload.footerTagline || '').trim();
  const pageUrl = safeHttpUrl(String(payload.pageUrl || ''));
  // Canonical/OG URL always resolves to something — an operator-set override, or this
  // page's own real address — so social unfurlers and search engines never see a blank.
  const canonicalHref = safeHttpUrl(String(payload.canonicalUrl || '')) || pageUrl;
  const ogImage = safeHttpsImageUrl(String(payload.ogImageUrl || '')) || heroBg || logoSrc;
  const metaKeywords = String(payload.metaKeywords || '').trim();
  const ogTitle = escapeHtml(payload.title);
  const ogDescription = escapeHtml(payload.description.slice(0, 300));

  const jsonLd: Record<string, unknown> = {
    '@context': 'https://schema.org',
    '@type': 'SelfStorage',
    name: payload.facilityName,
  };
  if (pageUrl) jsonLd.url = pageUrl;
  if (ogImage) jsonLd.image = ogImage;
  if (payload.facilityPhone.trim()) jsonLd.telephone = payload.facilityPhone.trim();
  if (payload.address.trim()) {
    jsonLd.address = { '@type': 'PostalAddress', streetAddress: payload.address.trim() };
  }
  const jsonLdScript = `<script type="application/ld+json">${JSON.stringify(jsonLd).replace(/</g, '\\u003c')}</script>`;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(payload.title)}</title>
  <meta name="description" content="${escapeHtml(payload.description)}" />
  ${metaKeywords ? `<meta name="keywords" content="${escapeHtml(metaKeywords)}" />` : ''}
  <meta name="robots" content="index, follow" />
  ${canonicalHref ? `<link rel="canonical" href="${escapeHtml(canonicalHref)}" />` : ''}
  <meta property="og:type" content="business.business" />
  <meta property="og:site_name" content="${escapeHtml(payload.facilityName)}" />
  <meta property="og:title" content="${ogTitle}" />
  <meta property="og:description" content="${ogDescription}" />
  ${pageUrl ? `<meta property="og:url" content="${escapeHtml(pageUrl)}" />` : ''}
  ${ogImage ? `<meta property="og:image" content="${escapeHtml(ogImage)}" />` : ''}
  <meta name="twitter:card" content="${ogImage ? 'summary_large_image' : 'summary'}" />
  <meta name="twitter:title" content="${ogTitle}" />
  <meta name="twitter:description" content="${ogDescription}" />
  ${ogImage ? `<meta name="twitter:image" content="${escapeHtml(ogImage)}" />` : ''}
  ${jsonLdScript}
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=DM+Sans:ital,opsz,wght@0,9..40,400;0,9..40,600;0,9..40,700;1,9..40,400&display=swap" rel="stylesheet" />
  <style>
    :root{
      --bg:#f4f6f8;
      --surface:#ffffff;
      --ink:#0f172a;
      --muted:#64748b;
      --line:#e2e8f0;
      --accent:#0f7669;
      --accent-2:#0d9488;
      --hero-ink:#f8fafc;
      --shadow:0 14px 40px rgba(15,23,42,.08);
      --radius:14px;
      --font:'DM Sans',system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
    }
    *{box-sizing:border-box}
    html{scroll-behavior:smooth}
    /* Sticky header (~64px); keeps in-page anchors from hiding under the bar */
    #home,#about,#units,#unit-list,#contact,#map,#promo,[id^="cat-"]{scroll-margin-top:88px}
    body{margin:0;font-family:var(--font);background:var(--bg);color:var(--ink);line-height:1.55}
    a{color:var(--accent-2)}
    .wrap{max-width:1120px;margin:0 auto;padding:0 22px}
    .topbar{background:#0f172a;color:#e2e8f0;font-size:.9rem}
    .topbar .wrap{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;padding:10px 22px}
    .top-link{color:#f8fafc;text-decoration:none;font-weight:600}
    .top-link:hover{text-decoration:underline}
    .top-muted{opacity:.85}
    .btn-pay{display:inline-flex;align-items:center;gap:8px;padding:8px 14px;border-radius:999px;background:#fff;color:#0f172a;text-decoration:none;font-weight:700;font-size:.88rem}
    .btn-pay:hover{filter:brightness(.97)}
    .site-header{background:var(--surface);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:20;backdrop-filter:saturate(1.2) blur(6px)}
    .header-row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:14px 0;flex-wrap:wrap}
    .brand-lockup{display:flex;align-items:center;gap:12px;min-width:200px}
    .brand-logo{width:48px;height:48px;object-fit:contain;border-radius:10px;background:#f8fafc;border:1px solid var(--line)}
    .brand-mark{width:48px;height:48px;border-radius:12px;background:linear-gradient(135deg,var(--accent),#134e4a);color:#fff;display:grid;place-items:center;font-weight:800;font-size:1.1rem}
    .brand-text .name{margin:0;font-size:1.15rem;font-weight:800;letter-spacing:-.02em;line-height:1.2}
    .site-tagline{margin:2px 0 0;font-size:.82rem;color:var(--muted);max-width:36ch}
    nav{display:flex;gap:6px 14px;flex-wrap:wrap;align-items:center;justify-content:flex-end}
    nav a{color:var(--ink);text-decoration:none;font-weight:600;font-size:.9rem;padding:6px 2px;border-bottom:2px solid transparent}
    nav a:hover{border-bottom-color:var(--accent-2);color:var(--accent-2)}
    .hero-shell{margin:0;background:var(--surface)}
    .hero{
      ${heroStyle}
      background-image:var(--hero-image);
      background-size:cover;background-position:center;
      position:relative;color:var(--hero-ink);padding:clamp(52px,10vw,96px) 0;
    }
    .hero::before{
      content:'';position:absolute;inset:0;
      background:linear-gradient(120deg,rgba(15,23,42,.82) 0%,rgba(15,118,105,.45) 48%,rgba(15,23,42,.55) 100%);
    }
    .hero .wrap{position:relative;z-index:1}
    .eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:.72rem;font-weight:700;opacity:.85;margin:0 0 10px}
    .hero h1{margin:0;font-size:clamp(1.85rem,4vw,2.65rem);font-weight:800;letter-spacing:-.03em;line-height:1.1;max-width:18ch}
    .hero .sub{margin:14px 0 0;font-size:1.05rem;max-width:52ch;opacity:.92}
    .cta{display:flex;gap:12px;flex-wrap:wrap;margin-top:22px}
    .btn{display:inline-flex;align-items:center;justify-content:center;padding:12px 20px;border-radius:999px;text-decoration:none;font-weight:700;font-size:.95rem;border:0;cursor:pointer;transition:transform .12s ease,box-shadow .12s ease}
    .btn:active{transform:translateY(1px)}
    .btn-primary{background:#f8fafc;color:#0f172a;box-shadow:0 10px 30px rgba(0,0,0,.2)}
    .btn-primary:hover{box-shadow:0 12px 34px rgba(0,0,0,.28)}
    .btn-ghost{background:rgba(255,255,255,.12);color:#f8fafc;border:1px solid rgba(248,250,252,.35)}
    .btn-ghost:hover{background:rgba(255,255,255,.18)}
    .btn-light{background:#fff;color:#0f172a;border:1px solid var(--line)}
    .section{padding:clamp(40px,6vw,72px) 0}
    .section.alt{background:#eef2f6}
    .section-head{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:22px}
    .section-title{margin:0;font-size:clamp(1.35rem,2.4vw,1.75rem);font-weight:800;letter-spacing:-.02em}
    .muted{color:var(--muted)}
    .banner{
      background:linear-gradient(135deg,#ecfeff,#f0fdfa);
      border:1px solid #99f6e4;border-radius:var(--radius);
      padding:22px 24px;box-shadow:var(--shadow);
    }
    .banner strong{display:block;font-size:1.05rem;margin-bottom:8px;color:#115e59}
    .pricing-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:18px}
    .price-card{
      background:var(--surface);border-radius:var(--radius);padding:22px 22px 20px;
      border:1px solid var(--line);box-shadow:var(--shadow);
    }
    .price-card h3{margin:0 0 6px;font-size:.95rem;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
    .price-big{margin:6px 0 14px;font-size:2.1rem;font-weight:800;letter-spacing:-.03em}
    .price-card p{margin:0 0 14px;color:var(--muted);font-size:.95rem}
    .cat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}
    .cat-card{
      background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);
      padding:20px;box-shadow:0 8px 24px rgba(15,23,42,.06);
    }
    .cat-card h3{margin:0 0 8px;font-size:1.1rem}
    .cat-meta{margin:0 0 12px;color:var(--muted);font-size:.92rem}
    .text-link{font-weight:700;color:var(--accent);text-decoration:none}
    .text-link:hover{text-decoration:underline}
    .cat-actions{display:flex;gap:14px;flex-wrap:wrap}
    .unit-list{display:grid;gap:12px}
    .unit-dropdown{
      background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:8px 14px;
      box-shadow:0 8px 24px rgba(15,23,42,.06);
    }
    .unit-dropdown + .unit-dropdown{margin-top:12px}
    .unit-dropdown summary{
      list-style:none;cursor:pointer;display:flex;align-items:center;justify-content:space-between;
      gap:10px;padding:8px 2px;font-weight:700;
    }
    .unit-dropdown summary::-webkit-details-marker{display:none}
    .pill{
      display:inline-flex;align-items:center;padding:4px 10px;border-radius:999px;background:#ecfeff;color:#0f7669;
      font-size:.8rem;font-weight:700;border:1px solid #99f6e4;
    }
    .unit-row{
      display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;
      background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:16px 18px;
      box-shadow:0 8px 24px rgba(15,23,42,.06);
    }
    .unit-row h3{margin:0 0 6px;font-size:1.03rem}
    .unit-row-right{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
    .unit-rate{margin:0;font-weight:800;font-size:1.03rem}
    .chip-wrap{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
    .chip{
      display:inline-flex;align-items:center;padding:8px 12px;border-radius:999px;
      background:#fff;border:1px solid var(--line);font-size:.85rem;font-weight:600;color:#334155
    }
    .feature-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px}
    .feature-cell{
      display:flex;align-items:flex-start;gap:10px;background:var(--surface);
      border:1px solid var(--line);border-radius:12px;padding:12px 14px;font-weight:600;font-size:.92rem
    }
    .tick{color:var(--accent);font-weight:800;margin-top:1px}
    .promise-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:18px}
    .promise-card{background:var(--surface);border-radius:var(--radius);padding:22px;border:1px solid var(--line);box-shadow:var(--shadow)}
    .promise-card h3{margin:0 0 10px;font-size:1.05rem}
    .promise-card p{margin:0;color:var(--muted);font-size:.95rem}
    .steps-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}
    .step-card{background:var(--surface);border-radius:var(--radius);padding:22px;border:1px solid var(--line);box-shadow:var(--shadow)}
    .step-card h3{margin:0 0 10px;font-size:1.05rem}
    .step-card p{margin:0;color:var(--muted);font-size:.95rem}
    .card-icon-badge{width:44px;height:44px;border-radius:12px;background:rgba(15,118,105,.1);display:flex;align-items:center;justify-content:center;margin-bottom:14px}
    .card-icon-glyph{width:22px;height:22px;color:var(--accent)}
    .card-icon-img{width:26px;height:26px;object-fit:contain;border-radius:6px}
    .quotes{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}
    .quote-card{
      background:var(--surface);border-radius:var(--radius);padding:22px;border:1px solid var(--line);
      box-shadow:var(--shadow);
    }
    .quote-text{margin:0;font-size:1.02rem;font-style:italic;color:#1e293b}
    .quote-author{margin:12px 0 0;font-size:.88rem;font-weight:700;color:var(--muted)}
    .stars{margin-top:10px;color:#ca8a04;font-size:.95rem;letter-spacing:.08em}
    .promo-band{background:linear-gradient(120deg,#134e4a,#0f7669);color:#ecfeff}
    .promo-inner{display:flex;align-items:center;justify-content:space-between;gap:20px;flex-wrap:wrap;padding:8px 0}
    .promo-title{color:#f8fafc}
    .promo-body{margin:8px 0 0;max-width:62ch;opacity:.95}
    .contact-grid{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.1fr);gap:22px;align-items:stretch}
    @media (max-width:880px){.contact-grid{grid-template-columns:1fr}}
    .contact-card{background:var(--surface);border-radius:var(--radius);padding:22px;border:1px solid var(--line);box-shadow:var(--shadow)}
    .contact-card h3{margin-top:0}
    .contact-line{margin:6px 0}
    .hours-list{margin:0;padding-left:18px;color:var(--muted)}
    .map-frame{border-radius:var(--radius);overflow:hidden;border:1px solid var(--line);box-shadow:var(--shadow);min-height:280px;background:#e2e8f0}
    .map-frame iframe{width:100%;height:320px;border:0;display:block}
    .map-placeholder{
      border-radius:var(--radius);border:1px dashed #cbd5e1;background:#f8fafc;
      min-height:280px;display:grid;place-items:center;padding:20px;text-align:center
    }
    .site-footer{background:#0f172a;color:#94a3b8;padding:28px 0;margin-top:12px}
    .footer-row{display:flex;flex-wrap:wrap;gap:12px 20px;align-items:center;justify-content:space-between}
    .footer-brand{color:#e2e8f0;font-weight:700}
    .footer-link{color:#5eead4;text-decoration:none;font-weight:600}
    .footer-link:hover{text-decoration:underline}
    .fine{font-size:.85rem;opacity:.9}
    .browse-strip{background:var(--surface);border-bottom:1px solid var(--line);padding:10px 0}
    .browse-pills{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
    .browse-pill{
      display:inline-flex;align-items:center;padding:8px 14px;border-radius:999px;
      background:#eef2f6;color:#334155;font-weight:600;font-size:.88rem;text-decoration:none;border:1px solid #dbe2ea
    }
    .browse-pill:hover{background:#e2e8f0;color:#0f172a}
    .legend-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:18px}
    .legend-card{
      background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:18px;
      box-shadow:var(--shadow);
    }
    .legend-card-grid{display:grid;grid-template-columns:1fr minmax(140px,180px);gap:16px;align-items:start}
    @media (max-width:720px){.legend-card-grid{grid-template-columns:1fr}}
    .legend-card-title{margin:0;font-size:1.05rem;font-weight:800;color:#0f172a;letter-spacing:-.02em}
    .legend-card-bullets{margin:10px 0 0;padding-left:18px;color:#475569;font-size:.92rem}
    .legend-card-bullets li{margin:4px 0}
    .legend-card-aside{display:flex;flex-direction:column;align-items:stretch;gap:12px}
    .legend-thumb{
      height:110px;border-radius:12px;background:linear-gradient(145deg,#e2e8f0,#f8fafc);
      border:1px solid var(--line);position:relative;overflow:hidden
    }
    .legend-thumb::after{
      content:'';position:absolute;inset:18% 22%;border-radius:6px;
      background:linear-gradient(180deg,#cbd5e1,#94a3b8);opacity:.55
    }
    .legend-card-price-row{display:flex;align-items:baseline;justify-content:space-between;gap:10px;flex-wrap:wrap}
    .legend-price{font-size:1.25rem;font-weight:800;color:#0f172a}
    .legend-scarcity{color:#b91c1c;font-weight:700;font-size:.85rem}
    .legend-rent-btn{
      width:100%;border:0;border-radius:10px;padding:12px 14px;font-weight:800;font-size:.92rem;
      background:#0f172a;color:#fff;cursor:pointer
    }
    .legend-rent-btn:hover{filter:brightness(1.06)}
    .legend-rent-btn:disabled{opacity:.45;cursor:not-allowed}
    .rent-modal{position:fixed;inset:0;z-index:80;display:none;align-items:center;justify-content:center;padding:18px}
    .rent-modal.open{display:flex}
    .rent-modal-backdrop{position:absolute;inset:0;background:rgba(15,23,42,.45)}
    .rent-modal-panel{
      position:relative;z-index:1;width:min(520px,100%);max-height:min(92vh,900px);overflow:auto;
      background:#fff;border-radius:16px;padding:22px 22px 18px;box-shadow:0 24px 80px rgba(15,23,42,.25);
      border:1px solid var(--line)
    }
    .rent-modal-close{
      position:absolute;top:10px;right:12px;border:0;background:transparent;font-size:1.6rem;line-height:1;
      cursor:pointer;color:#64748b
    }
    .rent-modal-title{margin:0 28px 8px 0;font-size:1.15rem;font-weight:800;color:#0f172a}
    .rent-modal-desc ul{margin:0;padding-left:18px;color:#475569;font-size:.92rem}
    .rent-modal-pay{margin:16px 0 0}
    .rent-modal-pay h3{margin:0 0 8px;font-size:.95rem;font-weight:800;color:#0f172a}
    .rent-pay-card{
      display:flex;align-items:flex-start;gap:10px;border:1px solid var(--line);border-radius:12px;padding:12px 14px;
      background:#f8fafc
    }
    .rent-pay-card input{margin-top:3px}
    .rent-modal-label{display:block;margin:14px 0 6px;font-weight:700;font-size:.9rem;color:#0f172a}
    .rent-modal-select{
      width:100%;padding:12px 12px;border-radius:10px;border:1px solid var(--line);font-size:.95rem;font-weight:600;
      background:#fff
    }
    .rent-modal-input{
      width:100%;padding:12px 12px;border-radius:10px;border:1px solid var(--line);font-size:.95rem;
      font-family:var(--font);background:#fff;margin-bottom:2px
    }
    .rent-modal-input:focus{outline:none;border-color:var(--accent-2);box-shadow:0 0 0 3px rgba(13,148,136,.12)}
    .rent-modal-back{
      padding:12px 18px;border-radius:10px;border:1px solid var(--line);background:#fff;
      font-weight:700;font-size:.92rem;cursor:pointer;color:#334155;font-family:var(--font)
    }
    .rent-modal-back:hover{background:#f1f5f9}
    .rent-modal-primary{margin-top:14px}
  </style>
</head>
<body>
  <div class="topbar">
    <div class="wrap">
      ${topPhone}
      ${payload.showPaymentLoginButtonInHeader === false ? '' : `<a class="btn-pay" href="${escapeHtml(paymentHref)}">${escapeHtml(payload.secondaryCtaLabel)}</a>`}
    </div>
  </div>
  <header class="site-header">
    <div class="wrap header-row">
      <div class="brand-lockup">
        ${logoBlock}
        <div class="brand-text">
          <p class="name">${escapeHtml(payload.facilityName)}</p>
          ${taglineHtml}
        </div>
      </div>
      <nav aria-label="Primary">
        <a href="#home">Home</a>
        <a href="#about">About</a>
        <a href="#units">Units</a>
        <a href="#map">Map</a>
        <a href="#contact">Contact</a>
      </nav>
    </div>
  </header>
  ${browseStripHtml}

  <div class="hero-shell" id="home">
    <section class="hero">
      <div class="wrap">
        <p class="eyebrow">Reserve online</p>
        <h1>${escapeHtml(payload.heroHeadline)}</h1>
        <p class="sub">${escapeHtml(payload.heroSubheadline)}</p>
        <div class="cta">
          <a class="btn btn-primary" href="${escapeHtml(unitsHref)}">${escapeHtml(payload.primaryCtaLabel)}</a>
          <a class="btn btn-ghost" href="#unit-list">Rent online</a>
        </div>
      </div>
    </section>
  </div>

  <main>
    ${categoryIntroSection}
    ${howItWorksSection}
    <section class="section" id="about">
      <div class="wrap">
        <div class="section-head">
          <h2 class="section-title">Your self storage partner</h2>
        </div>
        <div class="banner">
          <strong>${escapeHtml(payload.facilityName)}</strong>
          <p class="muted" style="margin:0;font-size:1.02rem">${escapeHtml(payload.marketingContent)}</p>
          <div class="chip-wrap">${amenityChips}</div>
        </div>
      </div>
    </section>
    ${aboutSection}

    <section class="section alt" id="units">
      <div class="wrap">
        <div class="section-head">
          <h2 class="section-title">Our pricing guide</h2>
          <a class="text-link" href="${escapeHtml(unitsHref)}">View all units</a>
        </div>
        <div class="pricing-grid">
          <article class="price-card">
            <h3>Starting at</h3>
            <p class="price-big">${escapeHtml(startingLabel)}</p>
            <p>Live pricing from your published inventory. Sizes and rates update as your availability changes.</p>
            <a class="btn btn-primary" style="border-radius:12px" href="${escapeHtml(unitsHref)}">${escapeHtml(payload.primaryCtaLabel)}</a>
          </article>
          <article class="price-card">
            <h3>Available now</h3>
            <p class="price-big">${payload.availableCount}</p>
            <p>Units currently marked available on your public map snapshot.</p>
            <a class="btn btn-light" style="border-radius:12px" href="#unit-list">Start a rental</a>
          </article>
        </div>
      </div>
    </section>
    ${categoryGridSection}

    <section class="section" id="unit-list">
      <div class="wrap">
        <div class="section-head">
          <h2 class="section-title">Available storage units</h2>
        </div>
        ${unitRowsHtml}
      </div>
    </section>

    ${amenitiesSection}

    <section class="section">
      <div class="wrap">
        <h2 class="section-title" style="margin-bottom:18px">Our promise to you</h2>
        <div class="promise-grid">
          <article class="promise-card">
            <div class="card-icon-badge">${cardIcon(promiseSecurityIcon, 'shield-check', 'Security')}</div>
            <h3>Security</h3>
            <p>${promiseS}</p>
          </article>
          <article class="promise-card">
            <div class="card-icon-badge">${cardIcon(promiseServiceIcon, 'headset', 'Customer service')}</div>
            <h3>Customer service</h3>
            <p>${promiseSv}</p>
          </article>
          <article class="promise-card">
            <div class="card-icon-badge">${cardIcon(promiseConvenienceIcon, 'clock', 'Convenience')}</div>
            <h3>Convenience</h3>
            <p>${promiseC}</p>
          </article>
        </div>
      </div>
    </section>

    <section class="section alt">
      <div class="wrap">
        <h2 class="section-title" style="margin-bottom:16px">Testimonials</h2>
        <div class="quotes">${testimonialsHtml}</div>
      </div>
    </section>

    ${promoSection}
    ${partnershipSection}
    ${faqSection}

    <section class="section" id="contact">
      <div class="wrap">
        <div class="section-head">
          <h2 class="section-title">Contact us</h2>
        </div>
        <div class="contact-grid" id="map">
          <div class="contact-card">
            <h3>${escapeHtml(payload.facilityName)}</h3>
            <p class="contact-line">${escapeHtml(addressDisplay)}</p>
            <p class="contact-line"><strong>Phone</strong><br />${
              phoneTelHref
                ? `<a href="${phoneTelHref}">${escapeHtml(phoneDisplay)}</a>`
                : escapeHtml(phoneDisplay)
            }</p>
            ${emailRow}
            <h4 style="margin:18px 0 8px;font-size:1rem">Office hours</h4>
            <ul class="hours-list">${officeHoursHtml || '<li>Contact us for current hours</li>'}</ul>
          </div>
          ${mapBlock}
        </div>
      </div>
    </section>
  </main>

  <footer class="site-footer">
    <div class="wrap footer-row">
      <div>
        <div class="footer-brand">${escapeHtml(footerLegalText)}</div>
        ${footerTagline ? `<div class="fine">${escapeHtml(footerTagline)}</div>` : ''}
        <div class="fine">Storage Facility Creator — public website template v3</div>
      </div>
      <div class="fine" style="display:flex;gap:16px;align-items:center;flex-wrap:wrap">
        ${socialLinksHtml}
        ${reviewFooter}
      </div>
    </div>
  </footer>
  <div id="rent-modal" class="rent-modal" aria-hidden="true">
    <div class="rent-modal-backdrop" data-modal-close="1"></div>
    <div class="rent-modal-panel" role="dialog" aria-modal="true" aria-labelledby="rent-modal-title">
      <button type="button" class="rent-modal-close" data-modal-close="1" aria-label="Close">&times;</button>
      <h2 id="rent-modal-title" class="rent-modal-title"></h2>
      <div class="rent-modal-desc" id="rent-modal-desc"></div>
      <!-- Step 1: unit + payment -->
      <div id="rent-step-1">
        <div class="rent-modal-pay">
          <h3>Payment options</h3>
          <label class="rent-pay-card">
            <input type="radio" name="rentpayopt" checked disabled />
            <span id="rent-modal-cycle"></span>
          </label>
        </div>
        <label class="rent-modal-label" for="rent-modal-select">Select unit</label>
        <select id="rent-modal-select" class="rent-modal-select"></select>
        <button type="button" class="legend-rent-btn rent-modal-primary" id="rent-modal-continue">Continue</button>
      </div>
      <!-- Step 2: reservation form -->
      <div id="rent-step-2" style="display:none">
        <p class="rent-step2-sub" style="margin:0 0 14px;color:#64748b;font-size:.92rem">Enter your details to reserve this unit.</p>
        <label class="rent-modal-label" for="rent-email">Email *</label>
        <input id="rent-email" type="email" class="rent-modal-input" placeholder="you@email.com" required />
        <label class="rent-modal-label" for="rent-name">Full Name</label>
        <input id="rent-name" type="text" class="rent-modal-input" placeholder="Full Name" />
        <label class="rent-modal-label" for="rent-phone">Phone</label>
        <input id="rent-phone" type="tel" class="rent-modal-input" placeholder="(555) 123-4567" />
        <label class="rent-modal-label" for="rent-date">Preferred Move-In Date</label>
        <input id="rent-date" type="date" class="rent-modal-input" />
        <!--
          SMS opt-in. Unchecked by default and never pre-checked: A2P 10DLC
          review requires express consent, and the campaign's message flow
          tells carriers this exact checkbox appears on this form. If it is not
          here, that claim is false and the campaign is rejected for an
          unverifiable CTA.
        -->
        <label class="rent-consent" for="rent-sms-consent" style="display:flex;gap:8px;align-items:flex-start;margin:14px 0 0;font-size:.82rem;line-height:1.45;color:#475569">
          <input id="rent-sms-consent" type="checkbox" style="margin-top:3px;flex:0 0 auto" />
          <span>I consent to receive SMS notifications regarding my storage account. Message frequency varies. Message &amp; data rates may apply. Reply STOP to opt out, HELP for help. Consent is not a condition of renting a unit.</span>
        </label>
        <div id="rent-form-error" style="display:none;color:#b91c1c;font-size:.88rem;margin:8px 0 0"></div>
        <div style="display:flex;gap:10px;margin-top:14px">
          <button type="button" class="rent-modal-back" id="rent-back">Back</button>
          <button type="button" class="legend-rent-btn rent-modal-primary" id="rent-submit" style="flex:1">Reserve Now</button>
        </div>
      </div>
    </div>
  </div>
  <script>
    (function () {
      function scrollToId(hash) {
        if (!hash || hash === '#' || hash.length < 2) return;
        var id = decodeURIComponent(hash.slice(1));
        var el = document.getElementById(id);
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
      document.addEventListener(
        'click',
        function (e) {
          var t = e.target;
          if (!t || !t.closest) return;
          var a = t.closest('a[href^="#"]');
          if (!a) return;
          var href = a.getAttribute('href');
          if (!href || href === '#' || href.length < 2) return;
          e.preventDefault();
          if (location.hash !== href) {
            history.pushState(null, '', href);
          }
          scrollToId(href);
        },
        false
      );
      function onHash() {
        scrollToId(location.hash || '');
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', onHash);
      } else {
        onHash();
      }
      window.addEventListener('hashchange', onHash);
      window.addEventListener('popstate', onHash);

      var rentModal = document.getElementById('rent-modal');
      if (rentModal) {
        var rentBaseHold = '';
        var step1 = document.getElementById('rent-step-1');
        var step2 = document.getElementById('rent-step-2');
        function showStep(n) {
          if (step1) step1.style.display = n === 1 ? '' : 'none';
          if (step2) step2.style.display = n === 2 ? '' : 'none';
        }
        function closeModal() {
          rentModal.classList.remove('open');
          rentModal.setAttribute('aria-hidden', 'true');
          showStep(1);
        }
        rentModal.querySelectorAll('[data-modal-close]').forEach(function (el) {
          el.addEventListener('click', closeModal);
        });
        document.addEventListener('click', function (e) {
          var btn = e.target && e.target.closest && e.target.closest('[data-modal-open]');
          if (!btn) return;
          e.preventDefault();
          rentBaseHold = btn.getAttribute('data-rent-base') || '';
          var title = btn.getAttribute('data-title') || '';
          var cycle = btn.getAttribute('data-cycle') || '';
          var bulletsEnc = btn.getAttribute('data-bullets-json') || '%5B%5D';
          var optsEnc = btn.getAttribute('data-options') || '%5B%5D';
          var bullets, opts;
          try { bullets = JSON.parse(decodeURIComponent(bulletsEnc)); } catch (e) { bullets = []; }
          try { opts = JSON.parse(decodeURIComponent(optsEnc)); } catch (e) { opts = []; }
          var h = document.getElementById('rent-modal-title');
          if (h) h.textContent = title;
          var cyc = document.getElementById('rent-modal-cycle');
          if (cyc) cyc.textContent = cycle;
          var desc = document.getElementById('rent-modal-desc');
          if (desc) {
            desc.innerHTML = '<ul>' + bullets.map(function (b) {
              return '<li>' + String(b).replace(/</g, '&lt;') + '</li>';
            }).join('') + '</ul>';
          }
          var sel = document.getElementById('rent-modal-select');
          if (sel) {
            sel.innerHTML = '';
            var oAuto = document.createElement('option');
            oAuto.value = '__AUTO__';
            oAuto.textContent = 'Automatically select';
            sel.appendChild(oAuto);
            opts.forEach(function (o) {
              var op = document.createElement('option');
              op.value = o.href;
              op.textContent = o.label;
              sel.appendChild(op);
            });
          }
          showStep(1);
          rentModal.classList.add('open');
          rentModal.setAttribute('aria-hidden', 'false');
        });
        var cont = document.getElementById('rent-modal-continue');
        if (cont) {
          cont.addEventListener('click', function () { showStep(2); });
        }
        var back = document.getElementById('rent-back');
        if (back) {
          back.addEventListener('click', function () { showStep(1); });
        }
        var submit = document.getElementById('rent-submit');
        if (submit) {
          submit.addEventListener('click', function () {
            var email = (document.getElementById('rent-email') || {}).value || '';
            var name = (document.getElementById('rent-name') || {}).value || '';
            var phone = (document.getElementById('rent-phone') || {}).value || '';
            var date = (document.getElementById('rent-date') || {}).value || '';
            var errEl = document.getElementById('rent-form-error');
            if (!email.trim() || email.indexOf('@') === -1) {
              if (errEl) { errEl.textContent = 'Please enter a valid email address.'; errEl.style.display = ''; }
              return;
            }
            if (errEl) errEl.style.display = 'none';
            var sel = document.getElementById('rent-modal-select');
            var val = sel ? sel.value : '__AUTO__';
            var href = val === '__AUTO__' ? rentBaseHold : val;
            if (!href) return;
            var sep = href.indexOf('?') !== -1 ? '&' : '?';
            href += sep + 'autoSubmit=1&email=' + encodeURIComponent(email.trim());
            if (name.trim()) href += '&name=' + encodeURIComponent(name.trim());
            if (phone.trim()) href += '&phone=' + encodeURIComponent(phone.trim());
            if (date) href += '&moveInDate=' + encodeURIComponent(date);
            var consentEl = document.getElementById('rent-sms-consent');
            href += '&smsConsent=' + (consentEl && consentEl.checked ? 'true' : 'false');
            closeModal();
            window.location.href = href;
          });
        }
      }
    })();
  </script>
  <script src="https://unpkg.com/lucide@latest"></script>
  <script>
    if (window.lucide && typeof window.lucide.createIcons === 'function') {
      window.lucide.createIcons();
    }
  </script>
</body>
</html>`;
}

function timestampMillis(value: unknown): number | null {
  if (!value || typeof value !== 'object') return null;
  const timestamp = value as {
    toMillis?: () => number;
    seconds?: number;
    _seconds?: number;
  };
  if (typeof timestamp.toMillis === 'function') return timestamp.toMillis();
  const seconds = timestamp.seconds ?? timestamp._seconds;
  return typeof seconds === 'number' ? seconds * 1000 : null;
}

export function hasActiveWebsiteSubscription(
  data: Record<string, unknown>,
  nowMs = Date.now(),
): boolean {
  const status = String(data.websiteSubscriptionStatus || '').toLowerCase();
  const subscriptionId = String(data.stripeWebsiteSubscriptionId || '').trim();
  const stripeEntitled = subscriptionId.startsWith('sub_') &&
    (status === 'active' || status === 'trialing');
  const adminTrialEndsAtMs = timestampMillis(data.websiteAdminTrialEndsAt);
  return stripeEntitled ||
    (adminTrialEndsAtMs !== null && adminTrialEndsAtMs > nowMs);
}

async function facilityWebsiteIsEntitled(facilityId: string): Promise<boolean> {
  if (!facilityId) return false;
  const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  return facilitySnap.exists &&
    hasActiveWebsiteSubscription((facilitySnap.data() || {}) as Record<string, unknown>);
}

export async function resolveSlug(slug?: string, domain?: string, hostHeader?: string): Promise<string | null> {
  const directSlug = (slug || '').trim().toLowerCase();
  if (directSlug) return directSlug;
  const candidateDomain = normalizeDomain(domain || hostHeader || '');
  if (!candidateDomain) return null;

  const db = admin.firestore();
  const settings = await db
    .collectionGroup('settings')
    .where('customDomain', '==', candidateDomain)
    .limit(10)
    .get();
  if (settings.empty) return null;
  const enabledMatches = settings.docs.filter((doc) => {
    const data = doc.data() as Record<string, unknown>;
    return data.enabled === true;
  });
  if (enabledMatches.length === 0) return null;
  // `customDomain` is a free-text field any facility owner/manager can set on their own
  // settings doc (see firestore-rules-src/facilities/06-settings.rules) — nothing enforces
  // it's unique across facilities. If more than one *different* facility has claimed the
  // same hostname, we cannot safely guess which one should be served: silently picking one
  // (e.g. the first Firestore returns) would let a facility that merely typed in someone
  // else's live domain hijack that domain's visitors. Fail closed instead.
  const distinctFacilityIds = new Set(
    enabledMatches.map((doc) => doc.ref.parent.parent?.id).filter((id): id is string => !!id),
  );
  if (distinctFacilityIds.size > 1) {
    functions.logger.error('resolveSlug: custom domain is claimed by multiple facilities', {
      candidateDomain,
      facilityIds: [...distinctFacilityIds],
    });
    return null;
  }
  const facilityId = enabledMatches[0].ref.parent.parent?.id;
  if (!facilityId || !(await facilityWebsiteIsEntitled(facilityId))) return null;

  const meta = await db.doc(`facilities/${facilityId}/mapEngine/meta`).get();
  const mapSlug = String(meta.data()?.publicSlug || '').trim().toLowerCase();
  return mapSlug || null;
}

function extractWebsiteRouteFromPath(pathValue: string): { slug: string; categorySlug: string | null } {
  const cleaned = String(pathValue || '').split('?')[0].trim();
  if (!cleaned) return { slug: '', categorySlug: null };
  const segments = cleaned
    .split('/')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (segments.length === 0) return { slug: '', categorySlug: null };
  const wIndex = segments.indexOf('w');
  if (wIndex >= 0 && segments.length > wIndex + 1) {
    const slug = segments[wIndex + 1].toLowerCase();
    if (segments.length > wIndex + 3 && segments[wIndex + 2] === 'c') {
      return { slug, categorySlug: segments[wIndex + 3].toLowerCase() };
    }
    return { slug, categorySlug: null };
  }
  return { slug: segments[segments.length - 1].toLowerCase(), categorySlug: null };
}

// minInstances: 1 keeps a warm instance so the index.html root-redirect lookup (see
// web/index.html) never eats a cold start on top of its own 2.5s safety-net timeout —
// a cold instance here previously meant real customers occasionally landed on the raw
// operator app instead of the facility's site. Same reasoning for renderPublicWebsite
// and routeCustomDomainRoot below.
export const getPublicWebsiteConfig = functions.runWith({ minInstances: 1 }).https.onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }
  if (req.method !== 'GET') {
    res.status(405).json({ error: 'Method not allowed.' });
    return;
  }
  try {
    const slug = await resolveSlug(String(req.query.slug || ''), String(req.query.domain || ''), String(req.headers.host || ''));
    if (!slug) {
      res.status(404).json({ error: 'Website not found.' });
      return;
    }
    const snap = await admin.firestore().collection('publicFacilityMaps').doc(slug).get();
    if (!snap.exists) {
      res.status(404).json({ error: 'Website not found.' });
      return;
    }
    const data = snap.data() || {};
    const facilityName = String(data.facilityName || 'Storage Facility');
    const publicSettings = (data.publicSettings || {}) as Record<string, unknown>;
    const facilityId = String(data.facilityId || '');
    if (publicSettings.enabled !== true || !(await facilityWebsiteIsEntitled(facilityId))) {
      res.status(404).json({ error: 'Website not found.' });
      return;
    }
    const units = Array.isArray(data.units) ? (data.units as Record<string, unknown>[]) : [];
    // isRentable already folds in status, tenant links, unit-type visibility, and the
    // per-unit publicListingEnabled flag — do not re-derive availability from raw status
    // here, or staff-only units (manager residence, office, personal-use, etc.) that are
    // internally `available` (to avoid billing implications) leak into the public storefront.
    const available = units.filter((u) => u.isRentable === true);
    const startingAt = available.reduce<number | null>((acc, u) => {
      const rate = asNumber(u.monthlyRate);
      if (rate == null) return acc;
      if (acc == null) return rate;
      return Math.min(acc, rate);
    }, null);
    const categories = new Map<string, { count: number; startingAt: number | null }>();
    for (const unit of available) {
      const key = String(unit.categorySlug || unit.unitType || 'storage-units').trim().toLowerCase();
      const rate = asNumber(unit.monthlyRate);
      const prev = categories.get(key);
      if (!prev) {
        categories.set(key, { count: 1, startingAt: rate });
        continue;
      }
      const next =
        prev.startingAt == null ? rate : rate == null ? prev.startingAt : Math.min(prev.startingAt, rate);
      categories.set(key, { count: prev.count + 1, startingAt: next });
    }

    res.json({
      facilityId,
      facilitySlug: slug,
      facilityName,
      pageTitle: String(publicSettings.pageTitle || `${facilityName} | Storage`),
      pageDescription: String(publicSettings.pageDescription || data.facilityDescription || ''),
      marketingContent: String(publicSettings.marketingContent || data.facilityDescription || ''),
      facilityPhone: String(data.facilityPhone || ''),
      facilityLogoUrl: typeof data.facilityLogoUrl === 'string' ? data.facilityLogoUrl : null,
      customDomain: typeof publicSettings.customDomain === 'string' ? publicSettings.customDomain : null,
      availableCount: available.length,
      startingAt,
      categories: [...categories.entries()].map(([name, value]) => ({
        name,
        count: value.count,
        startingAt: value.startingAt,
      })),
      websiteConfig:
        (publicSettings.websiteConfig as Record<string, unknown> | undefined) ??
        ((publicSettings.widgets as Record<string, unknown> | undefined)?.websiteConfig as Record<string, unknown> | undefined) ??
        {},
      rentUrl: `https://app.storagefacilitycreator.com/w/${slug}#units`,
      availableUnitsUrl: `https://app.storagefacilitycreator.com/w/${slug}#units`,
      generatedAt: new Date().toISOString(),
    });
  } catch (err) {
    functions.logger.error('getPublicWebsiteConfig failed', { error: (err as Error)?.message || String(err) });
    res.status(500).json({ error: 'Internal error.' });
  }
});

export const renderPublicWebsite = functions.runWith({ minInstances: 1 }).https.onRequest(async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).type('text/plain').send('Method not allowed.');
    return;
  }
  try {
  const routeFromPath = extractWebsiteRouteFromPath(req.path || req.originalUrl || '');
  const slugFromPath = routeFromPath.slug;
  const categoryFromPath = routeFromPath.categorySlug;
  const slug = await resolveSlug(
    String(req.query.slug || slugFromPath || ''),
    String(req.query.domain || ''),
    String(req.headers.host || ''),
  );
  if (!slug) {
    res.status(404).type('text/html').send(toHtml({
      title: 'Website not found',
      description: 'No published facility website exists for this link.',
      marketingContent: 'No published facility website exists for this link.',
      heroHeadline: 'Website not found',
      heroSubheadline: 'No published facility website exists for this link.',
      primaryCtaLabel: 'See Units',
      secondaryCtaLabel: 'Rent Online',
      paymentUrl: '#',
      tenantPortalUrl: '#',
      address: '',
      officeHours: '',
      amenities: [],
      testimonials: [],
      facilityName: 'Storage Facility',
      facilityPhone: '',
      facilityLogoUrl: null,
      heroImageUrl: null,
      tagline: '',
      contactEmail: '',
      mapEmbedUrl: null,
      promoTitle: '',
      promoBody: '',
      promoCtaLabel: '',
      promoCtaUrl: '',
      promiseSecurity: '',
      promiseService: '',
      promiseConvenience: '',
      reviewUrl: '',
      startingAt: null,
      availableCount: 0,
      facilitySlug: '',
      rentUrl: '#',
      unitsUrl: '#',
      categories: [],
      unitRows: [],
    }));
    return;
  }
  const snap = await admin.firestore().collection('publicFacilityMaps').doc(slug).get();
  if (!snap.exists) {
    res.status(404).type('text/html').send(toHtml({
      title: 'Website not found',
      description: 'No published facility website exists for this link.',
      marketingContent: 'No published facility website exists for this link.',
      heroHeadline: 'Website not found',
      heroSubheadline: 'No published facility website exists for this link.',
      primaryCtaLabel: 'See Units',
      secondaryCtaLabel: 'Rent Online',
      paymentUrl: '#',
      tenantPortalUrl: '#',
      address: '',
      officeHours: '',
      amenities: [],
      testimonials: [],
      facilityName: 'Storage Facility',
      facilityPhone: '',
      facilityLogoUrl: null,
      heroImageUrl: null,
      tagline: '',
      contactEmail: '',
      mapEmbedUrl: null,
      promoTitle: '',
      promoBody: '',
      promoCtaLabel: '',
      promoCtaUrl: '',
      promiseSecurity: '',
      promiseService: '',
      promiseConvenience: '',
      reviewUrl: '',
      startingAt: null,
      availableCount: 0,
      facilitySlug: '',
      rentUrl: '#',
      unitsUrl: '#',
      categories: [],
      unitRows: [],
    }));
    return;
  }
  const data = snap.data() || {};
  const publicSettings = (data.publicSettings || {}) as Record<string, unknown>;
  const facilityId = String(data.facilityId || '');
  if (publicSettings.enabled !== true || !(await facilityWebsiteIsEntitled(facilityId))) {
    res.status(404).type('text/plain').send('Website not found.');
    return;
  }
  const widgetsBlock = (publicSettings.widgets || {}) as Record<string, unknown>;
  const websiteConfig = (
    (publicSettings.websiteConfig || widgetsBlock.websiteConfig || {}) as Record<string, unknown>
  );
  const amenities = String(websiteConfig.amenities || '')
    .split(',')
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
  const testimonials = String(websiteConfig.testimonials || '')
    .split('\n')
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
  const units = Array.isArray(data.units) ? (data.units as Record<string, unknown>[]) : [];
  // isRentable already folds in status, tenant links, unit-type visibility, and the
  // per-unit publicListingEnabled flag — do not re-derive availability from raw status
  // here, or staff-only units (manager residence, office, personal-use, etc.) that are
  // internally `available` (to avoid billing implications) leak into the public storefront.
  const available = units.filter((u) => u.isRentable === true);
  const startingAt = available.reduce<number | null>((acc, u) => {
    const rate = asNumber(u.monthlyRate);
    if (rate == null) return acc;
    if (acc == null) return rate;
    return Math.min(acc, rate);
  }, null);
  const categories = new Map<string, { count: number; startingAt: number | null }>();
  for (const unit of available) {
    const key = String(unit.categorySlug || unit.unitType || 'storage-units').trim().toLowerCase();
    const rate = asNumber(unit.monthlyRate);
    const prev = categories.get(key);
    if (!prev) {
      categories.set(key, { count: 1, startingAt: rate });
      continue;
    }
    const next =
      prev.startingAt == null ? rate : rate == null ? prev.startingAt : Math.min(prev.startingAt, rate);
    categories.set(key, { count: prev.count + 1, startingAt: next });
  }
  const primaryRentCategory = String(
    available[0]?.categorySlug || available[0]?.unitType || '',
  ).trim().toLowerCase();
  const primaryRentUrl = withEmbedMode(
    primaryRentCategory
      ? `https://app.storagefacilitycreator.com/#/f/${encodeURIComponent(slug)}/${encodeURIComponent(primaryRentCategory)}`
      : `https://app.storagefacilitycreator.com/w/${slug}#categories`,
  );
  const unitRows = available.map((u) => {
    const categorySlug = String(u.categorySlug || u.unitType || '').trim().toLowerCase();
    const categoryLabel = (categorySlug || 'storage-units').replace(/-/g, ' ');
    const sizeText = String(u.size || '').trim();
    const width = asNumber(u.width);
    const length = asNumber(u.length);
    const sizeLabel =
      sizeText.length > 0
        ? sizeText
        : width != null && length != null
        ? `${width}x${length}`
        : '';
    const unitNumber = String(u.unitNumber || u.name || u.id || 'Available unit').trim();
    const unitId = String(u.unitId ?? u.id ?? '').trim();
    const rentHref = withEmbedMode(
      categorySlug
        ? `https://app.storagefacilitycreator.com/#/f/${encodeURIComponent(slug)}/${encodeURIComponent(categorySlug)}`
        : primaryRentUrl,
    );
    return {
      unitId,
      unitNumber,
      categorySlug,
      categoryLabel,
      monthlyRate: asNumber(u.monthlyRate),
      sizeLabel,
      rentHref,
    };
  });
  const facilityName = String(data.facilityName || 'Storage Facility');
  const facilityLogoUrl = typeof data.facilityLogoUrl === 'string' ? data.facilityLogoUrl : null;
  const description = String(publicSettings.marketingContent || data.facilityDescription || 'Browse available storage units and rent online.');
  const unitCategories = Array.isArray(websiteConfig.unitCategories)
    ? (websiteConfig.unitCategories as Record<string, unknown>[])
        .map((entry) => ({
          slug: String(entry.slug || '').trim().toLowerCase(),
          name: String(entry.name || '').trim(),
          shortBlurb: String(entry.shortBlurb || '').trim(),
          longDescription: String(entry.longDescription || '').trim(),
          heroImageUrl: String(entry.heroImageUrl || '').trim(),
          startingPrice: asNumber(entry.startingPrice),
          ctaLabel: String(entry.ctaLabel || '').trim(),
          displayOrder: asNumber(entry.displayOrder),
        }))
        .filter((entry) => entry.slug && entry.name)
    : [];
  const categoryPage =
    categoryFromPath != null
      ? unitCategories.find((item) => item.slug === categoryFromPath) || null
      : null;
  if (categoryFromPath && !categoryPage) {
    res.status(404).type('text/html').send('Category not found.');
    return;
  }
  const customDomain = typeof publicSettings.customDomain === 'string' ? publicSettings.customDomain.trim() : '';
  const pageUrl =
    (customDomain ? `https://${customDomain}` : `https://app.storagefacilitycreator.com/w/${slug}`) +
    (categoryPage ? `/${categoryPage.slug}` : '');
  res.status(200).type('text/html').send(
    toHtml({
      title: String(publicSettings.pageTitle || `${facilityName} | Self Storage`),
      description,
      marketingContent: description,
      heroHeadline: String(websiteConfig.heroHeadline || facilityName),
      heroSubheadline: String(
        websiteConfig.heroSubheadline || 'Secure, convenient, and reliable storage with online rentals.',
      ),
      primaryCtaLabel: String(websiteConfig.primaryCtaLabel || 'See Units'),
      secondaryCtaLabel: String(websiteConfig.secondaryCtaLabel || 'Make a Payment/Login'),
      paymentUrl: String(websiteConfig.paymentUrl || ''),
      tenantPortalUrl: 'https://app.storagefacilitycreator.com/#/tenant-portal',
      address: String(websiteConfig.address || ''),
      officeHours: String(websiteConfig.officeHours || ''),
      amenities,
      testimonials,
      facilityName,
      facilityPhone: String(data.facilityPhone || ''),
      facilityLogoUrl,
      heroImageUrl: typeof websiteConfig.heroImageUrl === 'string' ? websiteConfig.heroImageUrl : null,
      tagline: String(websiteConfig.tagline || ''),
      contactEmail: String(websiteConfig.contactEmail || ''),
      mapEmbedUrl: typeof websiteConfig.mapEmbedUrl === 'string' ? websiteConfig.mapEmbedUrl : null,
      promoTitle: String(websiteConfig.promoTitle || ''),
      promoBody: String(websiteConfig.promoBody || ''),
      promoCtaLabel: String(websiteConfig.promoCtaLabel || ''),
      promoCtaUrl: String(websiteConfig.promoCtaUrl || ''),
      promiseSecurity: String(websiteConfig.promiseSecurity || ''),
      promiseService: String(websiteConfig.promiseService || ''),
      promiseConvenience: String(websiteConfig.promiseConvenience || ''),
      reviewUrl: String(websiteConfig.reviewUrl || ''),
      logoImageUrl: typeof websiteConfig.logoImageUrl === 'string' ? websiteConfig.logoImageUrl : null,
      phoneNumber: String(websiteConfig.phoneNumber || ''),
      showPaymentLoginButtonInHeader: websiteConfig.showPaymentLoginButtonInHeader !== false,
      officeHoursStructured:
        websiteConfig.officeHoursStructured && typeof websiteConfig.officeHoursStructured === 'object'
          ? (websiteConfig.officeHoursStructured as Record<string, { open?: string; close?: string; closed?: boolean }>)
          : null,
      unitCategories,
      amenitiesStructured: Array.isArray(websiteConfig.amenitiesStructured)
        ? (websiteConfig.amenitiesStructured as Array<{ label: string; icon?: string }>)
        : [],
      testimonialsStructured: Array.isArray(websiteConfig.testimonialsStructured)
        ? (websiteConfig.testimonialsStructured as Array<{ quote: string; reviewer?: string; rating?: number; source?: string }>)
        : [],
      partnershipBand:
        websiteConfig.partnershipBand && typeof websiteConfig.partnershipBand === 'object'
          ? (websiteConfig.partnershipBand as { title?: string; body?: string; imageUrl?: string; ctaLabel?: string; ctaUrl?: string })
          : null,
      footerTagline: String(websiteConfig.footerTagline || ''),
      socialLinks:
        websiteConfig.socialLinks && typeof websiteConfig.socialLinks === 'object'
          ? (websiteConfig.socialLinks as { facebook?: string; instagram?: string; google?: string })
          : null,
      footerLegalText: String(websiteConfig.footerLegalText || ''),
      metaKeywords: String(websiteConfig.metaKeywords || ''),
      ogImageUrl: String(websiteConfig.ogImageUrl || ''),
      canonicalUrl: String(websiteConfig.canonicalUrl || ''),
      aboutSectionTitle: String(websiteConfig.aboutSectionTitle || ''),
      aboutSectionBody: String(websiteConfig.aboutSectionBody || ''),
      aboutSectionImageUrl: String(websiteConfig.aboutSectionImageUrl || ''),
      faqs: Array.isArray(websiteConfig.faqs)
        ? (websiteConfig.faqs as Array<{ question: string; answer: string }>)
        : [],
      pageUrl,
      stepChooseIconUrl: String(websiteConfig.stepChooseIconUrl || ''),
      stepDetailsIconUrl: String(websiteConfig.stepDetailsIconUrl || ''),
      stepReserveIconUrl: String(websiteConfig.stepReserveIconUrl || ''),
      promiseSecurityIconUrl: String(websiteConfig.promiseSecurityIconUrl || ''),
      promiseServiceIconUrl: String(websiteConfig.promiseServiceIconUrl || ''),
      promiseConvenienceIconUrl: String(websiteConfig.promiseConvenienceIconUrl || ''),
      categoryPage,
      startingAt,
      availableCount: available.length,
      facilitySlug: slug,
      rentUrl: primaryRentUrl,
      unitsUrl: `https://app.storagefacilitycreator.com/w/${slug}#unit-list`,
      categories: [...categories.entries()].map(([name, value]) => ({
        name,
        count: value.count,
        startingAt: value.startingAt,
      })),
      unitRows,
    }),
  );
  } catch (err) {
    functions.logger.error('renderPublicWebsite failed', { error: (err as Error)?.message || String(err) });
    res.status(500).type('text/html').send(
      '<!doctype html><meta charset="utf-8"><title>Temporarily unavailable</title><p>This site is temporarily unavailable. Please try again shortly.</p>',
    );
  }
});

function normalizeHostHeader(hostHeader: string): string {
  return String(hostHeader || '').trim().toLowerCase().split(':')[0];
}

function isPrimaryOperatorHost(hostHeader: string): boolean {
  const host = normalizeHostHeader(hostHeader);
  return (
    host === 'app.storagefacilitycreator.com' ||
    host === 'storage-facility-creator.web.app' ||
    host === 'storage-facility-creator.firebaseapp.com' ||
    host === 'localhost' ||
    host === '127.0.0.1'
  );
}

/**
 * For facility vanity hosts that share this same Hosting site, route `/` to the
 * matching marketing page instead of the Flutter operator SPA shell.
 */
export const routeCustomDomainRoot = functions.runWith({ minInstances: 1 }).https.onRequest(async (req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.status(405).type('text/plain').send('Method not allowed.');
    return;
  }

  try {
    const host = String(req.headers.host || '');
    if (isPrimaryOperatorHost(host)) {
      res.redirect(302, '/index.html');
      return;
    }

    const slug = await resolveSlug('', '', host);
    if (!slug) {
      res.redirect(302, '/index.html');
      return;
    }

    res.redirect(302, `/w/${encodeURIComponent(slug)}`);
  } catch (err) {
    functions.logger.error('routeCustomDomainRoot failed', { error: (err as Error)?.message || String(err) });
    res.redirect(302, '/index.html');
  }
});

/**
 * Real robots.txt for facility custom domains — previously this path fell through to the
 * generic Flutter shell (a static-file match always wins over a rewrite for the same path),
 * so every facility site effectively had no robots.txt at all. There's no way to pass a
 * `?domain=` query param here (crawlers request the bare path), so this relies on the
 * request's Host header, which Firebase Hosting forwards as-received for paths that don't
 * collide with a static file (unlike `/` and `/w/**`, no static robots.txt exists to compete).
 */
export const robotsTxt = functions.https.onRequest(async (req, res) => {
  res.set('Cache-Control', 'public, max-age=3600');
  const host = normalizeHostHeader(String(req.headers.host || ''));
  if (isPrimaryOperatorHost(host)) {
    // The operator dashboard is an authenticated SaaS app, not public content.
    res.status(200).type('text/plain').send('User-agent: *\nDisallow: /\n');
    return;
  }
  try {
    const slug = host ? await resolveSlug('', '', host) : null;
    if (!slug) {
      res.status(200).type('text/plain').send('User-agent: *\nAllow: /\n');
      return;
    }
    res.status(200).type('text/plain').send(
      `User-agent: *\nAllow: /\nSitemap: https://${host}/sitemap.xml\n`,
    );
  } catch (err) {
    functions.logger.error('robotsTxt failed', { error: (err as Error)?.message || String(err) });
    res.status(200).type('text/plain').send('User-agent: *\nAllow: /\n');
  }
});

/** Real sitemap.xml for facility custom domains — same Host-header approach as robotsTxt. */
export const sitemapXml = functions.https.onRequest(async (req, res) => {
  res.set('Cache-Control', 'public, max-age=3600');
  const host = normalizeHostHeader(String(req.headers.host || ''));
  const emptySitemap = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>';
  if (!host || isPrimaryOperatorHost(host)) {
    res.status(200).type('application/xml').send(emptySitemap);
    return;
  }
  try {
    const slug = await resolveSlug('', '', host);
    if (!slug) {
      res.status(200).type('application/xml').send(emptySitemap);
      return;
    }
    const snap = await admin.firestore().collection('publicFacilityMaps').doc(slug).get();
    if (!snap.exists) {
      res.status(200).type('application/xml').send(emptySitemap);
      return;
    }
    const data = snap.data() || {};
    const publicSettings = (data.publicSettings || {}) as Record<string, unknown>;
    if (publicSettings.enabled !== true) {
      res.status(200).type('application/xml').send(emptySitemap);
      return;
    }
    const widgetsBlock = (publicSettings.widgets || {}) as Record<string, unknown>;
    const websiteConfig = (publicSettings.websiteConfig || widgetsBlock.websiteConfig || {}) as Record<string, unknown>;
    const unitCategories = Array.isArray(websiteConfig.unitCategories)
      ? (websiteConfig.unitCategories as Record<string, unknown>[])
          .map((entry) => String(entry.slug || '').trim().toLowerCase())
          .filter((s) => s.length > 0)
      : [];
    const urls = [`https://${host}/`, ...unitCategories.map((s) => `https://${host}/${encodeURIComponent(s)}`)];
    const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls
      .map((u) => `  <url><loc>${escapeHtml(u)}</loc></url>`)
      .join('\n')}\n</urlset>`;
    res.status(200).type('application/xml').send(body);
  } catch (err) {
    functions.logger.error('sitemapXml failed', { error: (err as Error)?.message || String(err) });
    res.status(200).type('application/xml').send(emptySitemap);
  }
});
