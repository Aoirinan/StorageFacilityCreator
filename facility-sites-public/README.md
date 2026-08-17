# facility-sites-public

Deploy root for the **facility websites** Hosting site (`sfc-facility-sites`),
which serves every operator's public site on their own custom domain.

## Why this directory exists, and why it is nearly empty

Firebase Hosting serves an exact static-file match *before* it evaluates
rewrites. The operator app deploys `build/web`, which has an `index.html` at its
root, so on that site `/` always resolves to the Flutter app — on every domain
attached to it. The `routeCustomDomainRoot` rewrite could never fire, and every
facility custom domain rendered the SFC operator app instead of the operator's
own website.

That is not a config mistake; it is a property of sharing one Hosting site
between an SPA and host-routed content. The two cannot coexist.

So facility websites get their own site, whose deploy root contains **no
`index.html`** — nothing for `/` to match, so the rewrite runs and the request
reaches `routeCustomDomainRoot`, which looks the hostname up and serves that
facility's site.

## Rules for this directory

- **Never add an `index.html` here.** It would silently reinstate the original
  bug for every facility at once, and the symptom (customers seeing the wrong
  site) shows up on their domains, not in any test.
- Keep it free of anything that could shadow a rewrite path (`/w/**`,
  `/robots.txt`, `/sitemap.xml`, `/api/**`).
- Files placed here are public on every facility domain.

`firebase.json` ignores `**/*` for this target, so nothing here is uploaded;
the directory exists to give the target a valid, documented deploy root.
