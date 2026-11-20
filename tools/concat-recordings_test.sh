#!/bin/sh
# concat-recordings_test.sh - tools/concat-recordings.sh against clips made
# with ffmpeg (2 s each, named like the recorder names them):
#   sh tools/concat-recordings_test.sh
# Checks: clips that follow each other become one file, a pause starts a new
# file, midnight is not a pause, a new day folder at a later time is, and the
# two ways of naming the output. Skipped when ffmpeg is not installed.

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || {
	echo "skip: ffmpeg/ffprobe not installed"
	exit 0
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
clip() { # clip <path>: 2 s of video + audio
	mkdir -p "$(dirname "$1")"
	ffmpeg -v error -y -f lavfi -i testsrc=size=64x48:rate=10 -f lavfi -i sine=sample_rate=16000 \
		-t 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac "$1"
}
secs() { # secs <file>: length in whole seconds, rounded
	ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" | awk '{printf "%d", $1 + 0.5}'
}
# the lines "<n> clips -> <path>" of a run, as "<n>:<file name>" joined by spaces
run() {
	GAP=1 sh "$HERE/concat-recordings.sh" "$@" | sed -n 's|^\([0-9]*\) clips -> .*/\(.*\)$|\1:\2|p' | tr '\n' ' '
}

# two recordings on one day; the second runs over midnight; a third starts on
# the day after at a later time of day than the last clip before it
R=$T/recordings
for c in 2026/11/20/18-00-00 2026/11/20/18-00-02 2026/11/20/18-00-04 \
	2026/11/20/23-59-58 2026/11/21/00-00-00 2026/11/21/00-00-02 \
	2026/11/22/00-00-04; do
	clip "$R/$c.mp4"
done

mkdir "$T/out"
got=$(run "$R" "$T/out")
want="3:rec-2026-11-20_18-00-00.mp4 3:rec-2026-11-20_23-59-58.mp4 1:rec-2026-11-22_00-00-04.mp4 "
[ "$got" = "$want" ] || fail "output dir: $got"
n=$(secs "$T/out/rec-2026-11-20_18-00-00.mp4")
[ "$n" -eq 6 ] || fail "3 clips of 2 s are $n s long"
n=$(secs "$T/out/rec-2026-11-22_00-00-04.mp4")
[ "$n" -eq 2 ] || fail "1 clip of 2 s is $n s long"

got=$(run "$R" "$T/all.mp4")
[ "$got" = "3:all-1.mp4 3:all-2.mp4 1:all-3.mp4 " ] || fail "output file, 3 recordings: $got"
[ ! -e "$T/all.mp4" ] || fail "all.mp4 written although there are 3 recordings"

got=$(run "$R/2026/11/22" "$T/one.mp4")
[ "$got" = "1:one.mp4 " ] || fail "output file, 1 recording: $got"

# names that are not %H-%M-%S: never split, named after the first clip
clip "$T/flat/a.mp4"
clip "$T/flat/b.mp4"
got=$(run "$T/flat" "$T/out")
[ "$got" = "2:rec-a.mp4 " ] || fail "other names: $got"

if sh "$HERE/concat-recordings.sh" "$T/out-none" "$T/x.mp4" 2>/dev/null; then
	fail "no clips: exit 0"
fi

echo "ok"
