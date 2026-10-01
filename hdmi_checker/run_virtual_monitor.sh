#!/bin/sh
# 시뮬레이션으로 HDMI 출력을 받아 가상 모니터 창에 띄운다.
#   ./run_virtual_monitor.sh [프레임 수, 기본 10]
set -e
cd "$(dirname "$0")"

FRAMES=${1:-10}
mkdir -p build

iverilog -g2005 -o build/vmon.vvp \
    sim/tb_virtual_monitor.v \
    rtl/video_timing.v rtl/checkerboard.v rtl/tmds_encoder.v \
    rtl/ball_mover.v rtl/hdmi_core.v rtl/tmds_serializer.v

vvp build/vmon.vvp +FRAMES="$FRAMES" +OUT=build/frame

FILES=""
i=0
while [ "$i" -lt "$FRAMES" ]; do
    FILES="$FILES build/frame_$i.ppm"
    i=$((i + 1))
done
python3 tools/view_frames.py $FILES
