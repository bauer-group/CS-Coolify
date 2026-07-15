# Hardened Coolify Traefik Proxy (optional)

An **optional**, hardened drop-in replacement for the Traefik reverse proxy
that Coolify auto-generates and manages. It layers the BAUER GROUP EDGEPROXY
security posture on top of Coolify's proxy **without breaking Coolify's ability
to manage it or route deployed apps**.

Coolify itself is unaffected — the control-plane stack in the repo root
(`../docker-compose.yml`) stays exactly as-is. This only touches the proxy that
lives under `/data/coolify/proxy/`.

> **You do not need this.** Coolify's stock proxy works fine. Use this only when
> you want the extra hardening: tuned timeouts, container capability drop, log
> rotation, and sensible security defaults (compression, HSTS, security headers,
> a global TLS policy) applied to **every** app automatically.

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
| **DURABLE** | Everything in [`dynamic/bg-defaults.yml`](dynamic/bg-defaults.yml) (global middlewares + TLS policy) and the added `command:` flags (respondingTimeouts + the `bg-default@file` entrypoint wiring) | ✅ Yes |
| **BEST-EFFORT** | Compose structure: `image` pin, dropped `8080`, `cap_drop`/`security_opt`, `oom_score_adj`, `logging`, `stop_grace_period` | ⚠️ Reverts to Coolify stock |

**A best-effort revert is harmless** — you fall back to a working, unhardened
Coolify proxy. To restore the hardening, just re-paste
[`docker-compose.yml`](docker-compose.yml) and restart the proxy. (The DURABLE
parts keep working through a regen regardless.)

The load-bearing Coolify contract is preserved **byte-for-byte**, so nothing
about routing changes:

- container name `coolify-proxy`, external network `coolify`
- entrypoints **`http`** (:80) and **`https`** (:443) — every deployed app
  labels itself against these names
- cert resolver **`letsencrypt`** (HTTP-01 on `http`), ACME at `/traefik/acme.json`
- docker + file providers, `/data/coolify/proxy/:/traefik` mount, HTTP/3,
  `extra_hosts`, `restart: unless-stopped`

---

## What the hardening adds

Coolify generates every app's Traefik labels itself, so nobody hand-adds `@file`
middlewares — an opt-in toolbox would sit unused. Instead the defaults apply
**globally**, to every router, with zero per-app configuration.

**Durable (survives regeneration):**

- **Global default middlewares** ([`dynamic/bg-defaults.yml`](dynamic/bg-defaults.yml)),
  wired at both entrypoints so they hit every app **and** Coolify's own
  UI/realtime routes:
  - `bg-compress` — compression, excluding `text/event-stream` (SSE stays
    unbuffered) and already-compressed media. WebSockets (Coolify's `/app` +
    `/terminal/ws`) are Upgrade connections and pass through untouched.
  - `bg-headers` — HSTS (1 year, **no** includeSubdomains, **HTTPS-only** — no
    `forceSTSHeader`, so it is never sent on the http entrypoint and an
    intentionally HTTP-only service is unaffected), plus fixed BAUER GROUP brand
    values for `Server` (`BAUER GROUP Edge`) and `X-Powered-By` (`BAUER GROUP`)
    — constant values that advertise us and, being fixed, mask the real backend
    software + version. `X-Content-Type-Options: nosniff` and a third brand
    header `X-Solution-Provider` both ship **commented-out** in the file —
    uncomment either to enable it. Referrer-Policy is intentionally left to
    apps/browsers (a global one would override an app's own policy).
- **Global TLS policy** — `tls.options.default` with `minVersion: TLS 1.1` and a
  legacy-compatible cipher list (the EDGEPROXY posture — keeps old clients
  online). Applies to every router; **override per app for stricter TLS**.
- **respondingTimeouts** on both entrypoints — `readTimeout=0s`/`writeTimeout=0s`
  (unbounded body/response for large uploads, S3/MinIO multipart, SSE) and
  `idleTimeout=300s` (keeps quiet WebSocket connections alive).

Deliberately **not** global (would break apps or fight Coolify): frame-deny /
permissions-policy (break legit iframes / camera-mic), a global rate-limit (an
entrypoint rate-limit counts per source IP across *all* apps — too coarse for
CGNAT; do DoS at the edge), and an HTTP→HTTPS redirect (Coolify does it per app,
and a global one would fight the ACME HTTP-01 challenge). Add those per app.

### Expected log noise at every proxy start

Once per start — and **only** at start — Traefik logs:

```text
ERR middleware "bg-default@file" does not exist  routerName=ping@internal
ERR middleware "bg-default@file" does not exist  routerName=acme-http@internal
```

**This is harmless. Do not "fix" it.** It is a Traefik startup race, not a
misconfiguration: Traefik applies its first config generation as soon as the
`internal` provider reports and does not wait for the file provider, so the two
internal routers are built while the middleware map is still empty. The next
generation merges the file config and both routers come up normally — verified
on `traefik:v3.7`: the runtime API reports both `status=enabled` with
`mw=[bg-default@file]`, and `wget -qO- http://localhost:80/ping` returns `OK`.
Neither the healthcheck nor the ACME HTTP-01 challenge is affected.
Upstream: [traefik#9779](https://github.com/traefik/traefik/issues/9779),
`kind/bug/confirmed`, won't-fix for now.

> **When it is NOT harmless:** if these lines *recur* outside startup (every
> Coolify deploy triggers a config reload), or name `@docker` routers, then
> `bg-defaults.yml` genuinely failed to load and *every* router is erroring.
> Check with `docker logs coolify-proxy --since 15m 2>&1 | grep 'does not exist'`
> — that must be **empty**.

Dropping `--entrypoints.http.http.middlewares=` would silence both lines (both
internal routers live on http), but it strips `bg-headers` from plain-HTTP
responses: a service that intentionally serves over HTTP then leaks its real
backend — measured, `Server: nginx/1.31.2` instead of `Server: BAUER GROUP Edge`.
Two documented benign log lines beat losing that masking. Apps that redirect
HTTP→HTTPS are unaffected either way — Traefik generates the 30x itself, so no
backend header is ever exposed on that path.

**Best-effort (reverts on regeneration):**

- Traefik pinned to **v3.7** (replaces Coolify's older template default)
- **Dashboard OFF** — no `8080` publish, no dashboard router (stock exposes a
  dead `:8080` port with `--api.insecure=false`). Coolify does not need it — it
  tracks proxy status by Docker container state, not the Traefik API.
- `cap_drop: ALL` + only `NET_BIND_SERVICE`, `no-new-privileges`
- `oom_score_adj: -50` (BAUER GROUP OOM hierarchy)
- non-blocking **json-file logging** with rotation (stock sets none)
- `stop_grace_period: 30s`

---

## Install

> **Order matters — dynamic config FIRST.** The compose references
> `bg-default@file` on both entrypoints; if that middleware isn't defined yet,
> Traefik can't resolve it and *every* router errors (including the Coolify UI)
> — permanently, not just the two benign startup lines documented above.

### 1. Dynamic config (the global defaults — install first)

Coolify UI → **Server → Proxy → Dynamic Configurations** → add one file:

- `bg-defaults.yml` → paste [`dynamic/bg-defaults.yml`](dynamic/bg-defaults.yml)

(Lands in `/data/coolify/proxy/dynamic/`, hot-reloads, and never collides with
Coolify's reserved `coolify.yaml` — verified: Coolify defines no `tls` block, so
our `tls.options.default` is authoritative, and only the `gzip` /
`redirect-to-https` middleware names, which this file avoids.)

### 2. Proxy compose (hardened)

Coolify UI → **Server → Proxy → Configuration** → replace the editor contents
with [`docker-compose.yml`](docker-compose.yml) → **Save** → **Restart Proxy**.

### 3. Verify

```bash
# proxy up + healthy, ports 80/443/443udp, no 8080
docker ps --filter name=coolify-proxy
docker port coolify-proxy

# global defaults are live: HSTS + brand headers on any app response
curl -sI https://<one-of-your-app-domains> | grep -iE 'strict-transport|server:|x-powered-by'

# an existing app still serves + renews certs
curl -I https://<one-of-your-app-domains>
```

If a response is missing those headers, or apps return 404/500, the dynamic
file probably isn't installed — re-check step 1.

---

## Overriding the global defaults per app

The defaults apply automatically. Per-app router middlewares run **after** the
global entrypoint middlewares, so an app can layer its own on top (rate-limit,
body-cap, frame-deny, forward-auth, …) via a Traefik label in Coolify
(Advanced → Labels):

```yaml
traefik.http.routers.<router>.middlewares=<your-mw>@file
```

For **stricter TLS on one app** (admin / payment surface), add a named option
to `bg-defaults.yml` and point that app's router at it:

```yaml
# in bg-defaults.yml, under tls.options:
#   bg-strict: { minVersion: VersionTLS13, sniStrict: true }
traefik.http.routers.<router>.tls.options=bg-strict@file
```

`<router>` is the router name Coolify generates for the app (see the Traefik
logs or the app's generated labels).

> To change a default globally, edit the `bg-default` chain / `bg-headers` /
> `tls.options.default` in `bg-defaults.yml` — but do **not** remove the file
> while the entrypoint flags are live.

---

## Rollback to Coolify stock

> **The DURABLE parts do not roll back by pasting the stock compose.** That is
> the flip side of durability: `--entrypoints.*.http.middlewares=` is a custom
> flag, so Coolify carries it into the regenerated compose. The editor then
> shows stock while the running container still has the flag — verify with
> `docker inspect coolify-proxy --format '{{json .Args}}'`, not with the editor.
> Same for `bg-defaults.yml`: it lives in the dynamic dir and a compose rollback
> never touches it, so its `tls.options.default` keeps applying to every https
> router under the stock compose too. Roll both back explicitly.

1. Remove both `--entrypoints.*.http.middlewares=bg-default@file` lines from the
   proxy compose (Server → Proxy → Configuration) → Restart Proxy — or
   *Reset to default* / trigger a server revalidation to restore stock wholesale.
   Confirm they are gone from the *running container's* args, not just the editor.
2. **Only then** delete `bg-defaults.yml` in Server → Proxy → Dynamic
   Configurations. Order matters: never leave the entrypoint flags pointing at a
   deleted middleware, or every router errors.

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

Ported from the BAUER GROUP **CS-Traefik** (EDGEPROXY) stack. For a broader
middleware catalogue to build per-app overrides from, see that repo's
`docs/middlewares.md`.
