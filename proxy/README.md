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
a user-owned file. What it does with the saved compose (verified against
Coolify **4.4.6** source and in a sandbox):

| Action | Effect on the saved compose |
| --- | --- |
| **Save**, start, restart, server validation | Used **verbatim**, comments included |
| **Traffic analytics toggle** (Server → Analytics) | Parsed, the [analytics block](#traffic-analytics-coolify-44) added/removed, written back: every key survives, **all comments are lost** |
| **Reset configuration**, proxy-type change, empty config | **Regenerated** from Coolify's template — everything reverts to stock |

Coolify is meant to keep custom `command:` flags on a regeneration, but 4.4.6's
*Reset configuration* regenerates without reading the saved config, so it drops
**all** of them (sandbox-verified). So the hardening splits into:

| Class | What | Survives a toggle? | Survives a reset? |
| --- | --- | --- | --- |
| **DURABLE** | Everything in [`dynamic/bg-defaults.yml`](dynamic/bg-defaults.yml) (global middlewares + TLS policy) | ✅ | ✅ (the TLS policy keeps applying; the middleware is no longer wired) |
| **Compose** | Added `command:` flags (respondingTimeouts, `bg-default@file` wiring) and the compose structure (`image` pin, dropped `8080`, capabilities, `security_opt`, `oom_score_adj`, `logging`, `stop_grace_period`) | ✅ | ⚠️ Reverts to Coolify stock |

**A revert is harmless** — you fall back to a working, unhardened Coolify
proxy. To restore the hardening, re-paste
[`docker-compose.yml`](docker-compose.yml) and restart the proxy. Every Save
also keeps the previous file in `/data/coolify/proxy/backups/` (10 versions).

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

**Hardening defaults** (definitions in the durable dynamic file; the
entrypoint wiring and the timeouts are compose flags — see the table above):

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

**Compose structure (reverts on regeneration):**

- Traefik pinned to **v3.7** (the version Coolify 4.4's template ships)
- **Dashboard OFF** — no `8080` publish, no dashboard router (stock exposes a
  dead `:8080` port with `--api.insecure=false`). Coolify does not need it — it
  tracks proxy status by Docker container state, not the Traefik API.
- `traefik.enable=false` (as in Coolify 4.4) — with `true`, Traefik's docker
  provider builds a router for the proxy container itself
- `cap_drop: ALL` + only `NET_BIND_SERVICE` and `DAC_OVERRIDE`,
  `no-new-privileges`. `DAC_OVERRIDE` is required: `setup.sh` and Coolify's
  installer create `/data/coolify/proxy` as `9999:root 0700`, and without it
  root cannot read `dynamic/` or `acme.json` (every router errors, no
  certificates) — sandbox-verified. The only other mount is the Docker socket,
  which is root-equivalent anyway.
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

The file contains the [traffic analytics](#traffic-analytics-coolify-44) block.
**Analytics off?** Delete both marked blocks first (between
`>>> BEGIN traffic analytics` and `<<< END traffic analytics`):

```bash
sed '/>>> BEGIN traffic analytics/,/<<< END traffic analytics/d' docker-compose.yml
```

### 3. Verify

```bash
# proxy up + healthy, ports 80/443/443udp, no 8080
docker ps --filter name=coolify-proxy
docker port coolify-proxy

# global defaults are live: HSTS + brand headers on any app response
curl -sI https://<one-of-your-app-domains> | grep -iE 'strict-transport|server:|x-powered-by'

# an existing app still serves + renews certs
curl -I https://<one-of-your-app-domains>

# Traefik can read its directory (must print nothing)
docker logs coolify-proxy 2>&1 | grep -iE 'permission denied|access logger'
```

If a response is missing those headers, or apps return 404/500, the dynamic
file probably isn't installed — re-check step 1.

---

## Traffic analytics (Coolify 4.4+)

Coolify 4.4 added traffic analytics (Server → Analytics): Traefik writes a JSON
access log to `/data/coolify/proxy/access.log`, Coolify's Sentinel tails it
read-only, and a small `traefik-logrotate` sidecar rotates it (above 20 MiB,
5 gzipped rotations). Turning analytics on or off makes Coolify add or remove
exactly two things in the saved compose — 11 `--accesslog*` flags at the end of
`command:` and the `traefik-logrotate` service — and restart the proxy.

[`docker-compose.yml`](docker-compose.yml) already contains both, in Coolify's
exact form (marked `>>> BEGIN / <<< END traffic analytics`), so it stays a
fix-point (sandbox-verified against Coolify 4.4.6):

| Situation | Result |
| --- | --- |
| Analytics **on**, file pasted | Saved verbatim; Traefik logs, Sentinel ingests, hardened sidecar rotates |
| Toggle afterwards (off, on) | Coolify removes/re-adds the block **without duplicates**; all hardening keys survive, **comments are lost**, the sidecar's own hardening reverts to Coolify's stock sidecar |
| Analytics **off** | Delete both marked blocks before pasting (see [Install](#2-proxy-compose-hardened)) — otherwise Traefik keeps writing an access log nobody reads |

> Re-pasting the file after a toggle restores comments and the hardened
> sidecar. Do **not** paste a version without the block while analytics is on:
> Coolify does not re-add it on Save, and analytics silently stays empty until
> the next toggle.

Keep the block unchanged: the flag strings, their order at the end of
`command:`, the service key `traefik-logrotate`, its container name and the
`$$` escaping in the script. With the complete set present Coolify treats it as
its own; a different service key would make the next toggle add a second
sidecar with the same container name. Whenever Coolify applies the block
(toggle, reset) it replaces your own `--accesslog.*` flags with its set.

Behind Cloudflare no extra Traefik setting is needed: Sentinel takes the
visitor IP from `Cf-Connecting-Ip` when the connecting peer is a Cloudflare
address. Do **not** add `forwardedHeaders.trustedIPs` for Sentinel's sake — it
makes Sentinel fall back to the spoofable leftmost `X-Forwarded-For` entry.

### Privacy (GDPR)

- `access.log` and its rotations hold, per request, the full client IP (plus
  `X-Forwarded-For` / `Cf-Connecting-Ip`), User-Agent, full Referer and the
  request path **including the query string**. Retention is by size only
  (the live file plus 5 gzipped rotations of ~20 MiB of log lines each), so on
  quiet hosts that can mean months. **Disabling analytics deletes nothing** —
  remove `/data/coolify/proxy/access.log*` yourself if needed.
- Sentinel keeps daily aggregates for 395 days by default ("Daily retention" on
  the Analytics page) including the full IP as a top-N dimension. Minute and
  hourly rows are folded into them within 1-3 days ("Hourly retention" is only a
  fallback if that fails).
- **"Client IP addresses: Anonymized/Off" has no effect yet**: Sentinel 1.0.2
  ignores the setting and stores full IPs; support (including purging stored
  IPs) arrives with Sentinel 1.0.3+. "Off" only hides the IP breakdown in the
  UI.
- Document the processing (lawful basis, retention) in your records of
  processing and privacy notice, or keep analytics off on hosts where that is
  not settled.

### Disk usage

| Data | Path | Bound |
| --- | --- | --- |
| Raw access log | `/data/coolify/proxy/access.log` + `.1-.5.gz` | Sidecar checks every 60 s and rotates above 20 MiB. Under sustained load the live file reaches *traffic × 60 s* first (measured: ~1 KB per request, 3,700 req/s → ~240 MB), and a rotation briefly needs a second uncompressed copy. Rotations compress ~27:1. Only bounded while the sidecar runs |
| Traffic aggregates | `/data/coolify/sentinel/analytics.sqlite` | Daily rows × "Daily retention" (395 days), top-50/200 per dimension. Grows for ~13 months, then levels off: roughly 25-250 MB per app (quiet to busy). SQLite never shrinks the file. Not capped: distinct `Host` header spellings, so an attacker can add rows |
| Server/container metrics | `/data/coolify/sentinel/metrics.sqlite` (+ `-wal`) | "Metrics history days" (default 7): ~20 MB per container |
| GeoIP database | `/data/coolify/sentinel/geoip-*.mmdb` | One file, 3-8 MB |
| Container logs (Traefik, sidecar, Sentinel) | Docker json-file | 50 MB × 5, 1 MB × 2, and `daemon.json` (10 MB × 3) |

The daily `doctor.sh check` (`coolify-check.timer`, see the main README) fails
when the rotation sidecar is missing and warns about a large access log or
Sentinel directory - into the journal only. Coolify's own disk alert (80 %)
checks `/` only and only fires with a notification channel configured.

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

> **`bg-defaults.yml` does not roll back with the compose.** It lives in the
> dynamic dir, so its `tls.options.default` keeps applying to every https router
> under the stock compose too. Roll it back explicitly — after the compose.

1. Server → Proxy → Configuration → **Reset configuration** → Restart Proxy.
   In Coolify 4.4.6 this restores the stock compose wholesale, including the
   removal of the `bg-default@file` entrypoint flags (traffic analytics stays as
   configured). Confirm with
   `docker inspect coolify-proxy --format '{{json .Args}}'` — the running
   container counts, not the editor.
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
- **Access log = Coolify's.** `--accesslog.*` and `--log.level=` are
  template-owned, and every analytics toggle or reset replaces custom
  `--accesslog.*` flags with Coolify's set. A custom filtered access log (e.g.
  without query strings) is therefore best-effort at most.
- **Version pin is best-effort** — a regen sets `image:` to Coolify's template
  version (v3.7 in Coolify 4.4).

---

Ported from the BAUER GROUP **CS-Traefik** (EDGEPROXY) stack. For a broader
middleware catalogue to build per-app overrides from, see that repo's
`docs/middlewares.md`.
