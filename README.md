# Astro Pixel Platform: installer

One command installs (or upgrades) the whole platform on a Kubernetes cluster: Argo Workflows, Postgres + pg_sphere, an
object store, the API and web UI, the plate-solving verbs and the per-node astrometry indexes.

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -
```

This copy installs release **0.1.1**. You need `kubectl` pointed at the cluster (a cluster-admin context: the install
creates CRDs and ClusterRoles) and a default StorageClass. Helm is downloaded (checksum-pinned) into a temporary directory
when you do not have it.

No Kubernetes on the machine yet? On a bare Linux host the opt-in `--bootstrap` flag installs single-node k3s first
(pinned version, checksum-verified installer, its bundled Traefik as the ingress) and then the platform, and prints
`http://<host-ip>/`:

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sudo sh -s -- --bootstrap --yes
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/uninstall.sh | sudo sh -s -- --remove-k3s --purge-indexes --yes   # and back
```

Pass options after `-s --`:

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -s -- \
  --namespace aps --set ingress.host=aps.example.org --values my-values.yaml
sh install.sh --help          # every flag
```

When it finishes it prints the address to open and how to create the first user (the first person to register becomes the
owner; afterwards registration is closed). Re-running the same command upgrades in place and keeps your data and secrets.
The astrometry indexes download in the background on each node; the app is usable right away and `kubectl get nodes -L
aps/index-set` shows which nodes can already solve.

Uninstall (your data is kept unless you ask):

```sh
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/uninstall.sh | sh -s -- --yes
curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/uninstall.sh | sh -s -- --yes --purge-data   # also deletes all frames and users
```

Images are published as `ghcr.io/parsecpipeline/aps-<name>` and the chart as `oci://ghcr.io/parsecpipeline/charts/aps`.
Everything (registry, chart source, namespace, storage, ingress, external Postgres/S3) is configurable; the full guide is in
`docs/install.md` of the main repository and ships with each release.
