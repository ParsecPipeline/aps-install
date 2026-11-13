# Installing the Astro Pixel Platform on Kubernetes

One command installs, upgrades and (with a second one) removes the whole platform on any Kubernetes cluster with internet
access: Argo Workflows (the compute engine), the identity provider (Zitadel), Postgres + pg_sphere, an S3 object store, the API
(`apsd`), the web UI, the verbs (plate solve, metadata extraction, reftool) and the per-node astrometry indexes.

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -
```

Options go after `-s --`:

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -s -- \
  --namespace aps --values my-values.yaml --set routes.host=aps.example.org
```

Everything the script does is visible in the script (`sh install.sh --help` lists the flags). It never uses `sudo`, never edits your
kubeconfig, writes only to a temporary directory it removes on exit, and runs `helm upgrade --install` on the chart
`oci://ghcr.io/parsecpipeline/charts/aps` (pinned to the version the script was published with).

## Flags

`install.sh --help` is the authoritative list (every flag has an `APS_*` environment twin). The ones you will use:

| Flag | Meaning |
|---|---|
| `--namespace NS`, `--release NAME` | where and under which name the release lives (default `aps` / `aps`) |
| `--values FILE`, `--set K=V` | Helm values, repeatable, applied in the order given |
| `--chart DIR\|TGZ`, `--chart-url URL`, `--version V` | install a local or downloaded chart instead of the published OCI chart |
| `--context NAME` | kubectl/helm context (`KUBECONFIG` is honoured) |
| `--url URL` | the address this machine reaches the cluster at (an IP becomes `aps.<ip>.sslip.io` as the public name); overrides Traefik discovery. `--url https://NAME[:PORT]` with no `tls.mode` and no certificate configured means TLS ends in front of the cluster: the installer sets `tls.mode=upstream`, `routes.host=NAME` and says so |
| `--no-traefik-changes` | never modify a Traefik you reuse: with one host name (below) the installer stops before installing and prints the exact change instead |
| `--no-identity-values` | do not generate the identity host values (Zitadel external domain, Argo SSO): you supply them (see Names) |
| `--timeout DUR`, `--wait-indexes[=DUR]` | readiness budget; optionally wait for the astrometry indexes on every node |
| `--helm-version V` | pinned helm to download when none >= 3.14 is on `PATH` |
| `--dry-run` | pass `--dry-run` to Helm: nothing is installed |
| `--bootstrap`, `--k3s-version V` | install single-node k3s first on a bare host (next section) |

`uninstall.sh --help` lists `--release`, `--namespace`, `--context`, `--purge-data`, `--purge-crds`, `--purge-indexes`,
`--index-image IMG` (the image of the purge pods when the release is already gone) and `--remove-k3s` (see Uninstalling).

## A bare Linux host with no Kubernetes: `--bootstrap`

On a single Linux machine (a VM, a home server) with no cluster, one opt-in flag installs a single-node
[k3s](https://k3s.io) first and then the platform, as root:

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sudo sh -s -- --bootstrap --yes
```

It prints the app URL when it is done (open it and create your account: the first account becomes the owner).

- **Opt-in only.** Without `--bootstrap` the script never installs Kubernetes. With it, a cluster that is already reachable
  (your kubeconfig answers) is left alone: the k3s step is skipped and the script says so. A host that already runs k3s from an
  earlier `--bootstrap` is reused (its kubeconfig is picked up), never reinstalled over.
- **Needs root** for the k3s step (`sudo sh`), with a clear error otherwise, and a Linux host with ports 80 and 443 free (k3s's
  ingress listens there; the script refuses when something else already does).
- **What is installed:** k3s at a pinned version (`--k3s-version`, default `v1.34.13+k3s1`) through its official installer script.
  The script is taken from that release tag of the k3s repository (not from `get.k3s.io`, which always serves the moving
  newest copy and so cannot be checksum-pinned) and verified against a SHA-256 embedded in `install.sh` before it runs; the
  installer then verifies the k3s binary against the release's own checksum file. A different `--k3s-version` needs
  `APS_K3S_INSTALL_SHA256` (the sha256 of that tag's `install.sh`). The script waits for the node to be Ready, for k3s's
  default StorageClass and for Traefik, uses `/etc/rancher/k3s/k3s.yaml` for the rest of the run and installs the chart normally.
- **Ingress: k3s's bundled Traefik is reused.** The installer finds it (CRDs plus a running controller) and installs the chart with
  `traefik.install=false`, so nothing else is deployed. The chart's `IngressRoute`s do not buffer requests or responses, so large
  uploads and the live run stream work through it; `install-smoke` proves the large-body and event-stream behaviour through
  Traefik on every VM run. k3s's Traefik keeps its default entrypoint timeouts: see "Timeouts on a Traefik you reuse".
- **kubectl afterwards:** `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` as root, or `sudo k3s kubectl ...`.
- **Removing it again:** `uninstall.sh --remove-k3s` (below).

## Prerequisites

| Need | Why | If missing |
|---|---|---|
| `kubectl` with a context for the cluster | the script talks to the API server | install kubectl; `--context NAME` picks a non-default context |
| Kubernetes 1.30 or newer | the bundled Zitadel chart, native sidecars | checked, exit 2 |
| A name for the app and one for the identity provider | OIDC redirects browsers between them (next section) | the script picks `aps.<node address>.sslip.io` when it can; otherwise exit 2 |
| Permission to create CRDs, ClusterRoles and (if absent) the namespace | Argo installs CRDs; the index fetcher needs a ClusterRole (below) | checked, exit 2 with the missing verb; use a cluster-admin context |
| A default StorageClass | Postgres (5 Gi) and the object store (10 Gi) use PVCs | warning; `--set global.storageClass=<name>` or use external services |
| Traefik | the app is published through Traefik `IngressRoute`s | reused when found (k3s and microk8s ship one), otherwise the chart installs it (next section) |
| hostPath volumes allowed in the namespace | the index fetcher keeps indexes in `/var/lib/aps/astrometry-index` on each node | warning if the namespace enforces Pod Security baseline/restricted |
| Free disk on the nodes that will solve | `wide` preset ~0.3 GB; +4.6 GB for 5200-LITE; ~34 GB for everything | the fetcher refuses to fill a disk (`insufficient-disk` in its node annotation) |
| Internet access from the nodes | image pulls from `ghcr.io`, Argo from `quay.io`, indexes from `data.astrometry.net` | see "Air-gapped and mirrored installs" |
| linux/amd64 nodes | the published images are amd64 only | warning |

Helm 3.14+ is used from your `PATH`; otherwise the script downloads the pinned helm for your OS/CPU into a temporary
directory and verifies it against a SHA-256 table embedded in the script (not fetched from the same host).

## What happens

1. Preflight (all read-only; nothing is changed if it fails): context and server shown, API ready, version, permissions,
   StorageClass, node architectures, Pod Security of the namespace, foreign Argo CRDs, an interrupted Helm release, and the
   Traefik decision (found and reused, or installed by the chart; printed).
2. `helm upgrade --install aps <chart> -n aps --create-namespace --wait --timeout 15m --reset-then-reuse-values ...`.
   No `--atomic`: after an interruption (Ctrl-C, network) you re-run and it resumes with the images already pulled.
3. Waits for `apsd` and the web UI, then polls `/readyz`.
4. Reports the index download progress per node (it never blocks on it unless you pass `--wait-indexes`) and prints the URL,
   the first-user instructions, and the upgrade/uninstall commands.

Exit codes: 0 ok, 2 preflight or usage problem (nothing installed), 3 Helm failed (status and warning events are printed), 4 the
app did not become ready in time, or sign-in cannot work (the identity provider is not served where browsers are sent).

### Names: hosts, ports and TLS

The app and the identity provider need **two public names that the browser resolves**, for example `aps.example.org` (the app,
`routes.host`) and `id.aps.example.org` (the bundled Zitadel, `identity.host`, default `id.<routes.host>`): the identity
provider builds every URL it hands out from the name it is called by, and the OIDC redirect URI and the cookies belong to the app's
name. Give them with `--set routes.host=aps.example.org` (add `--set routes.port=8080` when the public port is not 80/443, and
`--set tls.mode=...` for TLS). When you give none, `install.sh` uses `aps.<address>.sslip.io` (public wildcard DNS) from the
address it can find (the k3s host, the Traefik load balancer, or the only node); an `--url http://10.0.0.5` becomes that too. An
upgrade keeps the host the release already has.

The Zitadel and Argo subcharts take the identity host, the issuer and the Argo redirect URL as plain values a parent chart cannot
template, so the installer writes them for you (`aps_identity_values` in `install.sh`). With plain Helm run
`deploy/helm/identity-values.sh --host aps.example.org [--port 8080] [--tls|--tls-upstream] [--argo path|host=NAME|off]` and pass the output with
`-f`; `templates/validate.yaml` fails the render, naming the script, when they disagree with `routes.host`. `--no-identity-values`
makes the installer skip generating them (you supply them). The chart's default host `aps.localtest.me` resolves to `127.0.0.1`:
enough for a local kind cluster reached on localhost.

**One host name only.** Where you can have only one name, serve the identity provider on the same host at another port:
`--set identity.host=aps.example.org:8443` (instead of the default sub-host `id.<routes.host>`). Zitadel's external port becomes
that port, the issuer is `<scheme>://aps.example.org:8443`, and Traefik needs an entrypoint on it (named `identity`;
`traefik.entryPoints.identity` renames it). This is automatic:

- The Traefik this chart installs gets the entrypoint (`traefikController.ports.identity`, written by the installer / `identity-values.sh --id-host aps.example.org:8443`).
- A Traefik you **reuse** is inspected before anything is installed. If it already has the entrypoint nothing changes. Otherwise the
  installer adds it, announces it in its output, and waits for the rollout, by the supported mechanism of how that Traefik was installed:
  - **Installed by the official Traefik Helm chart** (microk8s's ingress addon is one): `helm upgrade <its release> traefik --repo https://traefik.github.io/charts --version <its current chart version> --reuse-values`
    with `ports.identity.port` (+ `hostPort` when its `web` port uses a hostPort, else `exposedPort` and `expose`), and for a
    DaemonSet/Deployment on hostPorts `updateStrategy.rollingUpdate.maxSurge=0, maxUnavailable=1` (the default surge pod cannot bind the
    ports the old pod holds). It never uses `--wait` (a LoadBalancer Service without an address, as on microk8s, would never be ready). Nothing is added to your Helm
    repositories; `APS_TRAEFIK_CHART_REPO` points at a mirror.
  - **k3s's bundled Traefik**: a `HelmChartConfig` named `traefik` in `kube-system`. An existing one is merged (the `identity` block goes under its
    `ports:`; other keys and fields stay); if its `ports:` is written inline (`ports: {...}`) the installer stops and tells you instead.
  - **Anything else**: the installer stops before installing (exit 2) with the exact change: the argument `--entryPoints.identity.address=:<port>/tcp` and the port to publish.
  - `--no-traefik-changes` turns the first two into that same error.
- The public port must be reachable by browsers; on a host behind a TLS proxy see the next paragraph. Ports below 1024 use container port `10000 + port`.

After the install the installer checks that sign-in can work: the entrypoint exists, and the identity provider's discovery document
(`/.well-known/openid-configuration`) answers through Traefik with the identity Host header. If not, it prints the diagnosis and exits 4 instead of
announcing success.

**TLS.** Passkeys (WebAuthn) and `Secure` cookies need HTTPS: without `tls.mode` the session cookie is not `Secure` and browsers
refuse passkey enrolment (TOTP works). The no-TLS path is meant for home labs; with `tls.mode=certManager` the Certificate covers
the app, identity and Argo hosts, and Zitadel is told it is served over HTTPS (`ExternalSecure`).

**TLS terminated in front of the cluster** (a tunnel, a TLS-terminating reverse proxy, a cloud load balancer): `--set tls.mode=upstream`. Every public URL
(OIDC redirect URI, `Secure` cookies, the issuer, the Argo redirect URL) is `https://<routes.host>[:<routes.port>]`, but Traefik
keeps serving plain HTTP on its `web` entrypoint with no certificate and no redirect: the proxy in front owns both (a redirect at
Traefik would loop, since Traefik only sees HTTP). Point the proxy at Traefik's HTTP port and have it pass the `Host` header
unchanged; `routes.host` is required. With one host name (`--set identity.host=aps.example.org:8443`) the proxy must also forward
that public HTTPS port to Traefik's `identity` entrypoint (the plain-HTTP port the `identity` entrypoint listens on). Inside the
cluster nothing needs the public certificate: apsd and the bootstrap Job reach Zitadel's Service over plain HTTP with the public
`Host` and `X-Forwarded-Proto: https`, and the Argo pod's forwarder terminates TLS itself with a throwaway certificate (Argo skips
verifying it, `sso.insecureSkipVerify`). The installer's identity values follow `--set tls.mode=upstream` (with plain Helm pass
`--tls-upstream` to `identity-values.sh`).

The installer cannot configure the proxy / tunnel, but it tells you exactly what to map. At the end it prints, with the real addresses
of this cluster's Traefik (a hostPort on the node, a NodePort, or the Service's load balancer):

```
https://aps.example.org:443    ->  http://<node address>:80     (Traefik's `web` entrypoint)
https://aps.example.org:8444   ->  http://<node address>:8444   (Traefik's `identity` entrypoint; only with identity.host=NAME:8444)
```

(with the default sub-host, `https://id.aps.example.org:443` goes to the same `web` entrypoint as the app), plus a Caddy line as an
example. It first tries `https://<identity host>/.well-known/openid-configuration` from the installing machine: if that answers, the
mapping works and it says so; if not, the mapping is printed as a **REQUIRED** step, the install still ends with exit 0 and a warning
(it cannot test your edge from inside), and a failure that is not just the missing mapping exits 4. A TLS proxy running on the same host cannot
listen on a port that Traefik holds as a hostPort (the identity port, e.g. 8444): use a tunnel or another host for it.
`tls.mode` is also read from `-f` values files (plain `key: value` lines, as `routes.host`, `routes.port` and `identity.host`).

### Identity (who you are)

apsd stores no passwords. It is an OpenID Connect client (authorization code + PKCE) of one identity provider:

- **bundled** (default, `identity.mode=bundled`): Zitadel (chart 10.5.0, Zitadel v4.19) with its database and role on the release's
  Postgres, served at `identity.host`, its login UI memory-limited. Everything is configured without a click: a **bootstrap Job**
  creates the project `aps`, the role `platform-admin`, the OIDC clients `aps-apsd` (code + PKCE, JWT access tokens) and `aps-argo`,
  the action that flattens roles into a `groups` claim, and apsd's least-privilege service account (it may only grant/revoke
  roles of that project); it writes the client credentials into Secrets (`<release>-oidc-apsd`, `aps-oidc-argo`,
  `<release>-zitadel-svc`) and then **disables the install's one-time instance-admin credential and deletes its Secrets**. Later
  upgrades converge the project-level parts with the service account. Zitadel's console admin is the human
  `admin@aps.<identity host>`; its generated password is in the Secret `aps-zitadel` (`admin-username`, `admin-password`;
  back that Secret up together with the database, it also holds Zitadel's masterkey). The console is at `<identity URL>/ui/console`.
- **external** (`-f deploy/helm/aps/profiles/identity-external.yaml`, which sets `identity.mode=external` and `idp.enabled=false`):
  any OIDC issuer (Google, Entra ID, Okta, Keycloak, ...). Set `identity.external.issuer`, `identity.external.clientId` and
  `identity.external.clientSecret.existingSecret` (a Secret you create, key `client-secret`), and register the client with the
  redirect URI `<public URL>/auth/callback` (code flow with PKCE, refresh tokens). apsd verifies **JWT access tokens** against the
  issuer's JWKS and needs `aud` to contain the client id (or an entry of `identity.external.audiences`). Roles come from the
  claim `identity.claims.roles` (default `groups`; an array of strings or an object keyed by role); the role
  `identity.claims.adminRole` (default `platform-admin`) makes a platform administrator. In this mode apsd never grants roles.
  A Bearer JWT whose `client_id` is not apsd's is treated as a machine client's and gets an account on first use. List the client ids of
  any other client that signs people in at the same provider (`identity.external.interactiveClients`), so their user tokens are not
  mistaken for machines (those tokens never create an account; accounts are created at apsd's own login under the admission policy).

**The first user.** `identity.registration` is `first-user` by default: the first person to sign in becomes the owner (the bundled
mode grants them `platform-admin`; external mode relies on your claim), after that apsd refuses accounts it has not seen (HTTP 403 at
the callback). `open` lets every user the provider authenticates in; `closed` also switches the bundled Zitadel's self-registration
off, so an administrator creates the accounts in its console. Programs use **personal access tokens** (account page, or
`POST /v1/me/tokens`; scopes `read`, `write`, `process`) as `Authorization: Bearer aps_pat_...`, or an IdP client-credentials JWT.

**Sessions and keys.** The browser holds one sealed cookie (`aps_session`: AES-GCM, HttpOnly, SameSite=Lax) with a short-lived
access token that apsd verifies locally; the refresh token stays server-side. Sign-out and "sign out everywhere" end the sessions;
a disabled user is cut off within 30 seconds, others within one access-token lifetime (`identity.accessTokenSeconds`, 300). The
sealing keys are in the chart Secret (`cookie-key`, `cookie-key-previous`): to rotate, upgrade once with
`--set identity.rotateCookieKeys=true` (existing sessions keep working), then drop the flag.

**Opt-in provisioner.** `--set identity.provisioner.enabled=true` also creates a machine user that can create users (Secret
`<release>-idp-provisioner`, key `pat`; ORG_OWNER plus the instance role IAM_LOGIN_CLIENT, which Zitadel requires for the Session API; it can only be created by the FIRST install, since the install's instance-admin credential is locked down after it): the install smoke uses it (`deploy/dev/values-smoke.yaml` sets it); leave it off otherwise, it is a standing credential.

### Sharing (albums)

People can group their frames into **albums** and share an album with named users (viewer or editor), with everyone who is signed in,
or through a read-only link (`/s/<token>`, no account needed, one album only). Viewers see an album's frames but never run verbs on or
change frames they do not own; every thumbnail, tile and metadata read goes through one access check, and an object you may not view
answers 404. The relationships live in an OpenFGA embedded in apsd (schema `openfga` of the release's Postgres, created and migrated
at startup, nothing to install or configure); albums, their frames, members, links and an audit trail are ordinary tables. Optional
knobs on apsd (no chart value is needed): `APS_AUTHZ_LIST_TIMEOUT` (default `10s`, must stay under 30 s: a slower authorization lookup
fails the request instead of returning a partial list) and `APS_AUTHZ_RECONCILE_INTERVAL` (default `10m`: how often the stored
relationships are re-derived from the album tables, which also repairs a wiped `openfga` schema). Revoking a share takes effect at
once on the replica that handled it and within about a second on the others; a revoked link stops working within 60 seconds.

## Re-running, upgrading, rolling back

Re-running the install command is the upgrade and is idempotent: the generated Secret (Postgres password, object-store keys), the
Postgres and object-store volumes and the node-local indexes are kept, pods that did not change are not restarted (this is proven by
the install smoke: a second run leaves the Secret, the Postgres pod and the data untouched). `--reset-then-reuse-values` keeps the
`--set`/`-f` overrides you gave earlier and applies new chart defaults.

```sh
helm -n aps history aps
helm -n aps rollback aps <revision>       # restores the previous manifests; apsd schema changes are additive
```

A release stuck in `pending-install/upgrade` (an earlier run was killed mid-way) makes the script stop before changing anything and
print the recovery: `helm rollback aps -n aps` when an earlier revision exists, otherwise `helm uninstall aps -n aps` (volumes and
the Secret stay).

## Uninstalling

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/uninstall.sh | sh -s -- --yes
```

By default this removes the release (including a Traefik it installed) and its WorkflowTemplates and **keeps your data**: the
Postgres and object-store volumes, the Secret `aps-secrets`, the Argo CRDs and the node indexes. The Traefik CRDs stay too (Helm never
removes CRDs); installing again sees CRDs without a controller and installs Traefik again. Installing again finds them. Without a terminal to ask on the script
refuses unless you pass `--yes` (or `APS_ASSUME_YES=1`).

| Flag | Also removes |
|---|---|
| `--purge-data` (`--purge`) | the volumes (every frame, user, run) **and** the Secret, always together |
| `--purge-crds` | the `*.argoproj.io` CRDs (this deletes every Argo Workflow on the cluster) |
| `--purge-indexes` | the index files on every node and the node label/annotation (a short pod per node) |
| `--remove-k3s` | the single-node k3s that `install.sh --bootstrap` installed, **last**, by running its `k3s-uninstall.sh` (root; opt-in). This deletes the whole cluster and everything stored in it whatever the other flags say; the node-local index directory `/var/lib/aps` lives outside k3s, so add `--purge-indexes` to remove it too |

On a bootstrapped host: `curl -sfL .../uninstall.sh | sudo sh -s -- --remove-k3s --purge-indexes --yes`.

## Configuration

Every knob is a value with a comment in `deploy/helm/aps/values.yaml` (`helm show values oci://ghcr.io/parsecpipeline/charts/aps`).
Pass overrides with `--set key=value` and/or `--values file.yaml` (repeatable; they are applied in the order given).

| Value | Default | Meaning |
|---|---|---|
| `global.imageRegistry`, `global.imageTag` | `ghcr.io/parsecpipeline`, chart appVersion | where the `aps-*` images come from |
| `global.storageClass` | cluster default | StorageClass of the Postgres and object-store PVCs |
| `traefik.install` | unset (auto) | `true` installs Traefik with the release, `false` reuses the cluster's; `install.sh` decides when unset |
| `routes.enabled`, `routes.host`, `routes.port` | on, `aps.localtest.me` | the IngressRoutes; `routes.host` is required (see Names), `routes.port` when the public port is not 80/443 |
| `routes.maxBodySize` | `2g` | largest upload, enforced by apsd (`APS_MAX_BODY`) |
| `routes.api/auth/web/identity.middlewares` | none | extra Traefik Middleware references per route (rate limits for `/auth` and the login, forward-auth) |
| `tls.mode` | `none` | `none`, `certManager` (needs `routes.host`, `tls.certManager.issuerRef.name`), `secret` (`tls.secretName`) or `upstream` (TLS ends in front of Traefik; needs `routes.host`) |
| `plateSolve.enabled` | `true` | per-node indexes + solving; `false` = no DaemonSet, no solve |
| `plateSolve.preset` | `wide` | `telescope` (narrow, 4107-4114) / `wide` (4107-4119, ~0.3 GB) / `custom` (`plateSolve.indexFiles`) |
| `plateSolve.indexes.hostPath` | `/var/lib/aps/astrometry-index` | node-local path |
| `plateSolve.indexes.nodeSelector/tolerations` | none | which nodes hold indexes and serve solves (tainted nodes are skipped unless tolerated) |
| `identity.mode` | `bundled` | `bundled` (Zitadel) or `external` (your OIDC provider; see Identity) |
| `identity.host` | `id.<routes.host>` | the bundled identity provider's host name, or `name:port` for the same host on another port |
| `identity.registration` | `first-user` | `first-user`, `open`, `closed` |
| `identity.accessTokenSeconds`, `identity.sessionTTL` | `300`, `720h` | access-token lifetime (revocation latency) and browser session lifetime |
| `identity.provisioner.enabled` | `false` | the opt-in user-provisioning machine user |
| `idp.*` | | the Zitadel subchart (resources, replicas); the host keys under `idp.zitadel.configmapConfig` come from `identity-values.sh` |
| `apsd.autoSolve`, `apsd.autoExtractMeta`, `apsd.autoRender` | `true` | process every upload automatically; `autoRender` renders its Library thumbnail (and the thumbnail of every stack/calibrate product). Tile pyramids are rendered on a frame's first view whatever this says |
| `db.mode`, `objectStore.mode` | `incluster` | `external` for your own Postgres (needs pg_sphere) / S3 |
| `secrets.existingSecret` | generated | bring your own credentials Secret |

More astrometry indexes (5200-LITE, ~4.6 GB, for fields of roughly 6 to 22 arcminutes) are opt-in; save as `index-5200lite.yaml` and add
`--values index-5200lite.yaml`:

```yaml
plateSolve:
  series:
    - base: https://portal.nersc.gov/project/cosmo/temp/dstn/index-5200/LITE
      prefix: index-52
      scales: [3, 4, 5, 6]
      tiles: 48
      approxGiB: 5
```

Changing the selection later changes the index set id: each node downloads only the missing files, keeps the old ones, and relabels
itself when complete. Solve runs wait (Pending) on nodes that are not labelled yet.

### Traefik, TLS and uploads

The app is published with Traefik `IngressRoute`s (`traefik.io/v1alpha1`) on every cluster; no other ingress controller is supported.
`/v1` (and `/healthz`, `/readyz`) and `/auth` go straight to `apsd`, everything else to the web UI (static files only; it no longer
proxies the API). Each route carries a headers `Middleware` (`X-Content-Type-Options: nosniff`, `Referrer-Policy`,
`X-Frame-Options` and CSP `frame-ancestors`, plus HSTS when TLS is on) followed by your own `routes.<api|auth|web>.middlewares`
(a list of `{name, namespace?}` references to Middlewares you create: rate limits, forward-auth, ...).

**Which Traefik.** The chart can install the official Traefik chart (pinned, a subchart) or reuse one:

| `traefik.install` | Meaning |
|---|---|
| unset (auto) | `install.sh` decides before calling Helm: a Traefik that is running with its CRDs (`ingressroutes.traefik.io`) is reused, otherwise the chart installs one. It prints which. A re-run keeps a Traefik this release installed. |
| `true` | the release installs Traefik (a LoadBalancer Service; on kind and bare metal see below) |
| `false` | reuse the cluster's Traefik; its CRDs must exist |

Force it with `--set traefik.install=true|false` (this wins over the detection). Helm cannot look at the cluster when it decides
which subcharts to render, which is why the installer resolves `auto`; a plain `helm install` with the key unset installs Traefik and
refuses to render when another Traefik controller is already running ("set traefik.install=false"). k3s and microk8s ship Traefik,
so they reuse it; kind, EKS, GKE and bare clusters get the chart's. Entrypoint names default to `web`/`websecure`
(`traefik.entryPoints.http/https` if your Traefik names them differently). The chart-installed Traefik serves IngressRoutes only
(its Kubernetes Ingress provider is off) and its IngressClass is not the cluster default; tune it under `traefikController.*`
(the values of the Traefik chart). Its Service is a `LoadBalancer`: on a cluster without a load balancer set
`--set traefikController.service.spec.type=NodePort`, or on kind use `deploy/dev/values-kind.yaml` (hostPorts 80/443 on the control plane).

**TLS** (`tls.mode`):

| Mode | What it does |
|---|---|
| `none` (default) | plain HTTP; fine for a home lab |
| `secret` | `--set tls.mode=secret --set tls.secretName=my-cert`: serve with an existing `kubernetes.io/tls` Secret |
| `upstream` | `--set tls.mode=upstream --set routes.host=aps.example.org`: TLS is terminated in front of Traefik (see Names above); https public URLs, plain-HTTP routes, no certificate, no redirect |
| `certManager` | `--set tls.mode=certManager --set routes.host=aps.example.org --set tls.certManager.issuerRef.name=letsencrypt` (kind `ClusterIssuer` by default, or `tls.certManager.issuerRef.kind=Issuer`): the chart creates a cert-manager `Certificate` for `routes.host` (and the Argo UI host) in the Secret `<release>-tls`. cert-manager must be installed; the render fails with a message when its CRDs are missing |

With `secret` or `certManager` the routes move to the `websecure` entrypoint, the plain-HTTP entrypoint redirects every request to HTTPS (permanent;
`tls.redirectPort` when the public HTTPS port is not 443) and HSTS is sent (`routes.security.hstsSeconds`, 0 omits it).

**Uploads and timeouts.** The upload size limit (`routes.maxBodySize`, default 2g) is enforced by `apsd` itself, which answers
413 before reading an over-limit body, and not by Traefik. Traefik's only body limit is its `buffering` middleware, which reads
the whole request into memory or onto disk before forwarding it (a multi-gigabyte upload would be written twice and stall) and
buffers responses unless that is switched off, which also turns the limit off; so the chart renders no buffering middleware,
uploads stream straight to `apsd` and the event streams are never held back. A `ServersTransport` gives the backend connection
long timeouts (`traefik.timeouts`: dial 30s, response header 1h, idle 90s). The Traefik the chart installs also has no read/write
timeout on its entrypoints.

**Timeouts on a Traefik you reuse.** Traefik's entrypoint read timeout (60s by default) caps how long one request may take to arrive,
which a multi-gigabyte upload over a slow link exceeds, and the write timeout cuts event streams. Raise them on that Traefik. On
k3s, `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: {name: traefik, namespace: kube-system}
spec:
  valuesContent: |-
    ports:
      web:       {transport: {respondingTimeouts: {readTimeout: 0s, writeTimeout: 0s, idleTimeout: 180s}}}
      websecure: {transport: {respondingTimeouts: {readTimeout: 0s, writeTimeout: 0s, idleTimeout: 180s}}}
```

With Traefik 3.7 or newer you can instead lift them for the API route only:
`--set traefik.respondingTimeouts.readTimeout=0s --set traefik.respondingTimeouts.writeTimeout=0s`.

### The Argo UI (platform administrators only)

`install.sh` publishes it by default under `<app host>/argo/` behind **SSO**: people sign in with the identity provider and only
holders of the `platform-admin` role get in (everyone else: 403, there is deliberately no fallback ServiceAccount). Argo evaluates
roles at sign-in only, so its session is short (`sso.sessionExpiry: 1h`). `argo-server` runs `--auth-mode=sso,client`: `client`
stays for apsd's own ServiceAccount token. Behind the scenes the Argo pod maps the identity host to `127.0.0.1` and runs a small
TCP forwarder sidecar (`apsd forward`) to the identity Service (to Traefik with `secret`/`certManager`, so the public certificate answers; with `upstream` it terminates TLS itself), so there is
no DNS or hairpin assumption. Turn it off with `--set argoUI.enabled=false`, or give it a host of its own with `--set
argoUI.host=argo.example.org` (`baseHref` stays `/`; with `tls.mode=certManager` the Certificate covers that name as well). The
chart checks that `argo-workflows.server.baseHref` matches (`argoUI.path` in path mode, `/` in host mode), refuses the `server`
auth mode, and refuses an Argo UI that is not behind SSO. Restrict it further with Middlewares (`argoUI.middlewares`, for example
an IP allow-list) if the address is public.

### External Postgres and object store

```yaml
db:
  mode: external
  external: {url: "postgres://aps:...@db.example.org:5432/aps?sslmode=require"}   # or existingSecret/urlKey
objectStore:
  mode: external
  external: {endpoint: s3.example.org:443, pathStyle: false}
secrets:
  existingSecret: my-aps-credentials     # s3-access-key, s3-secret-key
```

The database needs the `pg_sphere` extension and a direct or session-mode connection (apsd's leader election is an advisory lock).

### Secrets and GitOps

The chart generates `aps-secrets` on the first install and reuses it on every upgrade (`lookup`), and keeps it on uninstall. Renderers
that never talk to a cluster (Argo CD / Flux `helm template` mode) cannot see it and would regenerate it on every sync, which would
lock apsd out of its own database: set `secrets.existingSecret` for GitOps (keys `db-password`, `s3-access-key`, `s3-secret-key`,
`cookie-key`, `cookie-key-previous`; `cookie-key` is the base64 of 32 random bytes). The bundled Zitadel's Secret `aps-zitadel` (masterkey,
config, admin password) is generated and kept the same way and the bootstrap Job writes the OIDC client Secrets; with GitOps
`helm template` mode these also need a stable source.

### What the node-label permission is

The index fetcher runs one pod per node and labels its own node (`aps/index-set=<id>`) when its index files are complete; solve
pods are only scheduled onto labelled nodes. For that its ServiceAccount holds a ClusterRole with exactly `nodes: get, patch`.
Kubernetes RBAC cannot restrict a patch to the pod's own node or to one label; a ValidatingAdmissionPolicy that does is the documented
follow-up (see the header of `templates/index-daemonset.yaml`). If you cannot accept this, set `plateSolve.enabled=false`, or pre-seed the
indexes and the label yourself with `plateSolve.indexSource.mode=preSeeded`.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Solve runs sit in `Pending` | no node is labelled with the index set yet. `kubectl get nodes -L aps/index-set` shows the label, `kubectl describe node <n>` the annotation `aps/index-progress` (`3/13` files, `fetch-failed: ...`, `insufficient-disk: ...`). Fetcher logs: `kubectl -n aps logs ds/aps-index-fetcher`. |
| Pods `Pending` with `unbound immediate PersistentVolumeClaims` | no default StorageClass: `--set global.storageClass=<name>` and re-run (delete the Pending PVCs first if they exist). |
| `ImagePullBackOff` on `ghcr.io/...` | the nodes cannot reach `ghcr.io` (proxy/firewall) or a package is private: pull-secrets via `--set 'global.imagePullSecrets[0].name=<secret>'`, or see the registry section. |
| `helm` reports `pending-install` / `pending-upgrade` | an earlier run was killed. `helm rollback aps -n aps` (earlier revision exists) or `helm uninstall aps -n aps`, then re-run. Nothing was deleted. |
| Install stops with "Argo Workflows CRDs already exist" | another Argo is on the cluster. This chart ships Argo v4 CRDs; installing overwrites them. Re-run with `--adopt-argo-crds` only if that is acceptable. |
| A node keeps an image under two names after switching registries | the kubelet image record gotcha: on that node `crictl rmi <both names>` (or `microk8s ctr images rm`) and let it pull again. Do not mix a registry-qualified and an imported tag of the same image on one node. |
| UI loads but uploads fail with 413 | the size limit is `routes.maxBodySize` (apsd's own, default 2g); a proxy or load balancer in front of Traefik may have a lower one. |
| Uploads or event streams are cut after 60 s | the entrypoint timeouts of a Traefik you reuse: see "Timeouts on a Traefik you reuse". |
| The install stops with "Traefik ... has no entrypoint \"identity\" on port ..." | `--no-traefik-changes` was given, or that Traefik is not Helm-installed / k3s's: make the change it prints (argument + published port), then re-run. See One host name only. |
| Sign-in redirects to `https://<host>:<port>` and nothing answers | the identity port is not mapped: with `tls.mode=upstream` your TLS proxy / tunnel must forward that public port to Traefik's `identity` entrypoint (the installer prints the exact mapping); otherwise the port is not open on the node (firewall). |
| `helm` fails with "a Traefik controller is already running" | a plain `helm install` found another Traefik: add `--set traefik.install=false` (or use `install.sh`, which decides). |
| The install finished but the printed URL does not open | the script checked apsd through a port-forward and warned that the Traefik address does not answer from the installing machine: check DNS/firewall and that Traefik has an address (`kubectl get svc -A -l app.kubernetes.io/name=traefik`), or use the `port-forward` command it prints. |
| The page redirects to the identity provider and the browser cannot resolve `id.<host>` | both names must resolve for the browser: DNS, `/etc/hosts`, or the `sslip.io` default. `*.localhost` and `*.localtest.me` resolve to loopback. |
| Sign-in fails with "sign-ups are closed" | `identity.registration=first-user` and someone already signed in: `--set identity.registration=open`, or sign in with the first account. |
| apsd or argo-server `Pending`/`CreateContainerConfigError` right after install | they wait for the Secrets the bootstrap Job writes: `kubectl -n aps get job -l app.kubernetes.io/component=identity-bootstrap`, `kubectl -n aps logs job -l app.kubernetes.io/component=identity-bootstrap`, `kubectl -n aps get pods -l app.kubernetes.io/name=zitadel`. |
| `helm` fails: `idp.zitadel.configmapConfig.ExternalDomain is ... but the identity host is ...` | the host values disagree: regenerate them with `deploy/helm/identity-values.sh` (or let `install.sh` do it). |
| `helm upgrade` fails on Zitadel's `init`/`setup` Job ("field is immutable") | delete the two finished Jobs first (`kubectl -n aps delete job aps-zitadel-init aps-zitadel-setup`); `install.sh` does this for you. |
| `install.sh` hangs waiting for the Traefik Service | a `LoadBalancer` Service on a cluster without a load balancer never gets an address: `--set traefikController.service.spec.type=NodePort` (and re-run), or install a load balancer. |

## Existing index directories

* `plateSolve.indexes.hostPath` may point at a directory that already holds the index files (for example one you filled by
  hand): the fetcher then verifies each file against the mirror and downloads nothing for complete ones. The directory
  must be owned by root (`chown root:root`, mode 755): the fetcher runs as root without `CAP_DAC_OVERRIDE` and otherwise cannot
  write its `.set-<id>` marker (it logs `cannot write` and retries). Marking a very large set complete takes a while on a
  slow disk because every file is checked.

## Air-gapped and mirrored installs

Everything is a parameter. Mirror the ten images (`apsd web pg-sphere solve extract-meta stack calibrate render reftool index-fetcher`, named
`aps-<name>:<version>`), `rustfs/rustfs:1.0.4` and the Argo images
(`quay.io/argoproj/workflow-controller`, `argocli`, `argoexec`, `argo-workflows-crdinstaller` at the Argo version of the chart) into
your registry, then:

```sh
sh install.sh --chart ./aps-<version>.tgz \
  --set global.imageRegistry=registry.example.org/aps \
  --set objectStore.incluster.image.repository=registry.example.org/mirror/rustfs \
  --set argo-workflows.images.tag=<argo version> ...   # plus the subchart image repositories
```

Download the chart tarball and its `.sha256` from the release, or `helm pull oci://ghcr.io/parsecpipeline/charts/aps --version <v>`, and
pass it with `--chart` (local file) or host both files yourself and use `--chart-url https://mirror/aps-<v>.tgz` (the `.sha256` sibling is
required and verified). For the index files set `plateSolve.indexSource.baseURL=https://mirror.example.org` (an internal mirror with the
same `4100/` layout), or `plateSolve.indexSource.mode=preSeeded` after copying the files onto the nodes yourself. An OCI registry without
TLS needs `--plain-http`.
