#!/usr/bin/env bash
# Prune old VS Code server bundles from the shared Dev Containers "vscode"
# Docker volume. Run on the host while no container is using the volume.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prune-vscode-volume.sh [options]

Prunes old VS Code server bundles (<volume>/vscode-server/bin/<platform>/<commit>)
from the shared Dev Containers volume. Run it on the host. It refuses to run
if any running container uses the volume.

A helper container is started from an image that is ALREADY present locally
(nothing is ever pulled) to access the volume.

Options:
  -p, --pattern STR   Substring used to find a local helper image
                      (default: vsc-, images built by Dev Containers)
  -k, --keep N        Bundles to keep per platform, newest first (default: 1)
  -n, --dry-run       Show what would be deleted; change nothing
  -v, --volume NAME   Volume name (default: vscode)
  -h, --help          Show this help

Leftover partial installs (<commit>_<timestamp>) are always removed and do
not count towards --keep.
EOF
}

pattern="vsc-"
keep=1
dry=0
volume=vscode

while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--pattern) pattern=${2:?$1 needs a value}; shift 2 ;;
    -k|--keep)    keep=${2:?$1 needs a value}; shift 2 ;;
    -n|--dry-run) dry=1; shift ;;
    -v|--volume)  volume=${2:?$1 needs a value}; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $keep =~ ^[0-9]+$ && $keep -ge 1 ]] || { echo "Error: --keep must be an integer >= 1" >&2; exit 2; }
command -v docker >/dev/null || { echo "Error: docker not found" >&2; exit 1; }

docker volume inspect "$volume" >/dev/null 2>&1 \
  || { echo "Error: docker volume '$volume' does not exist" >&2; exit 1; }

running=$(docker ps --filter "volume=$volume" --format '  {{.ID}}  {{.Names}}  ({{.Image}})')
if [[ -n $running ]]; then
  echo "Error: volume '$volume' is in use by running container(s):" >&2
  echo "$running" >&2
  echo "Stop them (close the devcontainers) and try again." >&2
  exit 1
fi

# `docker images` lists newest first; skip untagged entries.
image=$(docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -v '<none>' | grep -F -- "$pattern" | head -n1 || true)
if [[ -z $image ]]; then
  echo "Error: no local image matching '$pattern' found (images are never pulled)." >&2
  echo "Use --pattern to select another local image." >&2
  exit 1
fi

echo "Volume:  $volume"
echo "Image:   $image"
echo "Keep:    $keep per platform"
echo "Mode:    $([[ $dry == 1 ]] && echo 'DRY RUN' || echo 'DELETE')"

read -r -d '' inner <<'EOS' || true
keep=$1; dry=$2
root=/vscode/vscode-server/bin
fmt() { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GiB", k/1048576; else printf "%.0f MiB", k/1024 }'; }
size_kb() { du -sk "$1" | cut -f1; }

[ -d "$root" ] || { echo; echo "No $root in volume; nothing to do."; exit 0; }

total_before=$(size_kb /vscode)
bin_before=$(size_kb "$root")
echo
echo "Before: volume $(fmt "$total_before"), bin/ $(fmt "$bin_before")"

freed=0; ndel=0; nkeep=0
for plat in "$root"/*/; do
  plat=${plat%/}
  [ -d "$plat" ] || continue
  echo
  echo "== $(basename "$plat")"
  kept=0
  while IFS=$'\t' read -r date d; do
    name=${d##*/}
    size=$(size_kb "$d")
    case $name in
      *_*) action=delete; why="leftover" ;;
      *) if [ "$kept" -lt "$keep" ]; then action=keep; why="newest"; kept=$((kept+1))
         else action=delete; why="old"; fi ;;
    esac
    if [ "$action" = keep ]; then
      nkeep=$((nkeep+1))
      printf '  keep    %s  %s  %9s\n' "$name" "$date" "$(fmt "$size")"
    else
      ndel=$((ndel+1)); freed=$((freed+size))
      if [ "$dry" = 1 ]; then verb="delete?"; else verb="delete"; rm -rf -- "$d"; fi
      printf '  %-7s %s  %s  %9s  (%s)\n' "$verb" "$name" "$date" "$(fmt "$size")" "$why"
    fi
  done < <(find "$plat" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%TY-%Tm-%Td\t%p\n' | sort -rn | cut -f2-)
done

echo
if [ "$dry" = 1 ]; then
  echo "Summary (dry run): keep $nkeep, would delete $ndel, would free $(fmt "$freed")"
  echo "After (expected): volume $(fmt $((total_before-freed))), bin/ $(fmt $((bin_before-freed)))"
else
  echo "Summary: kept $nkeep, deleted $ndel, freed $(fmt "$freed")"
  echo "After:  volume $(fmt "$(size_kb /vscode)"), bin/ $(fmt "$(size_kb "$root")")"
fi
EOS

mount="$volume:/vscode"
[[ $dry == 1 ]] && mount+=":ro"

docker run --rm --pull=never --network=none --user root --entrypoint bash \
  -v "$mount" "$image" -c "$inner" _ "$keep" "$dry"
