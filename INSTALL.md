# Installing the Astro Pixel Platform on Kubernetes

One command installs, upgrades and (with a second one) removes the whole platform on any Kubernetes cluster with internet
access: Argo Workflows (the compute engine), Postgres + pg_sphere, an S3 object store, the API (`apsd`), the web UI, the
verbs (plate solve, metadata extraction, reftool) and the per-node astrometry indexes.

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -
```

Options go after `-s --`:

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -s -- \
  --namespace aps --values my-values.yaml --set ingress.host=aps.example.org
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
| `--url URL` | the address printed (and checked) as the one users open, overriding Ingress discovery |
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

It prints `http://<host-ip>/` when it is done (open it, the first account you register becomes the owner).

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
- **Ingress: k3s's bundled Traefik, unchanged.** Traefik is the default IngressClass on k3s and handles the chart's Ingress as it
  is: it does not cap request bodies, does not buffer requests and flushes event streams immediately, so large uploads and the
  live run stream work with no extra annotations (the `ingress-nginx` annotations of the default preset are ignored by Traefik).
  The alternative (disabling Traefik and installing ingress-nginx) means a second download, a second thing to keep patched and an
  ingress-nginx that is being retired upstream, for no benefit here, so it is deliberately not done. `install-smoke` proves the
  large-body and event-stream behaviour through Traefik on every VM run.
- **kubectl afterwards:** `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml` as root, or `sudo k3s kubectl ...`.
- **Removing it again:** `uninstall.sh --remove-k3s` (below).

## Prerequisites

| Need | Why | If missing |
|---|---|---|
| `kubectl` with a context for the cluster | the script talks to the API server | install kubectl; `--context NAME` picks a non-default context |
| Kubernetes 1.27 or newer | chart and Argo requirements | checked, exit 2 |
| Permission to create CRDs, ClusterRoles and (if absent) the namespace | Argo installs CRDs; the index fetcher needs a ClusterRole (below) | checked, exit 2 with the missing verb; use a cluster-admin context |
| A default StorageClass | Postgres (5 Gi) and the object store (10 Gi) use PVCs | warning; `--set global.storageClass=<name>` or use external services |
| An Ingress controller (optional) | a stable address for the UI | warning; the script prints a `kubectl port-forward` command instead |
| hostPath volumes allowed in the namespace | the index fetcher keeps indexes in `/var/lib/aps/astrometry-index` on each node | warning if the namespace enforces Pod Security baseline/restricted |
| Free disk on the nodes that will solve | `wide` preset ~0.3 GB; +4.6 GB for 5200-LITE; ~34 GB for everything | the fetcher refuses to fill a disk (`insufficient-disk` in its node annotation) |
| Internet access from the nodes | image pulls from `ghcr.io`, Argo from `quay.io`, indexes from `data.astrometry.net` | see "Air-gapped and mirrored installs" |
| linux/amd64 nodes | the published images are amd64 only | warning |

Helm 3.14+ is used from your `PATH`; otherwise the script downloads the pinned helm for your OS/CPU into a temporary
directory and verifies it against a SHA-256 table embedded in the script (not fetched from the same host).

## What happens

1. Preflight (all read-only; nothing is changed if it fails): context and server shown, API ready, version, permissions,
   StorageClass, IngressClass, node architectures, Pod Security of the namespace, foreign Argo CRDs, an interrupted Helm release.
2. `helm upgrade --install aps <chart> -n aps --create-namespace --wait --timeout 15m --reset-then-reuse-values ...`.
   No `--atomic`: after an interruption (Ctrl-C, network) you re-run and it resumes with the images already pulled.
3. Waits for `apsd` and the web UI, then polls `/readyz`.
4. Reports the index download progress per node (it never blocks on it unless you pass `--wait-indexes`) and prints the URL,
   the first-user instructions, and the upgrade/uninstall commands.

Exit codes: 0 ok, 2 preflight or usage problem (nothing installed), 3 Helm failed (status and warning events are printed), 4 the
app did not become ready in time.

### The first user

Registration is `first-user` by default: whoever registers first (UI "Create account" or
`curl -X POST <url>/v1/auth/register -H 'content-type: application/json' -d '{"username":"you","password":"..."}'`) owns the
installation; afterwards registration answers 403. Change with `--set apsd.registration=open` (anyone; do not do this on an
Internet-exposed install) or `closed`.

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

By default this removes the release and its WorkflowTemplates and **keeps your data**: the Postgres and object-store volumes, the
Secret `aps-secrets`, the Argo CRDs and the node indexes. Installing again finds them. Without a terminal to ask on the script
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
| `ingress.enabled/className/host` | on, default class, any host | the Ingress; `ingress.host` for a DNS name |
| `ingress.tls.enabled/secretName` | off | TLS on the Ingress (create the Secret yourself or use cert-manager annotations) |
| `plateSolve.enabled` | `true` | per-node indexes + solving; `false` = no DaemonSet, no solve |
| `plateSolve.preset` | `wide` | `telescope` (narrow, 4107-4114) / `wide` (4107-4119, ~0.3 GB) / `custom` (`plateSolve.indexFiles`) |
| `plateSolve.indexes.hostPath` | `/var/lib/aps/astrometry-index` | node-local path |
| `plateSolve.indexes.nodeSelector/tolerations` | none | which nodes hold indexes and serve solves (tainted nodes are skipped unless tolerated) |
| `apsd.registration` | `first-user` | `first-user`, `open`, `closed` |
| `apsd.autoSolve`, `apsd.autoExtractMeta` | `true` | process every upload automatically |
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

### Ingress, TLS and uploads

The default Ingress uses the `ingress-nginx` annotations (`ingress.preset`) for large uploads (`ingress.maxBodySize`, default 2g),
no request buffering and a one-hour timeout, so a multi-gigabyte FITS upload and the live run stream work. For another controller set
`--set ingress.preset=none` and add the equivalent annotations with `ingress.annotations`. Without any Ingress the web service
works through `kubectl -n aps port-forward svc/aps-web 8080:80`.

### The Argo UI (admin only)

Off by default. To expose Argo's own UI under the same Ingress:

```sh
... | sh -s -- --set argoUI.enabled=true --set argo-workflows.server.baseHref=/argo/
kubectl -n aps create token aps-apsd      # a bearer token to paste into the UI login
```

It is reachable by anyone who can reach the Ingress but needs a bearer token (the chart refuses the `server` auth mode, which
would run the UI with the server's own permissions). Treat it as an admin surface; restrict it with network policy or
`argoUI.annotations` (for example IP allow-lists) if the Ingress is public.

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
lock apsd out of its own database: set `secrets.existingSecret` for GitOps.

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
| UI loads but uploads fail with 413 | a proxy in front of the cluster Ingress limits bodies; the chart's own Ingress and web proxy allow `ingress.maxBodySize`. |
| The install finished but the printed URL does not open | the script checked the app through a port-forward and warned that the Ingress address does not answer from the installing machine: check DNS/firewall, or use the `port-forward` command it prints. |

## Ingress controllers, the Argo UI and existing index directories

* The chart's default ingress annotations target ingress-nginx (`ingress.preset: ingress-nginx`). Traefik (k3s, the microk8s
  `ingress` addon) works for the app (uploads and live logs included) and ignores those annotations. The optional admin Argo UI
  (`argoUI.enabled`, path `/argo/`) needs ingress-nginx's `rewrite-target` + regex path: on Traefik that Ingress does not match
  and `/argo/` falls through to the web app. There, leave `argoUI.enabled=false` and expose argo-server another way, for
  example `--set argo-workflows.server.serviceType=NodePort --set argo-workflows.server.serviceNodePort=30746` (plain HTTP,
  client auth: paste `Bearer $(kubectl -n aps create token aps-apsd --duration=24h)` into the UI) or a port-forward.
* `plateSolve.indexes.hostPath` may point at a directory that already holds the index files (for example from an earlier
  hand install): the fetcher then verifies each file against the mirror and downloads nothing for complete ones. The directory
  must be owned by root (`chown root:root`, mode 755): the fetcher runs as root without `CAP_DAC_OVERRIDE` and otherwise cannot
  write its `.set-<id>` marker (it logs `cannot write` and retries). Marking a very large set complete takes a while on a
  slow disk because every file is checked.
* Moving an existing deployment in (database dump + object copy + wiping a hand-installed Argo) is covered by
  `deploy/migrate/README.md`. Install with `--set apsd.replicaCount=0` first: the installer does not wait for the app then.

## Transitional removal checklist

The chart still carries the pre-Argo NATS path for the two verbs not yet ported. As each is ported, delete in this order:

1. `transitional.*` values (`queue`, `apsworker`) and `templates/transitional-queue.yaml` (+ `tests/queue_test.yaml`), the
   `NATS_URL` env entry in `templates/apsd.yaml`, and `nats:<NATS_TAG>` from `deploy/helm/tools.env`.
2. In apsd: the NATS block of `cmd/apsd/main.go`, `internal/queue` (keep `Publisher` only if something still needs it),
   `WithoutQueue` and the `queue.Unavailable` path in `internal/api`, and `cmd/apsworker`.
3. In the `aps-apsd` image: the `apsworker` binary and the `worker/` scripts of every verb that has moved to `verbs/<verb>/`
   (`stack`, `calibrate`, `footprint`, `tile`, `fitsmeta` as they are ported).
4. In the docs: this checklist, the `nats` image in the air-gapped list above, and the HANDOFF "transitional" notes.

## Air-gapped and mirrored installs

Everything is a parameter. Mirror the seven images (`apsd web pg-sphere solve extract-meta reftool index-fetcher`, named
`aps-<name>:<version>`), `rustfs/rustfs:1.0.4`, `nats:2.10.29` (only with the transitional queue) and the Argo images
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
