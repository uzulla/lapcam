#!/bin/sh
# build.sh - build the lapcam firmware image (docs/sdcard.md). Run on the build
# host (x86_64 Linux with Docker; docs/build.md has the one-time setup of the
# builder image and the download cache), from anywhere:
#   firmware/build.sh <thingino-firmware dir> [camera]
#     camera: wyze_cam3_t31x_gc2053_atbm6031 (the default)
# (PACK_ONLY=1, which only repacked the images, is gone: lapcam's files are in
# the rootfs now, so a change to device/ files needs the incremental build,
# which is what a plain run does - a minute or two when nothing else changed.)
#
# Runs firmware/prepare.sh (patches, user/<camera>/), then Thingino's own
# incremental build and packing inside the official builder container (the
# first time, the whole firmware is compiled: about 25 minutes on 4 cores with
# the download cache),
# then ffmpeg (not part of the image: it goes on the SD card). Results:
#   dist/firmware/thingino-<camera>.bin   the 16 MB image (whole flash)
#   dist/firmware/BUILD                   its BUILD_ID (branch+hash, date)
#   dist/ffmpeg                           the RTMPS-capable ffmpeg for the card
# The image's rootfs has only a few hundred KB to spare: the build fails if a
# partition image does not fit, which this script reports.

set -e

TREE=$1
CAMERA=${2:-wyze_cam3_t31x_gc2053_atbm6031}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
IMAGE=ghcr.io/themactep/thingino-builder-image:latest
DL_CACHE=thingino-dl-cache

if [ "${PACK_ONLY:-0}" != 0 ]; then
	echo "PACK_ONLY is gone (lapcam's files are in the rootfs now): run without it; the incremental build takes a minute or two" >&2
	exit 1
fi
if [ -z "$TREE" ] || [ ! -f "$TREE/Makefile" ]; then
	echo "Usage: $0 <thingino-firmware dir> [camera]" >&2
	exit 1
fi
TREE=$(cd "$TREE" && pwd)

if ! command -v docker >/dev/null 2>&1; then
	echo "docker is needed (docs/build.md)" >&2
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	echo "docker is installed but not running (or not usable by this user)" >&2
	exit 1
fi
if ! docker ps -a --format '{{.Names}}' | grep -qx "$DL_CACHE"; then
	echo "the download cache container '$DL_CACHE' is missing; in $TREE run:" >&2
	echo "  WORKFLOW=1 make -f Makefile.container container-pull    (docs/build.md, step 1)" >&2
	exit 1
fi

"$HERE/prepare.sh" "$TREE" "$CAMERA"

# in_tree <make args...>: Thingino's make inside the builder container, the
# way docs/build.md runs it (the install alternative works around the image's
# BSD-style install)
in_tree() {
	mkdir -p "$TREE/overrides"
	docker run --rm --user "$(id -u):$(id -g)" --network=host \
		--volumes-from "$DL_CACHE" \
		-v "$TREE":/workspace -v "$TREE/overrides":/overrides -w /workspace \
		-e BR2_DL_DIR=/dl \
		"$IMAGE" \
		bash -c "sudo update-alternatives --install /usr/bin/install install /usr/bin/gnuinstall 100 2>/dev/null; make WORKFLOW=1 CAMERA=$CAMERA $*"
}

# Thingino builds into output/<git branch>/<camera>-<kernel>-<libc>/ (prepare.sh
# put the tree on branch ciao; docs/build.md's output/HEAD/ was a detached
# checkout). The rootfs carries BUILD_ID = branch+hash, so a moved tree means a
# new output directory and a full build.
BRANCH=$(git -C "$TREE" rev-parse --abbrev-ref HEAD)
OUT=""
for d in "$TREE/output/$BRANCH/$CAMERA"-*; do
	[ -d "$d" ] || continue
	if [ -n "$OUT" ]; then
		echo "more than one output directory for $CAMERA under $TREE/output/$BRANCH (different kernel or libc builds?): remove the stale one" >&2
		ls -d "$TREE/output/$BRANCH/$CAMERA"-* >&2
		exit 1
	fi
	OUT=$d
done
if [ -n "$OUT" ]; then
	# the images are made from the partitions' directories: make's timestamps
	# do not see a changed file of the user layer, so they are removed to be
	# remade (the rootfs image is rebuilt by every Buildroot run anyway)
	rm -f "$OUT"/images/data.jffs2 "$OUT"/images/rootfs.squashfs "$OUT"/images/thingino-"$CAMERA".bin
fi

REBUILD=$TREE/user/$CAMERA/.rebuild
if [ -s "$REBUILD" ] && [ -n "$OUT" ]; then
	# patches prepare.sh has just applied: Buildroot would keep the stale
	# build of those packages
	for pkg in $(sort -u "$REBUILD"); do
		echo "Rebuilding $pkg (patched)"
		in_tree "rebuild-$pkg"
	done
fi
rm -f "$REBUILD"
echo "Building the firmware (incremental; the first run compiles everything)"
in_tree fast
echo "Building ffmpeg (for the SD card)"
in_tree br-thingino-ffmpeg

OUT=$(ls -d "$TREE/output/$BRANCH/$CAMERA"-* 2>/dev/null | head -n 1)
[ -n "$OUT" ] || { echo "no output directory for $CAMERA under $TREE/output/$BRANCH" >&2; exit 1; }
BIN=$OUT/images/thingino-$CAMERA.bin
if [ ! -f "$BIN" ]; then
	echo "no image was produced: $BIN (see the make output above)" >&2
	exit 1
fi
size=$(wc -c <"$BIN" | tr -d ' ')
if [ "$size" != 16777216 ]; then
	echo "unexpected image size $size (16 MB flash expected): $BIN" >&2
	exit 1
fi

build_id=$(sed -n 's/^BUILD_ID="\(.*\)"/\1/p' "$OUT/target/etc/os-release")
case "$build_id" in
"ciao+da40db6, "*) ;;
"") echo "no BUILD_ID in $OUT/target/etc/os-release" >&2; exit 1 ;;
*) echo "WARNING: BUILD_ID is '$build_id', not ciao+da40db6: device/common.sh will refuse this image (see prepare.sh)" >&2 ;;
esac
FFMPEG=$OUT/per-package/thingino-ffmpeg/target/usr/bin/ffmpeg
if [ ! -f "$FFMPEG" ]; then
	echo "ffmpeg was not built: $FFMPEG" >&2
	exit 1
fi
mkdir -p "$REPO/dist/firmware"
cp "$BIN" "$REPO/dist/firmware/thingino-$CAMERA.bin"
echo "$build_id" >"$REPO/dist/firmware/BUILD"
# the version prepare.sh wrote into the image (not computed again: the tree
# may have moved during a long build)
sed -n 's/^VERSION=//p' "$OUT/target/etc/lapcam-release" >"$REPO/dist/firmware/VERSION"
[ -s "$REPO/dist/firmware/VERSION" ] || { echo "no VERSION in $OUT/target/etc/lapcam-release" >&2; exit 1; }
# the files must be in the rootfs image itself, not only in the target
# directory. unsquashfs is the build's own (host/bin), a binary made in the
# builder container, so it is run there: on the host it may not start
rel=${OUT#"$TREE"/}
if ! listing=$(docker run --rm --user "$(id -u):$(id -g)" -v "$TREE":/workspace -w /workspace "$IMAGE" \
	"/workspace/$rel/host/bin/unsquashfs" -l "/workspace/$rel/images/rootfs.squashfs"); then
	echo "could not list $OUT/images/rootfs.squashfs with the build's unsquashfs (see the message above)" >&2
	exit 1
fi
if ! printf '%s\n' "$listing" | grep -q '/etc/lapcam-release$'; then
	echo "rootfs.squashfs has no /etc/lapcam-release: lapcam's files did not get into the rootfs (BR2_ROOTFS_OVERLAY in user/$CAMERA/local.fragment?)" >&2
	exit 1
fi
if [ -f "$FFMPEG" ]; then
	cp "$FFMPEG" "$REPO/dist/ffmpeg"
	# ffmpeg carries no version string of its own: the firmware's goes next to it
	cp "$REPO/dist/firmware/VERSION" "$REPO/dist/ffmpeg.version"
fi

echo
echo "Image:  dist/firmware/thingino-$CAMERA.bin (lapcam $(cat "$REPO/dist/firmware/VERSION"), $(cat "$REPO/dist/firmware/BUILD"))"
echo "        kernel $(wc -c <"$OUT/images/uImage" | tr -d ' ') B, rootfs $(wc -c <"$OUT/images/rootfs.squashfs" | tr -d ' ') B, data $(wc -c <"$OUT/images/data.jffs2" | tr -d ' ') B"
[ -f "$FFMPEG" ] && echo "ffmpeg: dist/ffmpeg ($(wc -c <"$REPO/dist/ffmpeg" | tr -d ' ') B)"
echo "Next: firmware/make-sdcard.sh (on the PC with the SD card)"
