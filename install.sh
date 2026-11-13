#!/bin/sh
# Astro Pixel Platform installer / upgrader: a thin, safe wrapper around the `aps` Helm chart.
#
#   curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/install.sh | sh -
#   curl -sfL <url>/install.sh | sh -s -- --values my-values.yaml --set routes.host=aps.example.org
#
# Re-running it is the upgrade: `helm upgrade --install` keeps the generated Secret, the Postgres/object-store
# volumes and the node-local astrometry indexes. POSIX sh. Never uses sudo, never edits your kubeconfig, never
# writes outside a mktemp directory (removed on exit).
#
# Bare Linux host with no Kubernetes? The opt-in `--bootstrap` flag installs single-node k3s first (run as root):
#   curl -sfL <url>/install.sh | sudo sh -s -- --bootstrap --yes
# Without the flag this script never installs Kubernetes.
#
# Exit codes: 0 ok | 2 preflight / usage | 3 helm failed | 4 timed out waiting for the app.

# Defaults rewritten at publish time by deploy/ci/package-chart.sh (aps_stamp_defaults); the committed values are the
# "latest published chart" defaults.
DEFAULT_CHART_URL="oci://ghcr.io/parsecpipeline/charts/aps" # @chart-url
DEFAULT_VERSION="0.3.0" # @version

# --bootstrap (opt-in): single-node k3s. The pinned version, and the sha256 of the official installer script AT THAT
# TAG, live here on purpose (a checksum fetched from the host that serves the script proves nothing). The script is
# taken from the k3s repository tag, not from get.k3s.io, because get.k3s.io serves the moving master copy and can
# never match a pinned checksum; it is the same script, and it verifies the k3s binary against the release's own
# checksum file. Another version needs APS_K3S_INSTALL_SHA256 (the sha256 of that tag's install.sh).
PINNED_K3S_VERSION="v1.34.13+k3s1"
K3S_INSTALL_SHA256_PINNED="40b487f0d8ef4f5d1bf422e7bb6228cc7789c40ecc66c5ab067d396bbee9816e"

usage() {
  cat <<'USAGE'
Usage: install.sh [flags]

  --namespace, -n NS     target namespace (default aps; env APS_NAMESPACE)
  --release NAME         Helm release name (default aps; env APS_RELEASE)
  --values, -f FILE      Helm values file, repeatable (env APS_VALUES, space-separated)
  --set K=V              Helm --set, repeatable
  --chart DIR|TGZ        install a local chart directory or packaged chart (env APS_CHART)
  --chart-url URL        https://...tgz (a .sha256 sibling is required and verified) or oci://... (env APS_CHART_URL)
  --version V            chart version (OCI references; env APS_VERSION)
  --helm-version V       pinned helm to download when none >= 3.14 is on PATH (default v3.19.0; env APS_HELM_VERSION)
  --context NAME         kubectl/helm context (env APS_CONTEXT; KUBECONFIG is honoured)
  --timeout DUR          helm --wait / readiness budget (default 15m; env APS_TIMEOUT)
  --wait-indexes[=DUR]   also wait (default 30m) for every eligible node to hold the astrometry indexes;
                         without it the install only reports index progress and never blocks on it
  --url URL              the address users will open, overriding Traefik discovery (env APS_URL)
  --plain-http           the OCI chart registry speaks plain HTTP (a local/lab registry; env APS_PLAIN_HTTP=1)
  --bootstrap            bare Linux host with no reachable Kubernetes: first install single-node k3s (pinned version,
                         checksum-verified installer, its bundled Traefik is the ingress), wait for the node, use
                         /etc/rancher/k3s/k3s.yaml, then install normally. Needs root (curl ... | sudo sh -s -- --bootstrap).
                         A reachable cluster is left alone. Opt-in: without it Kubernetes is never installed (env APS_BOOTSTRAP=1)
  --k3s-version V        k3s release for --bootstrap (default pinned v1.34.13+k3s1; another version needs
                         APS_K3S_INSTALL_SHA256 = sha256 of that tag's install.sh; env APS_K3S_VERSION)
  --yes, -y              do not ask for confirmation (env APS_ASSUME_YES=1)
  --dry-run              pass --dry-run to helm (nothing is installed)
  --no-identity-values   do not generate the identity host values (routes.host, identity.host, the Zitadel external domain and the
                         Argo SSO settings): you pass them yourself (deploy/helm/identity-values.sh writes them; see docs/install.md)
  --adopt-argo-crds      proceed although Argo Workflows CRDs already exist on the cluster (they will be
                         overwritten with this chart's Argo version)
  --help, -h             this text

Names: the app needs a public host name (the identity provider redirects browsers back to it) and the bundled identity
provider its own, next to it (id.<host>). Give one with --set routes.host=aps.example.org (and --set routes.port=8080 /
tls.mode=... when they apply); without one this script uses aps.<node address>.sslip.io (public wildcard DNS) when it can find
the address. Upgrades keep the host the release already has.

Traefik: the app is published through Traefik (IngressRoutes). Before installing, this script looks for a running Traefik
(its CRDs plus a controller): found -> it is reused (traefik.install=false), none -> the chart installs one (true). The
decision is printed. Force it with --set traefik.install=true|false.

Exit codes: 0 ok, 2 preflight or usage, 3 helm failed, 4 timed out waiting for the app.
USAGE
}

# ---------------------------------------------------------------- small helpers
say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { # die CODE MSG...
  _c="$1"; shift
  printf '%s: %s\n' "${PROG:-install.sh}" "$*" >&2
  exit "$_c"
}

# sq STRING: single-quote STRING for safe re-use with eval.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Seconds from 90s | 15m | 2h | 45 (bare = seconds).
dur_secs() {
  case "$1" in
    *[!0-9smh]*|"") return 1 ;;
    *s) _n="${1%s}"; _m=1 ;;
    *m) _n="${1%m}"; _m=60 ;;
    *h) _n="${1%h}"; _m=3600 ;;
    *) _n="$1"; _m=1 ;;
  esac
  case "$_n" in ""|*[!0-9]*) return 1 ;; esac
  echo $((_n * _m))
}

TMP=""
PF_PID=""
cleanup() {
  [ -z "$PF_PID" ] || kill "$PF_PID" 2>/dev/null
  [ -z "$TMP" ] || rm -rf "$TMP"
}

# ---------------------------------------------------------------- argument parsing
NS="${APS_NAMESPACE:-aps}"
REL="${APS_RELEASE:-aps}"
CHART="${APS_CHART:-}"
CHART_URL="${APS_CHART_URL:-}"
VERSION="${APS_VERSION:-$DEFAULT_VERSION}"
HELM_VERSION="${APS_HELM_VERSION:-}"   # default: PINNED_HELM_VERSION (see ensure_helm)
CTX="${APS_CONTEXT:-}"
TIMEOUT="${APS_TIMEOUT:-15m}"
URL_OVERRIDE="${APS_URL:-}"
ASSUME_YES="${APS_ASSUME_YES:-}"
WAIT_INDEXES=0
DRY_RUN=""
ADOPT_CRDS=""
NO_IDENTITY_VALUES=""
PLAIN_HTTP="${APS_PLAIN_HTTP:-}"
BOOTSTRAP="${APS_BOOTSTRAP:-}"
K3S_VERSION="${APS_K3S_VERSION:-}"
K3S_KUBECONFIG="${APS_K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"   # APS_K3S_KUBECONFIG is a test seam
BOOT_WAIT="${APS_BOOTSTRAP_WAIT:-300}"                                # seconds per bootstrap wait (test seam)
BOOTSTRAPPED=""                                                       # k3s-installed | k3s-existing
HELM_USER=""   # user -f/--set flags, shell-quoted, in the order given
HELM_BASE_URL="${APS_HELM_BASE_URL:-https://get.helm.sh}"
TTY_DEV="${APS_TTY:-/dev/tty}"   # APS_TTY is a test seam
POLL="${APS_POLL_INTERVAL:-2}"
UNINSTALL_URL="https://raw.githubusercontent.com/parsecpipeline/aps-install/main/uninstall.sh"

add_user() { HELM_USER="$HELM_USER $(sq "$1")"; }

parse_args() {
  for _f in ${APS_VALUES:-}; do add_user "-f"; add_user "$_f"; done
  while [ $# -gt 0 ]; do
    case "$1" in
      --namespace|-n) [ $# -ge 2 ] || die 2 "$1 needs a value"; NS="$2"; shift 2 ;;
      --release) [ $# -ge 2 ] || die 2 "--release needs a value"; REL="$2"; shift 2 ;;
      --values|-f) [ $# -ge 2 ] || die 2 "$1 needs a value"; add_user "-f"; add_user "$2"; shift 2 ;;
      --set) [ $# -ge 2 ] || die 2 "--set needs a value"; add_user "--set"; add_user "$2"; shift 2 ;;
      --chart) [ $# -ge 2 ] || die 2 "--chart needs a value"; CHART="$2"; shift 2 ;;
      --chart-url) [ $# -ge 2 ] || die 2 "--chart-url needs a value"; CHART_URL="$2"; shift 2 ;;
      --version) [ $# -ge 2 ] || die 2 "--version needs a value"; VERSION="$2"; shift 2 ;;
      --helm-version) [ $# -ge 2 ] || die 2 "--helm-version needs a value"; HELM_VERSION="$2"; shift 2 ;;
      --context) [ $# -ge 2 ] || die 2 "--context needs a value"; CTX="$2"; shift 2 ;;
      --timeout) [ $# -ge 2 ] || die 2 "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
      --url) [ $# -ge 2 ] || die 2 "--url needs a value"; URL_OVERRIDE="$2"; shift 2 ;;
      --wait-indexes) WAIT_INDEXES=1800; shift ;;
      --wait-indexes=*) WAIT_INDEXES="$(dur_secs "${1#*=}")" || die 2 "bad --wait-indexes duration: ${1#*=}"; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --no-identity-values) NO_IDENTITY_VALUES=1; shift ;;
      --adopt-argo-crds) ADOPT_CRDS=1; shift ;;
      --plain-http) PLAIN_HTTP=1; shift ;;
      --bootstrap) BOOTSTRAP=1; shift ;;
      --k3s-version) [ $# -ge 2 ] || die 2 "--k3s-version needs a value"; K3S_VERSION="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) usage >&2; die 2 "unknown argument: $1" ;;
    esac
  done
  TIMEOUT_S="$(dur_secs "$TIMEOUT")" || die 2 "bad --timeout duration: $TIMEOUT (use 90s, 15m, 1h)"
  if [ -n "$BOOTSTRAP" ] && [ -n "$CTX" ]; then
    die 2 "--bootstrap installs a new local k3s cluster and cannot be combined with --context (that names an existing cluster)"
  fi
}

# ---------------------------------------------------------------- kubectl / helm wrappers
# stdin is detached: when piped from curl, stdin IS this script and no child may read it.
kc() { kubectl ${CTX:+--context "$CTX"} "$@" </dev/null; }
hm() { "$HELM" ${CTX:+--kube-context "$CTX"} "$@" </dev/null; }

# ---------------------------------------------------------------- helm bootstrap
# >>> shared:helm-bootstrap (byte-identical in install.sh and uninstall.sh; a test enforces it)
# Pinned helm (used only when no helm >= 3.14 is on PATH). The sha256 values are from get.helm.sh and live HERE on
# purpose: a checksum fetched from the same host as the binary proves nothing.
PINNED_HELM_VERSION="v3.19.0"
HELM_SHA256_linux_amd64="a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496"
HELM_SHA256_linux_arm64="440cf7add0aee27ebc93fada965523c1dc2e0ab340d4348da2215737fc0d76ad"
HELM_SHA256_darwin_amd64="09a108c0abda42e45af172be65c49125354bf7cd178dbe10435e94540e49c7b9"
HELM_SHA256_darwin_arm64="31513e1193da4eb4ae042eb5f98ef9aca7890cfa136f4707c8d4f70e2115bef6"

mk_tmp() {
  [ -n "$TMP" ] || TMP="$(mktemp -d "${TMPDIR:-/tmp}/aps-install.XXXXXX")" || die 2 "cannot create a temporary directory"
}

helm_ok() { # helm_ok BIN: v3 >= 3.14
  _v="$("$1" version --template '{{.Version}}' 2>/dev/null </dev/null)" || return 1
  _v="${_v#v}"
  _maj="${_v%%.*}"; _rest="${_v#*.}"; _min="${_rest%%.*}"
  case "$_maj$_min" in ""|*[!0-9]*) return 1 ;; esac
  [ "$_maj" -eq 3 ] && [ "$_min" -ge 14 ]
}

fetch() { # fetch URL OUTFILE
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1" </dev/null
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1" </dev/null
  else die 2 "neither curl nor wget is available to download $1"; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/.*= *//'
  else die 2 "no sha256 tool (sha256sum, shasum or openssl) available to verify downloads"; fi
}

ensure_helm() {
  HELM_VERSION="${HELM_VERSION:-$PINNED_HELM_VERSION}"
  HELM=""
  if command -v helm >/dev/null 2>&1 && helm_ok helm; then HELM="$(command -v helm)"; return 0; fi
  _os="$(uname -s | tr 'A-Z' 'a-z')"
  case "$_os" in linux|darwin) ;; *) die 2 "unsupported OS \"$_os\" for the helm download; install helm >= 3.14 yourself" ;; esac
  _arch="$(uname -m)"
  case "$_arch" in x86_64|amd64) _arch=amd64 ;; aarch64|arm64) _arch=arm64 ;; *) die 2 "unsupported CPU \"$_arch\" for the helm download; install helm >= 3.14 yourself" ;; esac
  _want="${APS_HELM_SHA256:-}"
  if [ -z "$_want" ]; then
    [ "$HELM_VERSION" = "$PINNED_HELM_VERSION" ] \
      || die 2 "no embedded checksum for helm $HELM_VERSION (only $PINNED_HELM_VERSION); install helm yourself or set APS_HELM_SHA256 to the tarball's sha256"
    eval "_want=\$HELM_SHA256_${_os}_${_arch}"
  fi
  mk_tmp
  _tgz="$TMP/helm.tgz"
  say "helm >= 3.14 not found: downloading helm $HELM_VERSION ($_os/$_arch) to a temporary directory"
  fetch "$HELM_BASE_URL/helm-$HELM_VERSION-$_os-$_arch.tar.gz" "$_tgz" || die 2 "download of helm $HELM_VERSION failed"
  [ "$(sha256_of "$_tgz")" = "$_want" ] || die 2 "checksum mismatch for the downloaded helm tarball; refusing to run it"
  mkdir -p "$TMP/helm-bin" && tar -xzf "$_tgz" -C "$TMP/helm-bin" || die 2 "cannot unpack the helm tarball"
  HELM="$TMP/helm-bin/$_os-$_arch/helm"
  [ -x "$HELM" ] || die 2 "the helm tarball did not contain $_os-$_arch/helm"
}
# <<< shared:helm-bootstrap

# ---------------------------------------------------------------- --bootstrap: single-node k3s (opt-in)
cluster_reachable() { command -v kubectl >/dev/null 2>&1 && kc get --raw /readyz >/dev/null 2>&1; }

# Point this run at k3s's kubeconfig (a root-only file; the installer is expected to run as root for --bootstrap).
use_k3s_kubeconfig() {
  KUBECONFIG="$K3S_KUBECONFIG"; export KUBECONFIG
  case ":$PATH:" in *:/usr/local/bin:*) ;; *) PATH="$PATH:/usr/local/bin"; export PATH ;; esac
}

# poll_until SECONDS CMD...: run CMD every $POLL seconds until it succeeds (0) or SECONDS elapsed (1).
poll_until() {
  _pu_end=$(( $(date +%s) + $1 )); shift
  while :; do
    "$@" && return 0
    [ "$(date +%s)" -lt "$_pu_end" ] || return 1
    sleep "$POLL"
  done
}
have_nodes() { [ -n "$(kc get nodes -o name 2>/dev/null)" ]; }
have_traefik() { [ -n "$(kc -n kube-system get deploy traefik -o name 2>/dev/null)" ]; }
have_traefik_crd() { kc get crd ingressroutes.traefik.io -o name >/dev/null 2>&1; }
have_default_sc() { case "$(kc get storageclass -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null)" in *"|true"*) return 0 ;; *) return 1 ;; esac; }

# Something already listening on 80/443 would leave k3s's bundled Traefik (host ports 80/443) Pending.
check_ports_free() {
  command -v ss >/dev/null 2>&1 || return 0
  _busy="$(ss -ltn 2>/dev/null </dev/null | awk '{print $4}' | grep -E '[:.](80|443)$' | sort -u | tr '\n' ' ')"
  [ -z "$_busy" ] || die 2 "ports 80/443 are already in use on this host (listening: $_busy). k3s's Traefik ingress needs them. Stop whatever listens there (a web server, another cluster's ingress) and re-run --bootstrap."
}

install_k3s() {
  _v="${K3S_VERSION:-$PINNED_K3S_VERSION}"
  _want="${APS_K3S_INSTALL_SHA256:-}"
  if [ -z "$_want" ]; then
    [ "$_v" = "$PINNED_K3S_VERSION" ] \
      || die 2 "no embedded checksum for the k3s $_v installer (only $PINNED_K3S_VERSION); set APS_K3S_INSTALL_SHA256 to the sha256 of that tag's install.sh"
    _want="$K3S_INSTALL_SHA256_PINNED"
  fi
  _url="${APS_K3S_INSTALL_URL:-https://raw.githubusercontent.com/k3s-io/k3s/$(printf '%s' "$_v" | sed 's/+/%2B/g')/install.sh}"
  mk_tmp
  say "Installing single-node k3s $_v (official installer script, sha256-verified)"
  fetch "$_url" "$TMP/k3s-install.sh" || die 2 "download of the k3s installer from $_url failed"
  [ "$(sha256_of "$TMP/k3s-install.sh")" = "$_want" ] \
    || die 2 "checksum mismatch for the downloaded k3s installer; refusing to run it"
  # The Traefik that k3s bundles is the ingress (see docs/install.md); nothing else is changed from the defaults.
  INSTALL_K3S_VERSION="$_v" sh "$TMP/k3s-install.sh" </dev/null \
    || die 2 "the k3s installer failed (see its output above). Nothing else was installed; fix the cause and re-run, or remove a half-installed k3s with k3s-uninstall.sh"
}

bootstrap() {
  if cluster_reachable; then
    say "--bootstrap: a Kubernetes cluster is already reachable (context $(kubectl config current-context 2>/dev/null </dev/null || echo '?')); not installing k3s"
    return 0
  fi
  # A k3s that is already installed (an earlier --bootstrap): use its kubeconfig, never reinstall over it.
  if [ -r "$K3S_KUBECONFIG" ] || command -v k3s >/dev/null 2>&1; then
    use_k3s_kubeconfig
    say "--bootstrap: k3s is already installed on this host; waiting for its API (not reinstalling)"
    poll_until "$BOOT_WAIT" cluster_reachable \
      || die 2 "k3s is installed but its API did not answer within ${BOOT_WAIT}s (kubeconfig $K3S_KUBECONFIG). Start it (systemctl start k3s) or look at: journalctl -u k3s. --bootstrap does not reinstall over an existing k3s."
    BOOTSTRAPPED=k3s-existing
  else
    [ "$(uname -s)" = Linux ] || die 2 "--bootstrap installs k3s and only supports Linux hosts (this is $(uname -s)). Use any existing Kubernetes cluster instead."
    [ "${APS_TEST_UID:-$(id -u)}" = 0 ] || die 2 "--bootstrap installs k3s system-wide and needs root. Re-run as root, for example: curl -sfL <url>/install.sh | sudo sh -s -- --bootstrap [flags]"
    check_ports_free
    _arch="$(uname -m)"
    case "$_arch" in x86_64|amd64) ;; *) warn "this host is $_arch: the published images are linux/amd64 only, pods will not start here." ;; esac
    if [ -z "$ASSUME_YES" ] && ( : <"$TTY_DEV" ) 2>/dev/null; then
      printf 'No Kubernetes cluster is reachable. Install single-node k3s %s on this host? [y/N] ' "${K3S_VERSION:-$PINNED_K3S_VERSION}" >&2
      _ans=""
      read -r _ans <"$TTY_DEV" || _ans=""
      case "$_ans" in y|Y|yes|YES) ;; *) die 2 "aborted by the user" ;; esac
    fi
    install_k3s
    use_k3s_kubeconfig
    BOOTSTRAPPED=k3s-installed
  fi
  command -v kubectl >/dev/null 2>&1 || die 2 "k3s is installed but no kubectl was found on PATH (expected /usr/local/bin/kubectl)"
  say "Waiting for the k3s node to become Ready (up to ${BOOT_WAIT}s)"
  poll_until "$BOOT_WAIT" have_nodes || die 2 "no Kubernetes node registered within ${BOOT_WAIT}s. Look at: journalctl -u k3s"
  kc wait --for=condition=Ready node --all --timeout="${BOOT_WAIT}s" >/dev/null 2>&1 \
    || die 2 "the k3s node did not become Ready within ${BOOT_WAIT}s. Look at: kubectl get nodes; journalctl -u k3s"
  # Traefik and the default StorageClass are deployed by k3s asynchronously; the chart needs both. A miss is not fatal
  # (the install still works, with a warning from the preflight) but waiting here saves a confusing first-run delay.
  poll_until "$BOOT_WAIT" have_default_sc || warn "k3s has no default StorageClass yet; volumes may stay Pending"
  if poll_until "$BOOT_WAIT" have_traefik; then
    kc -n kube-system rollout status deploy/traefik --timeout="${BOOT_WAIT}s" >/dev/null 2>&1 \
      || warn "k3s's Traefik ingress is not ready yet; the UI may take a minute longer to answer"
  fi
  poll_until "$BOOT_WAIT" have_traefik_crd || warn "k3s has not registered Traefik's CRDs yet"
  say "k3s is ready (kubeconfig $K3S_KUBECONFIG)"
}

# The host's primary address, for the final URL when no Traefik address was found (bootstrap only).
host_ip() {
  _hip="${APS_HOST_IP:-}"   # explicit override (also the test seam)
  if [ -z "$_hip" ] && command -v hostname >/dev/null 2>&1; then _hip="$(hostname -I 2>/dev/null </dev/null | awk '{print $1}')"; fi
  if [ -z "$_hip" ] && command -v ip >/dev/null 2>&1; then
    _hip="$(ip -4 route get 1.1.1.1 2>/dev/null </dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  fi
  printf '%s' "$_hip"
}

# ---------------------------------------------------------------- preflight
confirm() {
  [ -z "$ASSUME_YES" ] || return 0
  # No usable terminal (CI, `curl | sh` from a script, setsid): the user asked for this, proceed.
  if ! ( : <"$TTY_DEV" ) 2>/dev/null; then return 0; fi
  printf 'Install/upgrade release "%s" in namespace "%s" on context "%s"%s? [y/N] ' "$REL" "$NS" "$CUR_CTX" "${SERVER:+ ($SERVER)}" >&2
  _ans=""
  read -r _ans <"$TTY_DEV" || _ans=""
  case "$_ans" in y|Y|yes|YES) return 0 ;; *) die 2 "aborted by the user" ;; esac
}

preflight() {
  command -v kubectl >/dev/null 2>&1 || die 2 "kubectl was not found on PATH. Install kubectl (https://kubernetes.io/docs/tasks/tools/) and point it at your cluster."

  CUR_CTX="${CTX:-$(kubectl config current-context 2>/dev/null </dev/null)}"
  [ -n "$CUR_CTX" ] || die 2 "no current kubectl context. Select one (kubectl config use-context NAME) or pass --context."
  SERVER="$(kc config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)"
  say "Cluster: context $CUR_CTX${SERVER:+ ($SERVER)}"

  if ! _out="$(kc get --raw /readyz 2>&1)"; then
    die 2 "the Kubernetes API of context \"$CUR_CTX\" is not reachable or not ready (kubectl get --raw /readyz failed: $_out)"
  fi

  confirm

  _ver="$(kc get --raw /version 2>/dev/null)"
  _minor="$(printf '%s' "$_ver" | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' | head -n 1)"
  _major="$(printf '%s' "$_ver" | sed -n 's/.*"major": *"\([0-9]*\).*/\1/p' | head -n 1)"
  if [ -n "$_minor" ] && [ "${_major:-1}" = 1 ] && [ "$_minor" -lt 30 ]; then
    die 2 "Kubernetes 1.$_minor is too old: this chart needs 1.30 or newer (the bundled Zitadel, native sidecars)"
  fi

  # Permissions: cluster-scoped objects are installed (CRDs, ClusterRoles); a namespace only when it does not exist.
  for _res in customresourcedefinitions clusterroles; do
    [ "$(kc auth can-i create "$_res" 2>/dev/null)" = yes ] \
      || die 2 "your credentials may not create $_res (kubectl auth can-i create $_res: no). Argo Workflows installs CRDs and ClusterRoles; ask a cluster administrator or use a cluster-admin context."
  done
  if kc get namespace "$NS" >/dev/null 2>&1; then
    _pss="$(kc get namespace "$NS" -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"
    case "$_pss" in
      baseline|restricted) warn "namespace $NS enforces the \"$_pss\" Pod Security level: the per-node index fetcher (root, hostPath) will be rejected. Use a namespace without enforcement or set plateSolve.enabled=false." ;;
    esac
  else
    [ "$(kc auth can-i create namespaces 2>/dev/null)" = yes ] \
      || die 2 "namespace $NS does not exist and your credentials may not create it. Create it first or ask an administrator."
  fi

  # Storage: Postgres and the object store need PVCs.
  _sc="$(kc get storageclass -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null)"
  case "$HELM_USER" in *global.storageClass=?*) ;; *)
    case "$_sc" in
      *"|true"*) ;;
      "") warn "no StorageClass exists on this cluster: the Postgres and object-store volumes will stay Pending. Install a storage provisioner, or use external services (see docs/install.md)." ;;
      *) warn "no DEFAULT StorageClass: volumes will stay Pending unless you pass --set global.storageClass=<one of: $(printf '%s' "$_sc" | sed 's/|.*//' | tr '\n' ' ')>" ;;
    esac ;;
  esac

  # Architectures: images are published for linux/amd64.
  _arch="$(kc get nodes -o 'jsonpath={.items[*].status.nodeInfo.architecture}' 2>/dev/null)"
  for _a in $_arch; do
    [ "$_a" = amd64 ] || { warn "node architecture \"$_a\" found: the published images are linux/amd64 only; pods on those nodes will not start."; break; }
  done

  # Foreign Argo Workflows CRDs: a different Argo under a foreign controller is how clusters break. install.sh marks
  # the CRDs it installed with the Helm ownership annotations (after a successful install), so a re-run or a
  # reinstall after uninstall.sh (CRDs are kept) is recognised as ours.
  if _owner="$(kc get crd workflows.argoproj.io -o 'jsonpath={.metadata.annotations.meta\.helm\.sh/release-name}|{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)"; then
    if [ "$_owner" != "$REL|$NS" ] && [ -z "$ADOPT_CRDS" ]; then
      die 2 "Argo Workflows CRDs (workflows.argoproj.io) already exist and were not installed by release \"$REL\" in namespace \"$NS\". Installing would overwrite them with this chart's Argo version and may break another Argo on this cluster. Re-run with --adopt-argo-crds if that is what you want."
    fi
  fi
}

# ---------------------------------------------------------------- Traefik
# The app is published through Traefik IngressRoutes. A Traefik that is already running (CRDs + a controller) is reused;
# otherwise the chart installs one. Helm cannot make that decision (a subchart condition cannot `lookup`), so it is made
# here and handed to the chart as a generated values file that comes BEFORE the user's -f files (their values win), unless
# the user passed --set traefik.install=... (which wins over everything).
traefik_controllers() { # "namespace/name" of every Traefik Deployment/DaemonSet on the cluster
  kc get deploy,ds -A -l app.kubernetes.io/name=traefik -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null
}

resolve_traefik() {
  TRAEFIK_VALUES=""
  case "$HELM_USER" in
    *traefik.install=*) say "Traefik: traefik.install was given on the command line; using it as is"; return 0 ;;
  esac
  _ctl="$(traefik_controllers)"
  _first="$(printf '%s\n' "$_ctl" | head -n 1)"
  if printf '%s\n' "$_ctl" | grep -qxF "$NS/$REL-traefik"; then
    _ti=true
    say "Traefik: $NS/$REL-traefik belongs to this release; keeping it (traefik.install=true)"
  elif [ -n "$_first" ] && have_traefik_crd; then
    _ti=false
    say "Traefik: found $_first with its CRDs; reusing it (traefik.install=false), nothing will be installed"
  elif [ -n "$_first" ]; then
    _ti=true
    warn "Traefik runs here ($_first) but its CRDs (ingressroutes.traefik.io) are missing (is the kubernetesCRD provider disabled?). Installing the chart's own Traefik, which brings the CRDs; set --set traefik.install=false to use yours once the CRDs exist."
  else
    _ti=true
    if have_traefik_crd; then say "Traefik: its CRDs exist but no controller is running; the chart installs one (traefik.install=true)"
    else say "Traefik: none found; the chart installs Traefik (traefik.install=true)"; fi
  fi
  mk_tmp
  TRAEFIK_VALUES="$TMP/traefik-install.yaml"
  printf 'traefik:\n  install: %s\n' "$_ti" > "$TRAEFIK_VALUES"
}

# ---------------------------------------------------------------- identity values
# The Zitadel and Argo subcharts take the identity host, the issuer and the Argo redirect URL as plain values that a
# parent chart cannot template, so they repeat routes.host. This function writes them from ONE host (templates/validate.yaml
# fails the render when they disagree). deploy/helm/identity-values.sh runs this same function for Helm users.
# BEGIN identity-values
# aps_identity_values HOST ID_HOST PORT TLS ARGO TARGET RELEASE -> values YAML on stdout.
#   ID_HOST: "" = id.HOST; NAME:PORT serves the identity provider on another port (of HOST itself, or another name). PORT: public port when not 80/443 ("" = default). TLS: 1 = https at Traefik, upstream = https in front of Traefik (Traefik sees plain HTTP), 0 = http. ARGO: path | host=NAME | off.
#   TARGET: with TLS, where the Argo pod's identity forwarder connects so the public certificate answers (default RELEASE-traefik:443).
aps_identity_values() {
  _iv_host="$1"; _iv_idhost="${2:-id.$1}"; _iv_port="$3"; _iv_tls="${4:-0}"; _iv_argo="${5:-path}"; _iv_target="$6"; _iv_rel="${7:-aps}"
  _iv_scheme=http; _iv_def=80; _iv_secure=false
  if [ "$_iv_tls" = 1 ] || [ "$_iv_tls" = upstream ]; then _iv_scheme=https; _iv_def=443; _iv_secure=true; fi
  _iv_pub="${_iv_port:-$_iv_def}"
  _iv_suffix=""; [ -z "$_iv_port" ] || _iv_suffix=":$_iv_port"
  # the identity provider's own port (NAME:PORT) replaces the app's for it
  _iv_idsuffix="$_iv_suffix"; _iv_idpub="$_iv_pub"; _iv_idname="$_iv_idhost"; _iv_own=""
  case "$_iv_idhost" in *:*) _iv_own="${_iv_idhost##*:}"; _iv_idname="${_iv_idhost%:*}"; _iv_idsuffix=":$_iv_own"; _iv_idpub="$_iv_own" ;; esac
  [ -n "$_iv_target" ] || _iv_target="$_iv_rel-traefik:443"
  printf '# generated by aps_identity_values for %s\n' "$_iv_host"
  printf 'routes:\n  host: "%s"\n' "$_iv_host"
  [ -z "$_iv_port" ] || printf '  port: "%s"\n' "$_iv_port"
  printf 'identity:\n  host: "%s"\n' "$_iv_idhost"
  printf 'idp:\n  zitadel:\n    configmapConfig:\n      ExternalDomain: "%s"\n      ExternalPort: %s\n      ExternalSecure: %s\n' "$_iv_idname" "$_iv_idpub" "$_iv_secure"
  if [ -n "$_iv_own" ]; then
    # the Traefik this chart installs gets an entrypoint on that port (a reused Traefik needs one added: docs/install.md)
    _iv_cport="$_iv_own"; [ "$_iv_own" -ge 1024 ] || _iv_cport=$((10000 + _iv_own))
    printf 'traefikController:\n  ports:\n    identity:\n      port: %s\n      exposedPort: %s\n      protocol: TCP\n      expose: {default: true}\n' "$_iv_cport" "$_iv_own"
  fi
  [ "$_iv_argo" != off ] || return 0
  case "$_iv_argo" in
    path)
      _iv_abase="$_iv_scheme://$_iv_host$_iv_suffix/argo"; _iv_bh="/argo/"
      printf 'argoUI:\n  enabled: true\n  path: /argo/\n' ;;
    host=*)
      _iv_ah="${_iv_argo#host=}"; _iv_abase="$_iv_scheme://$_iv_ah$_iv_suffix"; _iv_bh="/"
      printf 'argoUI:\n  enabled: true\n  host: "%s"\n' "$_iv_ah" ;;
    *) echo "aps_identity_values: ARGO must be path, host=NAME or off" >&2; return 2 ;;
  esac
  # The forwarder listens on the public port of the identity host (127.0.0.1 inside the Argo pod) and forwards to the Zitadel
  # Service, or with TLS to Traefik so that the public certificate answers. A port below 1024 needs the unprivileged-port sysctl.
  # With TLS upstream the cluster holds no certificate: the forwarder terminates TLS itself (self-signed, loopback only) and
  # Argo skips verifying it; the hop to Zitadel is plain HTTP.
  _iv_ftls=""; _iv_skip=""
  if [ "$_iv_tls" = 1 ]; then _iv_fwd="$_iv_target"; else _iv_fwd="$_iv_rel-zitadel:8080"; fi
  if [ "$_iv_tls" = upstream ]; then _iv_ftls='"--tls", '; _iv_skip="      insecureSkipVerify: true\n"; fi
  printf 'argo-workflows:\n  server:\n    baseHref: %s\n    authModes: [sso, client]\n' "$_iv_bh"
  printf '    sso:\n      enabled: true\n      issuer: "%s://%s%s"\n      redirectUrl: "%s/oauth2/callback"\n%b' "$_iv_scheme" "$_iv_idname" "$_iv_idsuffix" "$_iv_abase" "$_iv_skip"
  printf '    # The identity host names Zitadel; inside this pod it must reach it whatever DNS says: map it to localhost and run a\n'
  printf '    # TCP forwarder sidecar (a native sidecar: an init container that keeps running) from the apsd image, which renders\n'
  printf '    # through tpl from global values.\n'
  printf '    hostAliases:\n      - ip: 127.0.0.1\n        hostnames: ["%s"]\n' "$_iv_idname"
  if [ "$_iv_idpub" -lt 1024 ]; then
    printf '    podSecurityContext:\n      sysctls:\n        - {name: net.ipv4.ip_unprivileged_port_start, value: "0"}\n'
  fi
  printf '    extraInitContainers:\n      - name: identity-forward\n'
  printf "        image: '{{ include \"aps.globalApsdImage\" . }}'\n"
  printf "        imagePullPolicy: '{{ .Values.global.imagePullPolicy }}'\n"
  printf '        restartPolicy: Always\n        command: ["/app/apsd", "forward", %s":%s", "%s"]\n' "$_iv_ftls" "$_iv_idpub" "$_iv_fwd"
  printf '        securityContext: {runAsNonRoot: true, runAsUser: 1000, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}\n'
}
# END identity-values

# ---------------------------------------------------------------- identity host
# set_value KEY: the value of `--set KEY=...` the user passed ("" if none; the last one wins).
set_value() {
  printf '%s' "$HELM_USER" | tr ' ' '\n' | sed -n "s/^'$1=\(.*\)'\$/\1/p" | tail -n 1
}

# release_value TOP KEY: TOP.KEY from the installed release's user-supplied values ("" if none).
release_value() {
  hm get values "$REL" -n "$NS" -o yaml 2>/dev/null | awk -v top="$1" -v key="$2" '
    /^[^ #]/ { in_top = ($0 == top ":"); next }
    in_top && $1 == key ":" { sub(/^[^:]*: */, ""); gsub(/^"|"$/, ""); print; exit }'
}

# default_host: aps.<address>.sslip.io from the address this cluster is reached at, or fail (empty output).
default_host() {
  _dip=""
  [ -z "$BOOTSTRAPPED" ] || _dip="$(host_ip)"
  [ -n "$_dip" ] || _dip="$(kc get svc -A -l app.kubernetes.io/name=traefik -o 'jsonpath={range .items[*]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep . | head -n 1)"
  if [ -z "$_dip" ]; then
    _ips="$(kc get nodes -o 'jsonpath={range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null | grep .)"
    [ "$(printf '%s\n' "$_ips" | grep -c .)" = 1 ] && _dip="$_ips"
  fi
  [ -z "$_dip" ] || printf 'aps.%s.sslip.io' "$_dip"
}

# The identity host values (see aps_identity_values): generated into a file placed before the user's -f, so what the user sets wins.
resolve_identity() {
  ID_VALUES=""; ID_PORT=""; PUBLIC_HOST=""
  if [ -n "$NO_IDENTITY_VALUES" ]; then say "Identity: --no-identity-values; the identity host values are yours"; return 0; fi
  case "$HELM_USER" in *ExternalDomain=*|*identity.mode=external*) say "Identity: given on the command line; using it as is"; return 0 ;; esac
  _h="$(set_value routes.host)"; _p="$(set_value routes.port)"; _tm="$(set_value tls.mode)"
  if [ -z "$_h" ] && [ -n "$URL_OVERRIDE" ]; then
    # --url http://host[:port] says it all; an IP address cannot carry the identity provider's own name, so it becomes
    # aps.<ip>.sslip.io (the URL is still where this machine reaches the cluster)
    _u="${URL_OVERRIDE#*://}"; _u="${_u%%/*}"
    _h="${_u%%:*}"; case "$_u" in *:*) _p="${_u##*:}" ;; esac
    case "$URL_OVERRIDE" in https://*) [ -n "$_tm" ] || _tm=secret ;; esac
    case "$_h" in *[!0-9.]*|"") ;; *.*.*.*) _h="aps.$_h.sslip.io" ;; esac
  fi
  if [ -z "$_h" ] && [ -n "$(release_value identity host)" ]; then
    ID_PORT="$(release_value routes port)"
    PUBLIC_HOST="$(release_value routes host)"
    say "Identity: keeping the host of release \"$REL\" ($(release_value routes host))"
    return 0
  fi
  if [ -z "$_h" ]; then
    _h="$(default_host)"
    [ -n "$_h" ] || die 2 "cannot tell which host name to serve the app and its identity provider on. Pass --set routes.host=aps.example.org (a name that resolves to this cluster's Traefik for your browser) and, when it is not on port 80/443, --set routes.port=8080. See docs/install.md (Names)."
    say "Identity: no routes.host given; using $_h (public wildcard DNS for this node's address). The identity provider will be id.$_h. Use --set routes.host=... for your own name."
  fi
  PUBLIC_HOST="$_h"
  _tls=0; case "$_tm" in ""|none) ;; upstream) _tls=upstream ;; *) _tls=1 ;; esac
  _argo=path
  case "$HELM_USER" in *argoUI.enabled=false*) _argo=off ;; esac
  _ah="$(set_value argoUI.host)"; [ -z "$_ah" ] || _argo="host=$_ah"
  _target=""
  if [ "$_tls" = 1 ] && [ "${_ti:-$(set_value traefik.install)}" != true ]; then
    _ts="$(kc get svc -A -l app.kubernetes.io/name=traefik -o 'jsonpath={range .items[*]}{.metadata.name}.{.metadata.namespace}.svc{"\n"}{end}' 2>/dev/null | head -n 1)"
    [ -z "$_ts" ] || _target="$_ts:443"
  fi
  mk_tmp
  ID_VALUES="$TMP/identity-hosts.yaml"
  ID_PORT="$_p"
  aps_identity_values "$_h" "$(set_value identity.host)" "$_p" "$_tls" "$_argo" "$_target" "$REL" > "$ID_VALUES" || die 2 "could not generate the identity values"
}

# An interrupted release (pending-install/upgrade/rollback) cannot be upgraded; never auto-delete release Secrets.
check_release_state() {
  if _st="$(hm status "$REL" -n "$NS" -o json 2>/dev/null)"; then
    _state="$(printf '%s' "$_st" | grep -o '"status": *"[a-z-]*"' | head -n 1 | sed 's/.*: *"\(.*\)"/\1/')"
    case "$_state" in
      pending-*)
        die 2 "release \"$REL\" is stuck in state $_state (an earlier run was interrupted). Recover with one of: 'helm rollback $REL -n $NS' (when an earlier revision exists) or 'helm uninstall $REL -n $NS' (your data volumes and Secret are kept), then re-run this installer. Nothing was changed." ;;
    esac
  fi
}

# ---------------------------------------------------------------- chart
fetch_chart() {
  CHART_REF=""
  CHART_VERSIONED=""
  if [ -n "$CHART" ]; then
    [ -e "$CHART" ] || die 2 "--chart $CHART does not exist"
    CHART_REF="$CHART"
    if [ -d "$CHART" ] && ! { ls "$CHART"/charts/argo-workflows-*.tgz && ls "$CHART"/charts/traefik-*.tgz && ls "$CHART"/charts/zitadel-*.tgz; } >/dev/null 2>&1; then
      say "building chart dependencies"
      hm dependency build "$CHART" >&2 || die 2 "helm dependency build failed"
    fi
    return 0
  fi
  _u="${CHART_URL:-$DEFAULT_CHART_URL}"
  [ -n "$_u" ] || die 2 "no chart source: pass --chart DIR|TGZ or --chart-url URL"
  case "$_u" in
    oci://*) CHART_REF="$_u"; CHART_VERSIONED=1 ;;
    http://*|https://*)
      mk_tmp
      _f="$TMP/chart.tgz"
      say "downloading the chart from $_u"
      fetch "$_u" "$_f" || die 2 "download of $_u failed"
      fetch "$_u.sha256" "$TMP/chart.tgz.sha256" || die 2 "download of $_u.sha256 failed (the checksum file is required)"
      _sum="$(cut -d' ' -f1 <"$TMP/chart.tgz.sha256" | head -n 1)"
      [ "$(sha256_of "$_f")" = "$_sum" ] || die 2 "checksum mismatch for the downloaded chart $_u; refusing to install it"
      CHART_REF="$_f" ;;
    *) die 2 "unsupported chart URL \"$_u\" (use https://...tgz or oci://...)" ;;
  esac
}

# ---------------------------------------------------------------- install
run_helm() {
  set -- upgrade --install "$REL" "$CHART_REF" -n "$NS" --create-namespace --wait --timeout "$TIMEOUT" --reset-then-reuse-values
  if [ -n "$TRAEFIK_VALUES" ]; then set -- "$@" -f "$TRAEFIK_VALUES"; fi
  if [ -n "$ID_VALUES" ]; then set -- "$@" -f "$ID_VALUES"; fi
  if [ -n "$CHART_VERSIONED" ] && [ -n "$VERSION" ]; then set -- "$@" --version "$VERSION"; fi
  eval "set -- \"\$@\" $HELM_USER"
  [ -z "$DRY_RUN" ] || set -- "$@" --dry-run
  if [ -n "$PLAIN_HTTP" ] && [ -n "$CHART_VERSIONED" ]; then set -- "$@" --plain-http; fi
  # Zitadel's init/setup Jobs are ordinary Jobs whose pod template is immutable: remove the finished ones so an upgrade
  # recreates them (migrations re-run) instead of failing on the patch.
  if [ -z "$DRY_RUN" ] && hm status "$REL" -n "$NS" >/dev/null 2>&1; then
    kc -n "$NS" delete job "$REL-zitadel-init" "$REL-zitadel-setup" --ignore-not-found >/dev/null 2>&1 || true
  fi
  say "Installing release \"$REL\" into namespace \"$NS\" (pulls images and waits for the pods; a first install takes a few minutes)"
  if ! hm "$@"; then
    warn "helm failed. Release status and recent warning events follow; re-running this installer resumes where it stopped."
    hm status "$REL" -n "$NS" >&2 || true
    kc -n "$NS" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -n 15 >&2
    exit 3
  fi
}

# ---------------------------------------------------------------- waiting and reporting
# Stamp the Argo CRDs (applied by the chart's hook Job, which sets no Helm ownership) as belonging to this release, so
# a re-run or a reinstall after uninstall.sh is not mistaken for a foreign Argo (see preflight).
mark_crds() {
  kc annotate crd workflows.argoproj.io "meta.helm.sh/release-name=$REL" "meta.helm.sh/release-namespace=$NS" --overwrite >/dev/null 2>&1 || true
}

http_code() { # http_code URL -> 3-digit code (000 on failure)
  if command -v curl >/dev/null 2>&1; then
    # POLL_HOST: the public host name goes in the Host header, so the address can be used without DNS
    curl -s -o /dev/null -m 5 ${POLL_HOST:+-H "Host: $POLL_HOST"} -w '%{http_code}' "$1" </dev/null 2>/dev/null || printf '000'
  elif command -v wget >/dev/null 2>&1; then
    if wget -q -T 5 -O /dev/null ${POLL_HOST:+--header="Host: $POLL_HOST"} "$1" </dev/null 2>/dev/null; then printf '200'; else printf '000'; fi
  else
    printf '000'
  fi
}

# poll_ready BASE SECONDS: success once BASE/readyz answers 200 within SECONDS.
poll_ready() {
  _end=$(( $(date +%s) + $2 ))
  while :; do
    [ "$(http_code "$1/readyz")" = 200 ] && return 0
    [ "$(date +%s)" -ge "$_end" ] && return 1
    sleep "$POLL"
  done
}

# Sets BASE_URL and DISCOVERED (1 = a usable address was found or given), and TRAEFIK_NS / TRAEFIK_SVC (the Traefik Service
# that serves this release; used for the port-forward hint).
discover_url() {
  # BASE_URL: where the app is opened (names); POLL_URL + POLL_HOST: where this machine reaches it for the readiness check
  # (an address, with the public host as the Host header, so no DNS is needed).
  BASE_URL=""; DISCOVERED=0; POLL_URL=""; POLL_HOST="${PUBLIC_HOST:-}"
  TRAEFIK_NS="$NS"; TRAEFIK_SVC="$REL-traefik"
  if [ -n "$URL_OVERRIDE" ]; then
    POLL_URL="${URL_OVERRIDE%/}"; BASE_URL="$POLL_URL"; DISCOVERED=1
    if [ -n "$PUBLIC_HOST" ]; then
      case "$POLL_URL" in https://*) _os=https ;; *) _os=http ;; esac
      [ "$(release_value tls mode)" != upstream ] || _os=https
      BASE_URL="$_os://$PUBLIC_HOST${ID_PORT:+:$ID_PORT}"
    fi
    return 0
  fi
  # The public host and TLS come from the release's IngressRoute (routes.host / tls.mode).
  _r="$(kc -n "$NS" get ingressroute "$REL" -o 'jsonpath={.spec.tls.secretName}|{.spec.routes[0].match}' 2>/dev/null)" || _r=""
  _match=""; _tls=""
  IFS='|' read -r _tls _match <<EOF   # the match is last: it contains | itself
$_r
EOF
  _host="$(printf '%s' "$_match" | sed -n 's/.*Host(`\([^`]*\)`).*/\1/p')"
  # The Traefik Service(s) (ours or the cluster's): the first one with a load-balancer address wins.
  _svcs="$(kc get svc -A -l app.kubernetes.io/name=traefik -o 'jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.loadBalancer.ingress[0].ip}|{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null)" || _svcs=""
  _ip=""; _hn=""; _first=1
  while IFS='|' read -r _sn _sv _sip _shn; do
    [ -n "$_sv" ] || continue
    if [ "$_first" = 1 ]; then TRAEFIK_NS="$_sn"; TRAEFIK_SVC="$_sv"; _first=0; fi
    if [ -n "$_sip$_shn" ]; then TRAEFIK_NS="$_sn"; TRAEFIK_SVC="$_sv"; _ip="$_sip"; _hn="$_shn"; break; fi
  done <<EOF
$_svcs
EOF
  _addr="${_host:-${_ip:-$_hn}}"
  # k3s's Traefik answers on every node address through its host ports 80/443.
  [ -n "$_addr" ] || { [ -z "$BOOTSTRAPPED" ] || _addr="$(host_ip)"; }
  [ -n "$_addr" ] || return 0
  _scheme=http
  [ -z "$_tls" ] || _scheme=https
  _pt="${ID_PORT:-$(release_value routes port)}"
  BASE_URL="$_scheme://$_addr${_pt:+:$_pt}"
  POLL_URL="$BASE_URL"
  if [ "$(release_value tls mode)" = upstream ]; then
    # TLS ends in front of Traefik: people use https://host[:port], but from here the only thing to probe is Traefik's own
    # plain-HTTP entrypoint (no certificate, and the public port is the proxy's, not Traefik's).
    BASE_URL="https://${_host:-$_addr}${_pt:+:$_pt}"; POLL_URL="http://${_ip:-${_hn:-$_addr}}"
    [ -z "$_host" ] || POLL_HOST="$_host"
    DISCOVERED=1
    return 0
  fi
  # reach the cluster by its load-balancer address when there is one, naming the host in the Host header
  if [ -n "$_host" ] && [ -n "${_ip:-$_hn}" ]; then POLL_URL="$_scheme://${_ip:-$_hn}${_pt:+:$_pt}"; POLL_HOST="$_host"; fi
  DISCOVERED=1
}

# Temporary port-forward to apsd (it answers /readyz itself); sets PF_URL.
start_portforward() {
  PF_URL=""
  mk_tmp
  kubectl ${CTX:+--context "$CTX"} -n "$NS" port-forward "svc/$REL-apsd" :80 </dev/null >"$TMP/pf.out" 2>&1 &
  PF_PID=$!
  _n=0
  while [ "$_n" -lt 30 ]; do
    _port="$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\) *->.*/\1/p' "$TMP/pf.out" 2>/dev/null | head -n 1)"
    if [ -n "$_port" ]; then PF_URL="http://127.0.0.1:$_port"; return 0; fi
    sleep 1; _n=$((_n + 1))
  done
  return 1
}

wait_app() {
  # apsd.replicaCount=0 (e.g. while restoring a database before the first start): nothing can answer /readyz, so do
  # not wait for the app; only the web Deployment is checked.
  _rep="$(kc -n "$NS" get deploy "$REL-apsd" -o 'jsonpath={.spec.replicas}' 2>/dev/null)" || _rep=""
  if [ "$_rep" = 0 ]; then
    say "apsd is scaled to 0 replicas (apsd.replicaCount=0): not waiting for the app to answer; scale it up to start serving."
    kc -n "$NS" rollout status "deploy/$REL-web" --timeout "$TIMEOUT" >&2 \
      || die 4 "deployment $REL-web did not become ready within $TIMEOUT. Look at: kubectl -n $NS get pods"
    discover_url
    APSD_ZERO=1
    return 0
  fi
  for _d in apsd web; do
    kc -n "$NS" rollout status "deploy/$REL-$_d" --timeout "$TIMEOUT" >&2 \
      || die 4 "deployment $REL-$_d did not become ready within $TIMEOUT. Look at: kubectl -n $NS get pods; kubectl -n $NS describe pod -l app.kubernetes.io/instance=$REL"
  done
  discover_url
  if [ "$DISCOVERED" = 1 ]; then
    _b1="$TIMEOUT_S"; [ "$_b1" -le 60 ] || _b1=60
    if poll_ready "$POLL_URL" "$_b1"; then return 0; fi
    [ "$TIMEOUT_S" -gt "$_b1" ] || die 4 "the app did not answer $POLL_URL/readyz within $TIMEOUT"
    warn "$POLL_URL/readyz does not answer from this machine yet; checking the app through a port-forward instead"
  fi
  start_portforward || die 4 "could not open a port-forward to svc/$REL-apsd"
  _rest=$((TIMEOUT_S - 1)); [ "$_rest" -ge 1 ] || _rest=1
  poll_ready "$PF_URL" "$_rest" || die 4 "the app did not answer /readyz within $TIMEOUT (checked through a port-forward to apsd). Look at: kubectl -n $NS logs deploy/$REL-apsd"
  [ "$DISCOVERED" = 0 ] || warn "the app is ready, but $POLL_URL does not answer from this machine (firewall, DNS, or Traefik still starting: kubectl -n $TRAEFIK_NS get pods -l app.kubernetes.io/name=traefik)"
}

# Sets IX_READY IX_TOTAL IX_SET IX_LINE; IX_TOTAL=-1 when plate solving is disabled (no index DaemonSet).
index_state() {
  IX_READY=0; IX_TOTAL=-1; IX_SET=""; IX_LINE=""
  _ds="$(kc -n "$NS" get ds "$REL-index-fetcher" -o 'jsonpath={.status.desiredNumberScheduled}|{.spec.template.spec.containers[0].env[?(@.name=="SET_ID")].value}|{.spec.template.spec.containers[0].env[?(@.name=="LABEL_KEY")].value}' 2>/dev/null)" || return 0
  _tot=""; _lk=""
  IFS='|' read -r _tot IX_SET _lk <<EOF
$_ds
EOF
  IX_TOTAL="${_tot:-0}"; _lk="${_lk:-aps/index-set}"
  _pk="${_lk%/*}/index-progress"
  _lke="$(printf '%s' "$_lk" | sed 's/\./\\./g')"; _pke="$(printf '%s' "$_pk" | sed 's/\./\\./g')"
  _nodes="$(kc get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.metadata.labels.'"$_lke"'}{"|"}{.metadata.annotations.'"$_pke"'}{"\n"}{end}' 2>/dev/null)"
  _prog=""
  while IFS='|' read -r _n _l _a; do
    [ -n "$_n" ] || continue
    if [ -n "$_l" ] && [ "$_l" = "$IX_SET" ]; then IX_READY=$((IX_READY + 1))
    elif [ -n "$_a" ]; then _prog="$_prog $_n=$_a"; fi
  done <<EOF
$_nodes
EOF
  IX_LINE="index sets: $IX_READY of $IX_TOTAL eligible nodes ready (set $IX_SET)"
  [ -z "$_prog" ] || IX_LINE="$IX_LINE; progress:$_prog"
}

report_indexes() {
  index_state
  if [ "$IX_TOTAL" -lt 0 ]; then say "index sets: plate solving is disabled (plateSolve.enabled=false)"; return 0; fi
  say "$IX_LINE"
  if [ "$WAIT_INDEXES" -gt 0 ] && [ "$IX_READY" -lt "$IX_TOTAL" ]; then
    _end=$(( $(date +%s) + WAIT_INDEXES ))
    say "waiting up to ${WAIT_INDEXES}s for the indexes (Ctrl-C is safe: the download continues in the cluster)"
    while [ "$IX_READY" -lt "$IX_TOTAL" ] && [ "$(date +%s)" -lt "$_end" ]; do
      sleep "$POLL"
      index_state
    done
    say "$IX_LINE"
  fi
  if [ "$IX_READY" -lt "$IX_TOTAL" ]; then
    say "solve is not ready on $((IX_TOTAL - IX_READY)) nodes yet; the app is usable (solve runs wait until a node is ready)"
  fi
}

final_message() {
  if [ "$DISCOVERED" = 1 ]; then _url="$BASE_URL"; else _url="http://localhost:8080"; fi
  _ready="Astro Pixel Platform is ready."
  [ "${APSD_ZERO:-0}" != 1 ] || _ready="Astro Pixel Platform is installed, with apsd scaled to 0 (it does not serve yet: re-run without apsd.replicaCount=0)."
  cat <<MSG

$_ready

  Open:      $_url/
MSG
  if [ "$DISCOVERED" = 0 ]; then
    cat <<MSG
             (no Traefik address was found: make the host names (routes.host and id.<routes.host>) resolve to Traefik;
              for a local try: kubectl -n $TRAEFIK_NS port-forward svc/$TRAEFIK_SVC 8080:80 with routes.port=8080)
MSG
  fi
  cat <<MSG

  First user: open it and create your account (the first account becomes the owner, a platform administrator).
  Further sign-ups follow identity.registration (default first-user: closed after the first). Accounts, passwords and
  passkeys live in the identity provider; its admin login is in the Secret aps-zitadel (see docs/install.md, Identity).

  Solve progress per node:   kubectl get nodes -L aps/index-set
  Upgrade:                   re-run this installer (same flags); data and secrets are kept
  Uninstall (keeps data):    curl -sfL $UNINSTALL_URL | sh -s -- -n $NS --release $REL --yes
                             (add --purge-data to delete the database and stored frames too)
MSG
  if [ -n "$BOOTSTRAPPED" ]; then
    cat <<MSG

  This host runs single-node k3s (installed by --bootstrap):
    kubectl:                 export KUBECONFIG=$K3S_KUBECONFIG   (root-only file; or: sudo k3s kubectl ...)
    Remove k3s as well:      curl -sfL $UNINSTALL_URL | sudo sh -s -- --remove-k3s --purge-indexes --yes
                             (deletes the whole single-node cluster and everything stored in it)
MSG
  fi
}

# The bundled identity provider is configured by a Job (project, OIDC clients, service account): wait for it, since the
# first login needs it. Nothing to wait for with an external provider.
wait_identity() {
  [ "$(kc -n "$NS" get job -l app.kubernetes.io/component=identity-bootstrap -o name 2>/dev/null | grep -c .)" -gt 0 ] || return 0
  say "Waiting for the identity provider bootstrap Job"
  kc -n "$NS" wait --for=condition=complete job -l app.kubernetes.io/component=identity-bootstrap --timeout "$TIMEOUT" >&2 \
    || die 4 "the identity bootstrap Job did not complete within $TIMEOUT. Look at: kubectl -n $NS logs job -l app.kubernetes.io/component=identity-bootstrap; kubectl -n $NS get pods -l app.kubernetes.io/name=zitadel"
}

post_install() {
  mark_crds
  wait_identity
  wait_app
  report_indexes
  final_message
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ -z "$BOOTSTRAP" ] || bootstrap
  preflight
  resolve_traefik
  ensure_helm
  check_release_state
  resolve_identity
  fetch_chart
  run_helm
  [ -z "$DRY_RUN" ] || { say "dry run: nothing was installed"; exit 0; }
  post_install
}

main "$@"
exit $?
