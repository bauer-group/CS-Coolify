# Hardened Coolify Traefik Proxy (optional)

An **optional**, hardened drop-in replacement for the Traefik reverse proxy
that Coolify auto-generates and manages. It layers the BAUER GROUP EDGEPROXY
security posture on top of Coolify's proxy **without breaking Coolify's ability
to manage it or route deployed apps**.

Coolify itself is unaffected — the control-plane stack in the repo root
(`../docker-compose.yml`) stays exactly as-is. This only touches the proxy that
lives under `/data/coolify/proxy/`.

> **You do not need this.** Coolify's stock proxy works fine. Use this only when
> you want the extra hardening (tuned timeouts, container capability drop, log
> rotation, a reusable middleware + TLS-options toolbox for your apps).

---

## ⚠️ Read this before you deploy: Coolify owns the proxy compose

Coolify treats the proxy `docker-compose.yml` as a **generated artifact**, not
a user-owned file. On a **proxy regeneration** — triggered by *server
revalidation*, a *forced regenerate*, an *empty config*, or a *proxy-type
change* — Coolify rebuilds the whole compose from its hardcoded template and
preserves **only** custom `command:` flags whose prefix is not template-owned.
(Verified against `coollabsio/coolify` source; documented in issue
[#3018](https://github.com/coollabsio/coolify/issues/3018).)

So the hardening splits into two durability classes:

| Class | What | Survives a full regen? |
| --- | --- | --- |
| **DURABLE** | Everything in [`dynamic/`](dynamic/) (TLS options + middlewares) and the added `command:` flags (respondingTimeouts) | ✅ Yes |
| **BEST-EFFORT** | Compose structure: `image` pin, dropped `8080`, `cap_drop`/`security_opt`, `oom_score_adj`, `logging`, `stop_grace_period` | ⚠️ Reverts to Coolify stock |

**A best-effort revert is harmless** — you fall back to a working, unhardened
Coolify proxy. To restore the hardening, just re-paste
[`docker-compose.yml`](docker-compose.yml) and restart the proxy.

The load-bearing Coolify contract is preserved **byte-for-byte**, so nothing
about routing changes:

- container name `coolify-proxy`, external network `coolify`
- entrypoints **`http`** (:80) and **`https`** (:443) — every deployed app
  labels itself against these names
- cert resolver **`letsencrypt`** (HTTP-01 on `http`), ACME at `/traefik/acme.json`
- docker + file providers, `/data/coolify/proxy/:/traefik` mount, HTTP/3,
  `extra_hosts`, `restart: unless-stopped`

---

## What the hardening actually adds

**Durable (survives regeneration):**

- **respondingTimeouts** on both entrypoints — `readTimeout=0s` / `writeTimeout=0s`
  (unbounded body/response for large uploads, S3/MinIO multipart, SSE/streaming)
  and `idleTimeout=300s` (keeps quiet WebSocket connections alive). Added as
  `--entrypoints.<ep>.transport.*` command flags, which Coolify preserves.
- A reusable **middleware toolbox** ([`dynamic/bg-middlewares.yml`](dynamic/bg-middlewares.yml)):
  HSTS, frame/nosniff/referrer/permissions headers, CORS, rate limits (CGNAT-sized),
  body-size caps, retry, circuit breakers, www-canonicalisation, forward-auth
  (Authelia/Authentik), compression, and pre-composed chains
  (`hardened-public`, `hardened-api`, `s3-streaming`, `hardened-login`).
- Named **TLS options** ([`dynamic/bg-tls.yml`](dynamic/bg-tls.yml)):
  `bg-modern` (TLS 1.3), `bg-intermediate` (TLS 1.2 AEAD), `bg-compat`
  (TLS 1.1 legacy-client support).

**Best-effort (reverts on regeneration):**

- Traefik pinned to **v3.7** (replaces Coolify's older template default)
- **Dashboard OFF** — no `8080` publish, no dashboard router (stock exposes a
  dead `:8080` port with `--api.insecure=false`)
- `cap_drop: ALL` + only `NET_BIND_SERVICE`, `no-new-privileges`
- `oom_score_adj: -50` (BAUER GROUP OOM hierarchy)
- non-blocking **json-file logging** with rotation (stock sets none)
- `stop_grace_period: 30s`

---

## Install

Two parts. Do the **dynamic config first** so the middleware/TLS references
always resolve.

### 1. Dynamic config (durable toolbox)

Coolify UI → **Server → Proxy → Dynamic Configurations** → add two files:

- `bg-middlewares.yml` → paste [`dynamic/bg-middlewares.yml`](dynamic/bg-middlewares.yml)
- `bg-tls.yml` → paste [`dynamic/bg-tls.yml`](dynamic/bg-tls.yml)

(These land in `/data/coolify/proxy/dynamic/` and hot-reload. They never
collide with Coolify's reserved `coolify.yaml`.)

### 2. Proxy compose (hardened)

Coolify UI → **Server → Proxy → Configuration** → replace the editor contents
with [`docker-compose.yml`](docker-compose.yml) → **Save** → **Restart Proxy**.

### 3. Verify

```bash
# proxy is up and healthy
docker ps --filter name=coolify-proxy

# hardened flags are live (timeouts, no 8080)
docker inspect coolify-proxy --format '{{json .Args}}' | tr ',' '\n' | grep respondingTimeouts
docker port coolify-proxy            # should show 80, 443, 443/udp -- no 8080

# an existing app still serves + renews certs
curl -I https://<one-of-your-app-domains>
```

Then redeploy (or just hit) one existing app to confirm routing + TLS are
unaffected.

---

## Using the toolbox from a deployed app

In Coolify, add custom Traefik labels to the application (Advanced → Labels, or
the app's compose). Reference file-provider middlewares/options with `@file`:

```yaml
# Harden a public web app
traefik.http.routers.<router>.middlewares=hardened-public@file

# Strict TLS 1.3 for an admin surface
traefik.http.routers.<router>.tls.options=bg-modern@file

# Compose several (comma-separated), e.g. API + a body cap
traefik.http.routers.<router>.middlewares=hardened-api@file
```

`<router>` is the router name Coolify generates for that app (visible in the
Traefik logs or the app's generated labels).

### Always-on BAUER GROUP header (optional)

To stamp `X-Solution-Provider: BAUER GROUP` on **every** response, uncomment
the two `--entrypoints.*.http.middlewares=bg-provider@file` lines in
[`docker-compose.yml`](docker-compose.yml) — **only after** `bg-middlewares.yml`
is installed (step 1), or the unresolved reference breaks every router,
including Coolify's own UI.

---

## Rollback to Coolify stock

- **Compose:** Coolify UI → Server → Proxy → Configuration → *Reset to default*
  (or trigger a server revalidation), then Restart Proxy.
- **Dynamic config:** delete `bg-middlewares.yml` and `bg-tls.yml` in
  Server → Proxy → Dynamic Configurations. Remove any `@file` references you
  added to apps first, so no router points at a now-missing middleware.

---

## Known limitations in a Coolify proxy

- **No extra cert resolvers.** The `--certificatesresolvers.` prefix is
  template-owned, so a custom DNS-01/wildcard resolver is silently dropped on
  regen — and Traefik resolvers are static-only, so the file provider can't
  hold them either. HTTP-01 `letsencrypt` is the only durable resolver here.
  (Wildcards still work app-side if you bring the cert another way.)
- **No mounted static `traefik.yml`.** Coolify is CLI-args-only; a static
  config file is not read. All static settings must be `command:` flags.
- **`--accesslog.*` / `--log.level=` are template-owned** → a custom filtered
  access log doesn't survive regen, so it's intentionally left out.
- **Version pin is best-effort** — a regen reverts `image:` to Coolify's
  template version. To make v3.7+ permanent, upgrade Coolify so its template
  ships it.

---

Ported from the BAUER GROUP **CS-Traefik** (EDGEPROXY) stack. For the full
middleware reference and app-integration examples see that repo's
`docs/middlewares.md`.
