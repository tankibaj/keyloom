#!/bin/zsh
# Master -> loudness-normalised exports. Usage: scripts/export.sh   (run from video/, needs out/master.mp4)
set -euo pipefail
cd "$(dirname "$0")/.."
M=out/master.mp4
# loudness: gain to about -15 LUFS integrated, then a look-ahead limiter well under -1.5 dBTP (checked on the final mp4)
I=$(ffmpeg -hide_banner -i $M -af ebur128 -f null - 2>&1 | grep -E "^\s+I:" | tail -1 | awk '{print $2}')
GAIN=$(python3 -c "print(round(-14.4 - ($I), 2))")
AF="volume=${GAIN}dB,alimiter=limit=0.76:attack=3:release=60:level=disabled"
ffmpeg -hide_banner -y -i $M -vf "scale=1920:-2" -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -movflags +faststart -af "$AF" -c:a aac -b:a 160k out/keyloom.mp4
ffmpeg -hide_banner -y -i $M -vf "fps=25,scale=1920:-2" -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p -movflags +faststart -af "$AF" -c:a aac -b:a 160k out/keyloom-linkedin-25fps.mp4
ffmpeg -hide_banner -y -i $M -vf "fps=30,scale=1920:-2" -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -an out/keyloom.webm
# GIF: 9s of the proof section, 800px, 15fps
ffmpeg -hide_banner -y -ss 14.4 -t 9 -i $M -vf "fps=15,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" out/keyloom.gif
ffmpeg -hide_banner -y -ss 10.9 -i $M -frames:v 1 -q:v 2 out/keyloom-poster.jpg
