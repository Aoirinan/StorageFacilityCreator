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

/** Google Maps embed iframe src only. */
function safeGoogleMapsEmbedUrl(raw: string): string | null {
  const t = raw.trim();
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

function toHtml(payload: {
  title: string;
  description: string;
  marketingContent: string;
  heroHeadline: string;
  heroSubheadline: string;
  primaryCtaLabel: string;
  secondaryCtaLabel: string;
  paymentUrl: string;
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
  rentUrl: string;
  unitsUrl: string;
  categories: Array<{ name: string; count: number; startingAt: number | null }>;
}): string {
  const paymentHref =
    safeHttpUrl(payload.paymentUrl) || safeHttpUrl(payload.rentUrl) || safeHttpUrl(payload.unitsUrl) || '#';
  const rentHref = safeHttpUrl(payload.rentUrl) || '#';
  const unitsHref = safeHttpUrl(payload.unitsUrl) || '#';
  const promoCtaHref = safeHttpUrl(payload.promoCtaUrl);
  const reviewHref = safeHttpUrl(payload.reviewUrl);

  const logoSrc = safeHttpsImageUrl(payload.facilityLogoUrl || '');
  const heroBg = safeHttpsImageUrl(payload.heroImageUrl || '');

  const cards = payload.categories.length
    ? payload.categories
        .slice(0, 6)
        .map((c) => {
          const label = escapeHtml(c.name.replace(/-/g, ' '));
          const price = c.startingAt == null ? 'Call for rates' : `$${c.startingAt.toFixed(2)}`;
          return `<article class="cat-card"><h3>${label}</h3><p class="cat-meta">${c.count} available · from <strong>${price}</strong>/mo</p><a class="text-link" href="${escapeHtml(unitsHref)}">See units</a></article>`;
        })
        .join('')
    : `<article class="cat-card"><h3>Storage units</h3><p class="cat-meta">Availability updates in real time.</p><a class="text-link" href="${escapeHtml(unitsHref)}">See units</a></article>`;

  const amenityList = payload.amenities.length
    ? payload.amenities.slice(0, 14)
    : ['Online rentals', 'Online bill pay', 'Secure access', 'Variety of unit sizes'];
  const amenityChips = amenityList.map((a) => `<span class="chip">${escapeHtml(a)}</span>`).join('');

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

  const testimonialsHtml = (payload.testimonials.length
    ? payload.testimonials.slice(0, 4)
    : ['Great facility and easy online rentals.']
  )
    .map((raw) => {
      const { quote, author } = parseTestimonialLine(raw);
      const q = escapeHtml(quote);
      const a = author ? `<footer class="quote-author">— ${escapeHtml(author)}</footer>` : '';
      return `<article class="quote-card"><p class="quote-text">“${q}”</p><div class="stars" aria-hidden="true">★★★★★</div>${a}</article>`;
    })
    .join('');

  const addressDisplay =
    payload.address.trim().length > 0 ? payload.address : 'Contact us for facility address details.';
  const officeHoursHtml = payload.officeHours
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => `<li>${escapeHtml(line)}</li>`)
    .join('');

  const phoneDisplay = (payload.facilityPhone || '').trim() || 'Call for details';
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

  const startingLabel = payload.startingAt == null ? 'Call for rates' : `$${payload.startingAt.toFixed(2)}`;
  const heroStyle = heroBg
    ? `--hero-image:url(${escapeHtml(heroBg)});`
    : `--hero-image:linear-gradient(135deg,#0f7669 0%,#134e4a 55%,#0f172a 100%);`;

  const logoBlock = logoSrc
    ? `<img class="brand-logo" src="${escapeHtml(logoSrc)}" alt="" width="48" height="48" />`
    : `<div class="brand-mark" aria-hidden="true">${escapeHtml(payload.facilityName.trim().charAt(0) || 'S')}</div>`;

  const topPhone =
    phoneTelHref.length > 0
      ? `<a class="top-link" href="${phoneTelHref}">${escapeHtml(phoneDisplay)}</a>`
      : `<span class="top-muted">${escapeHtml(phoneDisplay)}</span>`;

  const reviewFooter =
    reviewHref.length > 0
      ? `<a class="footer-link" href="${escapeHtml(reviewHref)}" rel="noopener noreferrer">Leave us a review</a>`
      : '';

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(payload.title)}</title>
  <meta name="description" content="${escapeHtml(payload.description)}" />
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
  </style>
</head>
<body>
  <div class="topbar">
    <div class="wrap">
      ${topPhone}
      <a class="btn-pay" href="${escapeHtml(paymentHref)}">${escapeHtml(payload.secondaryCtaLabel)}</a>
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

  <div class="hero-shell" id="home">
    <section class="hero">
      <div class="wrap">
        <p class="eyebrow">Reserve online</p>
        <h1>${escapeHtml(payload.heroHeadline)}</h1>
        <p class="sub">${escapeHtml(payload.heroSubheadline)}</p>
        <div class="cta">
          <a class="btn btn-primary" href="${escapeHtml(unitsHref)}">${escapeHtml(payload.primaryCtaLabel)}</a>
          <a class="btn btn-ghost" href="${escapeHtml(rentHref)}">Rent online</a>
        </div>
      </div>
    </section>
  </div>

  <main>
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
            <a class="btn btn-light" style="border-radius:12px" href="${escapeHtml(rentHref)}">Start a rental</a>
          </article>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="wrap">
        <div class="section-head">
          <h2 class="section-title">Available categories</h2>
        </div>
        <div class="cat-grid">${cards}</div>
      </div>
    </section>

    <section class="section alt">
      <div class="wrap">
        <h2 class="section-title" style="margin-bottom:16px">All the convenience and security you need</h2>
        <div class="feature-grid">${featureCells}</div>
      </div>
    </section>

    <section class="section">
      <div class="wrap">
        <h2 class="section-title" style="margin-bottom:18px">Our promise to you</h2>
        <div class="promise-grid">
          <article class="promise-card">
            <h3>Security</h3>
            <p>${promiseS}</p>
          </article>
          <article class="promise-card">
            <h3>Customer service</h3>
            <p>${promiseSv}</p>
          </article>
          <article class="promise-card">
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
        <div class="footer-brand">Powered by Storage Facility Creator</div>
        <div class="fine">Cookie-cutter facility website template v2</div>
      </div>
      <div class="fine" style="display:flex;gap:16px;align-items:center;flex-wrap:wrap">
        ${reviewFooter}
      </div>
    </div>
  </footer>
</body>
</html>`;
}

async function resolveSlug(slug?: string, domain?: string, hostHeader?: string): Promise<string | null> {
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
  const matching = settings.docs.find((doc) => {
    const data = doc.data() as Record<string, unknown>;
    return data.enabled !== false;
  });
  if (!matching) return null;
  const facilityId = matching.ref.parent.parent?.id;
  if (!facilityId) return null;

  const meta = await db.doc(`facilities/${facilityId}/mapEngine/meta`).get();
  const mapSlug = String(meta.data()?.publicSlug || '').trim().toLowerCase();
  return mapSlug || null;
}

function extractSlugFromPath(pathValue: string): string {
  const cleaned = String(pathValue || '').split('?')[0].trim();
  if (!cleaned) return '';
  const segments = cleaned
    .split('/')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (segments.length === 0) return '';
  const wIndex = segments.indexOf('w');
  if (wIndex >= 0 && segments.length > wIndex + 1) {
    return segments[wIndex + 1].toLowerCase();
  }
  return segments[segments.length - 1].toLowerCase();
}

export const getPublicWebsiteConfig = functions.https.onRequest(async (req, res) => {
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
  const units = Array.isArray(data.units) ? (data.units as Record<string, unknown>[]) : [];
  const available = units.filter((u) => String(u.status || '').toLowerCase() === 'available');
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
    facilityId: String(data.facilityId || ''),
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
      ((publicSettings.widgets as Record<string, unknown> | undefined)?.websiteConfig as Record<string, unknown> | undefined) ??
      {},
    rentUrl: `https://app.storagefacilitycreator.com/#/f/${slug}/rent`,
    availableUnitsUrl: `https://app.storagefacilitycreator.com/#/f/${slug}/available-units`,
    generatedAt: new Date().toISOString(),
  });
});

export const renderPublicWebsite = functions.https.onRequest(async (req, res) => {
  if (req.method !== 'GET') {
    res.status(405).type('text/plain').send('Method not allowed.');
    return;
  }
  const slugFromPath = extractSlugFromPath(req.path || req.originalUrl || '');
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
      rentUrl: '#',
      unitsUrl: '#',
      categories: [],
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
      rentUrl: '#',
      unitsUrl: '#',
      categories: [],
    }));
    return;
  }
  const data = snap.data() || {};
  const publicSettings = (data.publicSettings || {}) as Record<string, unknown>;
  const widgets = (publicSettings.widgets || {}) as Record<string, unknown>;
  const websiteConfig = (widgets.websiteConfig || {}) as Record<string, unknown>;
  const amenities = String(websiteConfig.amenities || '')
    .split(',')
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
  const testimonials = String(websiteConfig.testimonials || '')
    .split('\n')
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
  const units = Array.isArray(data.units) ? (data.units as Record<string, unknown>[]) : [];
  const available = units.filter((u) => String(u.status || '').toLowerCase() === 'available');
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
  const facilityName = String(data.facilityName || 'Storage Facility');
  const facilityLogoUrl = typeof data.facilityLogoUrl === 'string' ? data.facilityLogoUrl : null;
  const description = String(publicSettings.marketingContent || data.facilityDescription || 'Browse available storage units and rent online.');
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
      startingAt,
      availableCount: available.length,
      rentUrl: `https://app.storagefacilitycreator.com/#/f/${slug}/rent`,
      unitsUrl: `https://app.storagefacilitycreator.com/#/f/${slug}/available-units`,
      categories: [...categories.entries()].map(([name, value]) => ({
        name,
        count: value.count,
        startingAt: value.startingAt,
      })),
    }),
  );
});
