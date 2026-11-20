#!/bin/sh
# concat-recordings.sh - join prudynt recorder clips (1 file per minute) into
# one MP4 per recording
#
#   tools/concat-recordings.sh <clip dir> <output.mp4 | output dir>
#
# Needs ffmpeg/ffprobe on the Mac (brew install ffmpeg). No re-encoding.
#
# One recording = clips that follow each other without a pause. Where the
# clock in the file names (%H-%M-%S.mp4) jumps further than the previous clip
# was long (Stop recording, then Record again later), a new output starts:
#   <output dir>   rec-2026-11-20_18-25-30.mp4, rec-2026-11-20_22-26-21.mp4, ...
#                  (named after the first clip of each recording)
#   <output.mp4>   output.mp4 when there is one recording, otherwise
#                  output-1.mp4, output-2.mp4, ...
# GAP=<seconds> is how far the jump may exceed the clip length before it counts
# as a pause (default 3: the names are whole seconds and the clips ~60.1 s).
# Clips whose names are not %H-%M-%S.mp4 are never split.
#
# Why not a plain `ffmpeg -f concat -c copy`: prudynt's SimpleMP4Muxer does not
# keep the video and audio tracks on the same time base from one file to the
# next (video may start at 179.8s while audio starts at 0s). A plain concat
# then stretches the result to several times its real length. So each clip is
# split into a video-only and an audio-only file, both re-based to start at 0,
# the two tracks are concatenated separately with the audio clip lengths as
# the offsets for both (the video clock runs ~10 s/h slow against the audio
# clock, so audio is the reference), and finally muxed back together.
set -eu

USAGE="usage: $0 <clip dir> <output.mp4 | output dir>"
DIR=${1:?$USAGE}
OUT=${2:?$USAGE}
GAP=${GAP:-3}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/v" "$WORK/a"
: >"$WORK/sessions"

# Clips are numbered in sorted path order: the recorder's file names repeat
# across days (%Y/%m/%d/%H-%M-%S), so the basename alone is not unique. The
# concat lists use paths relative to the list file, so $WORK needs no quoting.
i=0
s=0     # recording number
pt=     # previous clip: start (seconds of the day, from its name), length, folder
pdur=0
pdir=
find "$DIR" -name '*.mp4' -print | sort | while IFS= read -r f; do
	i=$((i + 1))
	b=$(printf '%06d.mp4' "$i")
	ffmpeg -nostdin -v error -y -i "$f" -map 0:v -c copy -avoid_negative_ts make_zero "$WORK/v/$b"
	ffmpeg -nostdin -v error -y -i "$f" -map 0:a -c copy -avoid_negative_ts make_zero "$WORK/a/$b"
	# audio span of this clip (last packet's pts + its duration) = offset for
	# the next clip in both tracks. Falls back to one AAC frame (1024 samples)
	# when ffprobe gives no packet duration.
	sr=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 "$WORK/a/$b")
	dur=$(ffprobe -v error -select_streams a:0 -show_entries packet=pts_time,duration_time -of csv=p=0 "$WORK/a/$b" |
		awk -F, -v sr="${sr:-16000}" '{last=$1; d=$2} END{if (d !~ /^[0-9.]+$/) d = 1024 / sr; printf "%.3f", last + d}')

	# Same recording as the previous clip? Not when this one starts later than
	# the previous one ended (+GAP). A start that went backwards is midnight;
	# a new day folder without going backwards is a pause of a day or more.
	d=$(dirname "$f")
	t=$(basename "$f" | awk -F'[-.]' '/^[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.mp4$/ {print $1 * 3600 + $2 * 60 + $3}')
	new=0
	if [ "$s" -eq 0 ]; then
		new=1
	elif [ -n "$t" ] && [ -n "$pt" ]; then
		[ "$d" = "$pdir" ] && same=1 || same=0
		new=$(awk -v t="$t" -v pt="$pt" -v pdur="$pdur" -v gap="$GAP" -v same="$same" 'BEGIN {
			jump = t - pt
			if (jump < 0) jump += 86400
			else if (!same) { print 1; exit }
			print (jump > pdur + gap) ? 1 : 0
		}')
	fi
	if [ "$new" -eq 1 ]; then
		s=$((s + 1))
		# name for the output dir form: date from the %Y/%m/%d folders when
		# the clip sits in them, plus the clip's own name
		name=$(printf '%s\n' "$f" | sed -n 's|.*/\([0-9]\{4\}\)/\([0-9][0-9]\)/\([0-9][0-9]\)/\([^/]*\)\.mp4$|\1-\2-\3_\4|p')
		[ -n "$name" ] || name=$(basename "$f" .mp4)
		printf '%s\n' "rec-$name.mp4" >>"$WORK/sessions"
	fi
	pt=$t
	pdur=$dur
	pdir=$d

	printf "file 'v/%s'\nduration %s\n" "$b" "$dur" >>"$WORK/v-$s.txt"
	printf "file 'a/%s'\nduration %s\n" "$b" "$dur" >>"$WORK/a-$s.txt"
done
total=$(wc -l <"$WORK/sessions")
[ "$total" -gt 0 ] || { echo "no .mp4 files under $DIR" >&2; exit 1; }

s=0
while IFS= read -r name; do
	s=$((s + 1))
	if [ -d "$OUT" ]; then
		out=$OUT/$name
	elif [ "$total" -eq 1 ]; then
		out=$OUT
	else
		out=${OUT%.mp4}-$s.mp4
	fi
	ffmpeg -nostdin -v error -y -f concat -safe 0 -i "$WORK/v-$s.txt" -c copy "$WORK/v-all.mp4"
	ffmpeg -nostdin -v error -y -f concat -safe 0 -i "$WORK/a-$s.txt" -c copy "$WORK/a-all.mp4"
	ffmpeg -nostdin -v error -y -i "$WORK/v-all.mp4" -i "$WORK/a-all.mp4" -map 0:v -map 1:a -c copy "$out"

	echo "$(grep -c '^file ' "$WORK/v-$s.txt") clips -> $out"
	ffprobe -v error -show_entries stream=codec_type,duration -of csv=p=0 "$out"
done <"$WORK/sessions"
