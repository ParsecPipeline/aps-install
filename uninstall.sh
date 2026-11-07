#!/bin/sh
# Astro Pixel Platform uninstaller. Removes the Helm release and its WorkflowTemplates and KEEPS your data
# (Postgres and object-store volumes, the generated Secret, the Argo CRDs and the node-local astrometry indexes)
# unless you ask otherwise, so a later install.sh brings everything back.
#
#   curl -sfL https://raw.githubusercontent.com/parsecpipeline/aps-install/main/uninstall.sh | sh -s -- --yes
#   curl -sfL <url>/uninstall.sh | sh -s -- -n aps --purge-data --yes
#
# After a `--bootstrap` install (single-node k3s on a bare host) `--remove-k3s` removes k3s itself as the last step
# (run as root: curl -sfL <url>/uninstall.sh | sudo sh -s -- --remove-k3s --purge-indexes --yes).
#
# POSIX sh. Never uses sudo. Exit codes: 0 ok | 2 usage / preflight / not confirmed | 3 a step failed.

PROG="uninstall.sh"

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [flags]

  --namespace, -n NS     namespace of the release (default aps; env APS_NAMESPACE)
  --release NAME         Helm release name (default aps; env APS_RELEASE)
  --purge-data, --purge  ALSO delete the Postgres and object-store volumes (all frames, users, runs) and the
                         generated Secret <release>-secrets. Both go together, never one without the other.
  --purge-crds           ALSO delete the *.argoproj.io CRDs (this deletes every Argo Workflow on the cluster)
  --purge-indexes        ALSO empty the node-local astrometry index directory on every node that holds it and
                         remove the node labels/annotations (runs a short pod per node)
  --index-image IMG      image for the purge pods (default: the release's index-fetcher image, read before uninstall)
  --remove-k3s           ALSO remove the single-node k3s that install.sh --bootstrap installed, last, by running its
                         k3s-uninstall.sh (needs root). This deletes the WHOLE cluster and all data stored in it, whatever
                         the other flags say; add --purge-indexes to also empty the node-local index directory
                         (/var/lib/aps, outside k3s). Opt-in; never done otherwise.
  --context NAME         kubectl/helm context (env APS_CONTEXT)
  --yes, -y              do not ask for confirmation (env APS_ASSUME_YES=1)
  --help, -h             this text

Without a terminal to ask on, the script refuses to run unless --yes or APS_ASSUME_YES=1 is given.
USAGE
}

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { # die CODE MSG...
  _c="$1"; shift
  printf '%s: %s\n' "${PROG:-install.sh}" "$*" >&2
  exit "$_c"
}

TMP=""
PF_PID=""
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
}

NS="${APS_NAMESPACE:-aps}"
REL="${APS_RELEASE:-aps}"
CTX="${APS_CONTEXT:-}"
ASSUME_YES="${APS_ASSUME_YES:-}"
HELM_VERSION="${APS_HELM_VERSION:-}"   # default: PINNED_HELM_VERSION (see ensure_helm)
HELM_BASE_URL="${APS_HELM_BASE_URL:-https://get.helm.sh}"
TTY_DEV="${APS_TTY:-/dev/tty}"   # test seam
PURGE_DATA=""; PURGE_CRDS=""; PURGE_INDEXES=""; INDEX_IMAGE=""; REMOVE_K3S=""; SKIP_CLUSTER=""
K3S_UNINSTALL="${APS_K3S_UNINSTALL:-/usr/local/bin/k3s-uninstall.sh}"     # test seam
K3S_KUBECONFIG="${APS_K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"          # test seam

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n) [ $# -ge 2 ] || die 2 "$1 needs a value"; NS="$2"; shift 2 ;;
    --release) [ $# -ge 2 ] || die 2 "--release needs a value"; REL="$2"; shift 2 ;;
    --context) [ $# -ge 2 ] || die 2 "--context needs a value"; CTX="$2"; shift 2 ;;
    --index-image) [ $# -ge 2 ] || die 2 "--index-image needs a value"; INDEX_IMAGE="$2"; shift 2 ;;
    --purge-data|--purge) PURGE_DATA=1; shift ;;
    --purge-crds) PURGE_CRDS=1; shift ;;
    --purge-indexes) PURGE_INDEXES=1; shift ;;
    --remove-k3s) REMOVE_K3S=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die 2 "unknown argument: $1" ;;
  esac
done

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

# ---------------------------------------------------------------- uninstall
confirm() {
  [ -z "$ASSUME_YES" ] || return 0
  if ! ( : <"$TTY_DEV" ) 2>/dev/null; then
    die 2 "no terminal to ask for confirmation on. Re-run with --yes (or APS_ASSUME_YES=1) to uninstall release \"$REL\" from namespace \"$NS\"."
  fi
  _what="the release \"$REL\" in namespace \"$NS\" (data is KEPT)"
  [ -z "$PURGE_DATA" ] || _what="the release \"$REL\" in namespace \"$NS\" AND ALL ITS DATA (database, stored frames, secrets)"
  [ -z "$PURGE_CRDS" ] || _what="$_what AND the Argo CRDs (every Argo Workflow on the cluster)"
  [ -z "$PURGE_INDEXES" ] || _what="$_what AND the node-local astrometry indexes"
  [ -z "$REMOVE_K3S" ] || _what="$_what AND THEN THE WHOLE single-node k3s cluster with everything stored in it"
  printf 'Uninstall %s on context "%s"? [y/N] ' "$_what" "${CUR_CTX:-local}" >&2
  _ans=""
  read -r _ans <"$TTY_DEV" || _ans=""
  case "$_ans" in y|Y|yes|YES) return 0 ;; *) die 2 "aborted by the user" ;; esac
}

purge_pod() { # purge_pod NODE IMAGE HOSTPATH: empty the hostPath on NODE with a one-shot pod pinned there
  _node="$1"; _img="$2"; _path="$3"
  _pod="aps-index-purge-$(printf '%s' "$_node" | tr 'A-Z.' 'a-z-' | cut -c1-40)"
  _ov="{\"spec\":{\"nodeName\":\"$_node\",\"restartPolicy\":\"Never\",\"tolerations\":[{\"operator\":\"Exists\"}],\"securityContext\":{\"runAsUser\":0},\"containers\":[{\"name\":\"purge\",\"image\":\"$_img\",\"imagePullPolicy\":\"IfNotPresent\",\"command\":[\"sh\",\"-c\",\"find /indexes -mindepth 1 -delete\"],\"volumeMounts\":[{\"name\":\"indexes\",\"mountPath\":\"/indexes\"}]}],\"volumes\":[{\"name\":\"indexes\",\"hostPath\":{\"path\":\"$_path\",\"type\":\"DirectoryOrCreate\"}}]}}"
  kc -n "$NS" delete pod "$_pod" --ignore-not-found >/dev/null 2>&1
  kc -n "$NS" run "$_pod" --image "$_img" --restart=Never --overrides "$_ov" >/dev/null || return 1
  kc -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$_pod" --timeout=180s >/dev/null || { kc -n "$NS" logs "$_pod" >&2; kc -n "$NS" delete pod "$_pod" --ignore-not-found >/dev/null 2>&1; return 1; }
  kc -n "$NS" delete pod "$_pod" --ignore-not-found >/dev/null 2>&1
  say "emptied $_path on node $_node"
}

cluster_uninstall() {
  command -v kubectl >/dev/null 2>&1 || die 2 "kubectl was not found on PATH"
  CUR_CTX="${CTX:-$(kubectl config current-context 2>/dev/null </dev/null)}"
  [ -n "$CUR_CTX" ] || die 2 "no current kubectl context (select one or pass --context)"
  say "Cluster: context $CUR_CTX"
  confirm
  kc get --raw /readyz >/dev/null 2>&1 || die 2 "the Kubernetes API of context \"$CUR_CTX\" is not reachable"
  ensure_helm

  # Read what the purge needs BEFORE the release (and with it the DaemonSet) disappears.
  IX_IMAGE=""; IX_PATH="${APS_INDEX_PATH:-/var/lib/aps/astrometry-index}"; IX_LABEL="aps/index-set"
  if [ -n "$PURGE_INDEXES" ]; then
    if _info="$(kc -n "$NS" get ds "$REL-index-fetcher" -o 'jsonpath={.spec.template.spec.containers[0].image}|{.spec.template.spec.volumes[?(@.name=="indexes")].hostPath.path}|{.spec.template.spec.containers[0].env[?(@.name=="LABEL_KEY")].value}' 2>/dev/null)"; then
      _i=""; _p=""; _l=""
      IFS='|' read -r _i _p _l <<EOF
$_info
EOF
      IX_IMAGE="${_i:-}"; IX_PATH="${_p:-$IX_PATH}"; IX_LABEL="${_l:-$IX_LABEL}"
    fi
    [ -z "$INDEX_IMAGE" ] || IX_IMAGE="$INDEX_IMAGE"
    # With --remove-k3s the single node is this host (root): the directory is emptied locally in remove_k3s, no pod needed.
    [ -n "$IX_IMAGE" ] || [ -n "$REMOVE_K3S" ] || die 2 "--purge-indexes needs the index-fetcher image and the release has no DaemonSet any more: pass --index-image <image>"
    IX_NODES="$(
      { kc -n "$NS" get pods -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/component=index-fetcher" -o 'jsonpath={range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
        kc get nodes -l "$IX_LABEL" -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null; } | grep -v '^$' | sort -u)"
  fi

  if hm status "$REL" -n "$NS" >/dev/null 2>&1; then
    say "Uninstalling release \"$REL\" from namespace \"$NS\""
    hm uninstall "$REL" -n "$NS" --wait || die 3 "helm uninstall failed"
  else
    say "release \"$REL\" is not installed in namespace \"$NS\"; removing leftovers only"
  fi

  # The verb WorkflowTemplates are post-install hooks: Helm does not track them, so remove them explicitly.
  kc -n "$NS" delete workflowtemplates.argoproj.io -l "app.kubernetes.io/part-of=aps,app.kubernetes.io/instance=$REL" --ignore-not-found >/dev/null 2>&1 || true

  if [ -n "$PURGE_DATA" ]; then
    # Volumes and Secret go together: a Secret without its volume (or the reverse) is a database nobody can open.
    say "Deleting the data volumes and the Secret ${REL}-secrets"
    kc -n "$NS" delete pvc -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/component in (pg,rustfs,nats)" --wait --timeout=180s \
      || die 3 "could not delete the volumes; the Secret ${REL}-secrets was NOT deleted (they must be deleted together). Re-run with --purge-data."
    kc -n "$NS" delete secret "${REL}-secrets" --ignore-not-found || die 3 "could not delete the Secret ${REL}-secrets"
  fi

  if [ -n "$PURGE_CRDS" ]; then
    _crds="$(kc get crd -o name 2>/dev/null | grep '\.argoproj\.io$' | tr '\n' ' ')"
    if [ -n "$_crds" ]; then
      say "Deleting the Argo CRDs"
      # shellcheck disable=SC2086
      kc delete $_crds --wait --timeout=180s || die 3 "could not delete the Argo CRDs"
    fi
  fi

  if [ -n "$PURGE_INDEXES" ]; then
    _failed=0
    for _n in $IX_NODES; do
      [ -n "$IX_IMAGE" ] || break
      if purge_pod "$_n" "$IX_IMAGE" "$IX_PATH"; then
        kc label node "$_n" "$IX_LABEL-" >/dev/null 2>&1 || true
        kc annotate node "$_n" "${IX_LABEL%/*}/index-progress-" >/dev/null 2>&1 || true
      else
        warn "could not empty $IX_PATH on node $_n"; _failed=1
      fi
    done
    [ "$_failed" = 0 ] || die 3 "some nodes could not be purged"
  fi

  say ""
  say "Uninstalled release \"$REL\"."
  _kept=""
  [ -n "$PURGE_DATA" ] || _kept="$_kept the data volumes and Secret ${REL}-secrets (--purge-data deletes them);"
  [ -n "$PURGE_CRDS" ] || _kept="$_kept the Argo CRDs (--purge-crds);"
  [ -n "$PURGE_INDEXES" ] || _kept="$_kept the node-local astrometry indexes (--purge-indexes);"
  if [ -n "$_kept" ]; then
    say "kept:${_kept%;}"
    say "Re-running install.sh restores the application on top of the kept data."
  fi
}

# --remove-k3s: the cluster steps need a reachable API; when k3s is already stopped there is nothing to uninstall
# inside it and only the k3s removal remains. A plain kubectl (not k3s's symlink) needs k3s's kubeconfig.
prepare_k3s_removal() {
  [ -x "$K3S_UNINSTALL" ] || die 2 "--remove-k3s: $K3S_UNINSTALL does not exist, so k3s was not installed by its installer on this host; nothing to remove"
  [ "${APS_TEST_UID:-$(id -u)}" = 0 ] || die 2 "--remove-k3s needs root (k3s is a system service). Re-run with sudo: curl -sfL <url>/uninstall.sh | sudo sh -s -- --remove-k3s ..."
  if [ -z "${KUBECONFIG:-}" ] && [ -z "$CTX" ] && [ -r "$K3S_KUBECONFIG" ]; then
    KUBECONFIG="$K3S_KUBECONFIG"; export KUBECONFIG
    case ":$PATH:" in *:/usr/local/bin:*) ;; *) PATH="$PATH:/usr/local/bin"; export PATH ;; esac
  fi
  if ! command -v kubectl >/dev/null 2>&1 || ! kc get --raw /readyz >/dev/null 2>&1; then
    SKIP_CLUSTER=1
    warn "the k3s API is not reachable: skipping the release removal, only k3s itself is removed"
  fi
}

remove_k3s() {
  say "Removing k3s ($K3S_UNINSTALL)"
  sh "$K3S_UNINSTALL" </dev/null || die 3 "$K3S_UNINSTALL failed"
  if [ -n "$PURGE_INDEXES" ]; then
    # k3s is single-node here and this host is that node: the index hostPath is outside k3s, so remove it directly.
    _ixp="${IX_PATH:-${APS_INDEX_PATH:-/var/lib/aps/astrometry-index}}"
    rm -rf "$_ixp" && say "removed $_ixp"
    rmdir "$(dirname "$_ixp")" 2>/dev/null || true
  fi
  say "k3s removed. Not touched: the node-local astrometry indexes under /var/lib/aps unless --purge-indexes was given, and anything k3s left in /var/lib/rancher that its uninstaller keeps."
}

main() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ -z "$REMOVE_K3S" ] || prepare_k3s_removal
  if [ -z "$SKIP_CLUSTER" ]; then cluster_uninstall; else confirm; fi
  [ -z "$REMOVE_K3S" ] || remove_k3s
}

main "$@"
exit $?
