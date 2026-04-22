#!/usr/bin/env bash
#
# Install the agg23.NEScheats core onto a Pocket SD card.
#
# Usage:
#   tools/install-to-pocket.sh [TARGET_ROOT]
#   TARGET_ROOT defaults to /Volumes/BLUEPOCKET.
#
# Copies:
#   pkg/pocket/Cores/agg23.NEScheats/*         -> $ROOT/Cores/agg23.NEScheats/
#   pkg/pocket/Assets/nes/agg23.NEScheats/*    -> $ROOT/Assets/nes/agg23.NEScheats/
#   pkg/pocket/Assets/nes/common/cheats/*       -> $ROOT/Assets/nes/common/cheats/
#
# Leaves alone:
#   $ROOT/Cores/agg23.NES/                      (stock agg23 install)
#   $ROOT/Platforms/nes.json
#   $ROOT/Platforms/_images/nes.bin
#   $ROOT/Assets/nes/agg23.NES/                 (stock core's palette etc.)
#
# After this runs you should see two cores under the "NES" platform tile:
# the stock agg23.NES and this fork (shortname "NES (Cheats)").

set -euo pipefail

TARGET_ROOT="${1:-/Volumes/BLUEPOCKET}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/pkg/pocket"

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo "error: target root $TARGET_ROOT does not exist or is not a directory" >&2
    echo "       pass a different path as the first argument, e.g.:" >&2
    echo "       $0 /Volumes/POCKET" >&2
    exit 1
fi

if [[ ! -d "$SRC/Cores/agg23.NEScheats" ]]; then
    echo "error: repo source not found at $SRC/Cores/agg23.NEScheats" >&2
    echo "       are you running this from a clean checkout of the branch?" >&2
    exit 1
fi

# Sanity: the Pocket mount should look like one.
if [[ ! -d "$TARGET_ROOT/Cores" && ! -d "$TARGET_ROOT/Assets" && ! -d "$TARGET_ROOT/Platforms" ]]; then
    echo "error: $TARGET_ROOT does not look like a Pocket SD card" >&2
    echo "       (expected at least one of Cores/, Assets/, Platforms/ to exist)" >&2
    exit 1
fi

if [[ ! -f "$SRC/Cores/agg23.NEScheats/nes.rev" ]]; then
    echo "error: no nes.rev at $SRC/Cores/agg23.NEScheats/nes.rev" >&2
    echo "       run a build first:" >&2
    echo "         quartus_sh --flow compile projects/nes_pocket.qpf" >&2
    echo "         python3 /opt/pocketpublish/reverse.py \\" >&2
    echo "             projects/output_files/nes_pocket.rbf \\" >&2
    echo "             pkg/pocket/Cores/agg23.NEScheats/nes.rev" >&2
    exit 1
fi

copy_tree() {
    local src="$1" dst="$2"
    mkdir -p "$dst"
    # Use rsync if available (handles merges cleanly, preserves attrs);
    # fall back to cp -R which also merges on most systems.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '.DS_Store' "$src/" "$dst/"
    else
        cp -R "$src/." "$dst/"
    fi
    echo "  copied $src -> $dst"
}

echo "Installing agg23.NEScheats to $TARGET_ROOT"

# Remove any stale previously-installed hyphenated variant
if [[ -d "$TARGET_ROOT/Cores/agg23.NES-cheats" ]]; then
    echo "  removing stale $TARGET_ROOT/Cores/agg23.NES-cheats (hyphenated, rejected by firmware)"
    rm -rf "$TARGET_ROOT/Cores/agg23.NES-cheats"
fi
if [[ -d "$TARGET_ROOT/Assets/nes/agg23.NES-cheats" ]]; then
    echo "  removing stale $TARGET_ROOT/Assets/nes/agg23.NES-cheats"
    rm -rf "$TARGET_ROOT/Assets/nes/agg23.NES-cheats"
fi

copy_tree "$SRC/Cores/agg23.NEScheats"        "$TARGET_ROOT/Cores/agg23.NEScheats"
copy_tree "$SRC/Assets/nes/agg23.NEScheats"   "$TARGET_ROOT/Assets/nes/agg23.NEScheats"
copy_tree "$SRC/Assets/nes/common/cheats"      "$TARGET_ROOT/Assets/nes/common/cheats"

# Invalidate Pocket core cache so the firmware re-scans /Cores/ on next boot.
# After a bad core install the Pocket sometimes keeps a stale cache that maps
# the directory name to a broken setup, causing "error in core setup" even
# after the underlying files are fixed.
for cache in corelist_cache.bin cores_cache.bin; do
    if [[ -f "$TARGET_ROOT/System/$cache" ]]; then
        echo "  invalidating $TARGET_ROOT/System/$cache"
        rm -f "$TARGET_ROOT/System/$cache"
    fi
done

echo
echo "Verifying installed nes.rev:"
SRC_REV="$SRC/Cores/agg23.NEScheats/nes.rev"
DST_REV="$TARGET_ROOT/Cores/agg23.NEScheats/nes.rev"
if command -v shasum >/dev/null 2>&1; then
    HASH_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
    HASH_CMD="sha256sum"
else
    echo "  (no sha256 tool found, skipping hash verification)"
    HASH_CMD=""
fi
if [[ -n "$HASH_CMD" ]]; then
    SRC_HASH=$($HASH_CMD "$SRC_REV" | awk '{print $1}')
    DST_HASH=$($HASH_CMD "$DST_REV" | awk '{print $1}')
    echo "  src: $SRC_HASH"
    echo "  sd : $DST_HASH"
    if [[ "$SRC_HASH" != "$DST_HASH" ]]; then
        echo "error: nes.rev on SD does not match source -- copy failed" >&2
        exit 1
    fi
fi

echo
echo "Done. On the Pocket NES tile you should now see two cores:"
echo "  - NES            (stock agg23)"
echo "  - NES (Cheats)   (this fork)"
echo
echo "Cheat files go in /Assets/nes/common/cheats/ on the SD."
