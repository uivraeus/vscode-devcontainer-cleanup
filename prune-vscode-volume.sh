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
  -k, --keep N        Versions to keep, newest first (default: 1): bundles per
                      platform, and cached extension versions per extension
                      (and target platform)
  -E, --no-extensions Do not prune the extension download cache
  -n, --dry-run       Show what would be deleted; change nothing
  -v, --volume NAME   Volume name (default: vscode)
  -h, --help          Show this help

Extension cache entries (<volume>/vscode-server/extensionsCache/<id>-<version>
[-<target platform>]) are grouped by name parsing, with no extension-specific
rules; the newest are chosen by version number, not file date. Entries whose
names cannot be parsed are left alone.

Leftover partial installs (<commit>_<timestamp>) are always removed and do
not count towards --keep.
EOF
}

pattern="vsc-"
keep=1
dry=0
volume=vscode
ext=1

while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--pattern) pattern=${2:?$1 needs a value}; shift 2 ;;
    -k|--keep)    keep=${2:?$1 needs a value}; shift 2 ;;
    -E|--no-extensions) ext=0; shift ;;
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
echo "Keep:    $keep per platform / per extension"
echo "Mode:    $([[ $dry == 1 ]] && echo 'DRY RUN' || echo 'DELETE')"

read -r -d '' inner <<'EOS' || true
keep=$1; dry=$2; ext=$3
root=/vscode/vscode-server/bin
extroot=/vscode/vscode-server/extensionsCache
fmt() { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GiB", k/1048576; else printf "%.0f MiB", k/1024 }'; }
size_kb() { du -sk "$1" | cut -f1; }

total_before=$(size_kb /vscode)
bin_before=0; [ -d "$root" ] && bin_before=$(size_kb "$root")
ext_before=0; [ -d "$extroot" ] && ext_before=$(size_kb "$extroot")
echo
echo "Before: volume $(fmt "$total_before"), bin/ $(fmt "$bin_before"), extensionsCache/ $(fmt "$ext_before")"

freed=0; ndel=0; nkeep=0
for plat in "$root"/*/; do
  [ -d "$root" ] || break
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

if [ "$ext" = 1 ] && [ -d "$extroot" ]; then
  echo
  echo "== extensionsCache"
  re='^(.+)-([0-9]+\.[0-9]+\.[0-9]+)(-[a-z0-9]+-[a-z0-9_]+|-web|-universal)?(\.sigzip)?$'
  list=$(mktemp); skipped=0
  while IFS= read -r name; do
    if [[ $name =~ $re ]]; then
      printf '%s%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "$name" >> "$list"
    else
      skipped=$((skipped+1)); echo "  skip    $name (unrecognized name)"
    fi
  done < <(find "$extroot" -mindepth 1 -maxdepth 1 -printf '%f\n')
  # A version may have several files (e.g. a .sigzip next to the package);
  # they are kept or deleted together.
  prev=; prevver=; kept=0
  while IFS=$'\t' read -r key ver name; do
    if [ "$key" != "$prev" ]; then prev=$key; prevver=$ver; kept=1
    elif [ "$ver" != "$prevver" ]; then prevver=$ver; kept=$((kept+1)); fi
    d=$extroot/$name; size=$(size_kb "$d")
    if [ "$kept" -le "$keep" ]; then
      nkeep=$((nkeep+1))
      printf '  keep    %s  %9s\n' "$name" "$(fmt "$size")"
    else
      ndel=$((ndel+1)); freed=$((freed+size))
      if [ "$dry" = 1 ]; then verb="delete?"; else verb="delete"; rm -rf -- "$d"; fi
      printf '  %-7s %s  %9s  (old)\n' "$verb" "$name" "$(fmt "$size")"
    fi
  done < <(sort -t"$(printf '\t')" -k1,1 -k2,2Vr "$list")
  rm -f "$list"
fi

echo
if [ "$dry" = 1 ]; then
  echo "Summary (dry run): keep $nkeep, would delete $ndel, would free $(fmt "$freed")"
  echo "After (expected): volume $(fmt $((total_before-freed)))"
else
  echo "Summary: kept $nkeep, deleted $ndel, freed $(fmt "$freed")"
  b=0; [ -d "$root" ] && b=$(size_kb "$root")
  e=0; [ -d "$extroot" ] && e=$(size_kb "$extroot")
  echo "After:  volume $(fmt "$(size_kb /vscode)"), bin/ $(fmt "$b"), extensionsCache/ $(fmt "$e")"
fi
EOS

mount="$volume:/vscode"
[[ $dry == 1 ]] && mount+=":ro"

docker run --rm --pull=never --network=none --user root --entrypoint bash \
  -v "$mount" "$image" -c "$inner" _ "$keep" "$dry" "$ext"
