#!/bin/sh
# concat-recordings_test.sh - tools/concat-recordings.sh against clips made
# with ffmpeg (2 s each, named like the recorder names them):
#   sh tools/concat-recordings_test.sh
# Checks: clips that follow each other become one file, a pause starts a new
# file, midnight is not a pause, a new day folder is (at a later time of day,
# and right after midnight days later), GAP, the two ways of naming the
# output (also for a relative clip dir and for names that collide), and that
# the script does not read its own output. Skipped when ffmpeg is not installed.

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
# (G= sets GAP for the run: 1 when not given, G=default leaves GAP unset).
# The output goes through a file so that a run that fails after printing its
# lines is not taken for a good one.
run() {
	(
		if [ "${G:-1}" = default ]; then unset GAP; else export GAP="${G:-1}"; fi
		sh "$HERE/concat-recordings.sh" "$@" >"$T/run.out"
	) || fail "exit $? from: concat-recordings.sh $*"
	sed -n 's|^\([0-9]*\) clips -> .*/\(.*\)$|\1:\2|p' "$T/run.out" | tr '\n' ' '
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

# the same clips through a relative clip dir that begins with the year: the
# date must still be in the names
mkdir "$T/out-rel"
got=$(cd "$R" && run 2026 "$T/out-rel")
[ "$got" = "$want" ] || fail "relative clip dir: $got"

# GAP: the default splits these the same way; one larger than every pause
# joins everything; not a number is refused
mkdir "$T/out-gap"
got=$(G=default run "$R" "$T/out-gap")
[ "$got" = "$want" ] || fail "default GAP: $got"
got=$(G=100000 run "$R" "$T/out-gap")
[ "$got" = "7:rec-2026-11-20_18-00-00.mp4 " ] || fail "GAP=100000: $got"
for g in abc 1m 1.2.3; do
	if GAP=$g sh "$HERE/concat-recordings.sh" "$R" "$T/out-gap" 2>/dev/null; then
		fail "GAP=$g: exit 0"
	fi
done

# ends right before midnight, starts again right after midnight two days later
clip "$T/skip/2026/11/20/23-59-58.mp4"
clip "$T/skip/2026/11/22/00-00-00.mp4"
got=$(run "$T/skip" "$T/out-gap")
[ "$got" = "1:rec-2026-11-20_23-59-58.mp4 1:rec-2026-11-22_00-00-00.mp4 " ] || fail "two days later after midnight: $got"

# two recordings that get the same name: the second one is numbered
clip "$T/same/a/10-00-00.mp4"
clip "$T/same/b/10-00-00.mp4"
mkdir "$T/out-same"
got=$(run "$T/same" "$T/out-same")
[ "$got" = "1:rec-10-00-00.mp4 1:rec-10-00-00-2.mp4 " ] || fail "same name twice: $got"

# output dir = clip dir: the second run must not read the first run's output
got=$(run "$T/flat" "$T/flat")
[ "$got" = "2:rec-a.mp4 " ] || fail "output into the clip dir: $got"
got=$(run "$T/flat" "$T/flat")
[ "$got" = "2:rec-a.mp4 " ] || fail "second run with the output in the clip dir: $got"

# no clips: an empty folder
mkdir "$T/empty"
if err=$(sh "$HERE/concat-recordings.sh" "$T/empty" "$T/x.mp4" 2>&1); then
	fail "no clips: exit 0"
fi
case $err in
"no .mp4 files under "*) ;;
*) fail "no clips: $err" ;;
esac

# every ffmpeg in the script runs with -nostdin: inside the loops it would
# otherwise eat the list the loop reads (with real, minute-long clips the
# second output name lost its first characters; 2 s clips are too short to
# show it, so this is checked on the source)
a=$(grep -c '^[[:space:]]*ffmpeg ' "$HERE/concat-recordings.sh")
b=$(grep -c '^[[:space:]]*ffmpeg -nostdin ' "$HERE/concat-recordings.sh")
[ "$a" -gt 0 ] && [ "$a" -eq "$b" ] || fail "$b of $a ffmpeg calls have -nostdin"

echo "ok"
