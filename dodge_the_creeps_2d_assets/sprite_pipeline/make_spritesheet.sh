#!/usr/bin/env bash
# 2D 角色视频 → 透明背景精灵图（macOS）
#
# 一条命令跑完：抽帧 → Vision 前景分割 → 去白底污染 → 锚点对齐 → 打包 PNG。
#
#   ./make_spritesheet.sh <video.mp4> [选项]
#
# 常用：
#   ./make_spritesheet.sh hero.mp4 --start 3.0 --frames 16
#   ./make_spritesheet.sh hero.mp4 --frames 8 --cell 256x192 --cols 4
#
# 依赖（首次运行会自动准备）：
#   · Xcode Command Line Tools（swiftc）—— macOS 自带 Vision / AVFoundation
#   · Python 3 + Pillow + numpy —— 脚本会在本目录建 .venv 并安装
#
# 设计取舍与踩坑记录见 README.md。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/.bin"
SWIFTC="${SWIFTC:-swiftc}"

VIDEO=""
FRAMES=16
START=0
END=""
CELL="256x192"
COLS=4
MARGIN=8
FPS=10
OUT=""
WORK=""
DECONTAM=1
DO_GIF=1
DO_PREVIEW=1
KEEP_WORK=1

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

选项：
  --start <秒>        抽帧起点，默认 0
  --end <秒>          抽帧终点，默认视频结尾
  --frames <N>        抽多少帧，默认 16
  --cell <WxH>        单元格尺寸，默认 256x192
  --cols <N>          列数，默认 4（行数自动 = ceil(frames/cols)）
  --margin <px>       安全边距，默认 8
  --fps <N>           GIF 预览帧率，默认 10
  --out <path>        输出 PNG，默认 <视频目录>/<视频名>_spritesheet_<N>f.png
  --work <dir>        中间帧目录，默认在临时目录
  --no-decontaminate  跳过白底去污染
  --no-gif            不生成 GIF 预览
  --no-preview        不生成深色背景预览
  --clean             成功后删除中间帧目录
  -h, --help          显示帮助
EOF
}

die() { echo "错误：$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="$2"; shift 2 ;;
    --end) END="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --cell) CELL="$2"; shift 2 ;;
    --cols) COLS="$2"; shift 2 ;;
    --margin) MARGIN="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --no-decontaminate) DECONTAM=0; shift ;;
    --no-gif) DO_GIF=0; shift ;;
    --no-preview) DO_PREVIEW=0; shift ;;
    --clean) KEEP_WORK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知参数：$1（用 --help 看用法）" ;;
    *) [[ -z "$VIDEO" ]] || die "只能指定一个视频"; VIDEO="$1"; shift ;;
  esac
done

[[ -n "$VIDEO" ]] || { usage; exit 2; }
[[ -f "$VIDEO" ]] || die "找不到视频：$VIDEO"
[[ "$FRAMES" =~ ^[0-9]+$ ]] && (( FRAMES > 0 )) || die "--frames 必须是正整数"
[[ "$CELL" =~ ^[0-9]+x[0-9]+$ ]] || die "--cell 格式应为 256x192"

# ---- 工具链 ----
command -v "$SWIFTC" >/dev/null 2>&1 || die "需要 Xcode Command Line Tools（swiftc）。运行：xcode-select --install"

mkdir -p "$BIN"
compile() {
  local src="$1" out="$2"
  if [[ ! -x "$out" || "$src" -nt "$out" ]]; then
    echo "编译 $(basename "$src")…"
    "$SWIFTC" -O "$src" -o "$out"
  fi
}
compile "$HERE/swift/extract_frames.swift" "$BIN/extract_frames"
compile "$HERE/swift/cutout_vision.swift" "$BIN/cutout_vision"

PY="$HERE/.venv/bin/python"
if [[ ! -x "$PY" ]]; then
  echo "首次运行：创建 Python 虚拟环境…"
  python3 -m venv "$HERE/.venv"
fi
if ! "$PY" -c "import PIL, numpy" >/dev/null 2>&1; then
  echo "安装 Pillow / numpy…"
  "$PY" -m pip install --quiet --disable-pip-version-check Pillow numpy
fi

# ---- 路径与时间范围 ----
if [[ -z "$END" ]]; then
  END="$("$BIN/extract_frames" --duration "$VIDEO")"
fi
if [[ -z "$OUT" ]]; then
  dir="$(cd "$(dirname "$VIDEO")" && pwd)"
  base="$(basename "${VIDEO%.*}")"
  OUT="$dir/${base}_spritesheet_${FRAMES}f.png"
fi
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT="$OUT_DIR/$(basename "$OUT")"

if [[ -z "$WORK" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/sprite_pipeline.XXXXXX")"
fi
mkdir -p "$WORK/raw" "$WORK/cut"
echo "工作目录：$WORK"

# ---- 1. 抽帧 ----
echo "抽帧：${START}s → ${END}s，共 ${FRAMES} 帧"
"$BIN/extract_frames" "$VIDEO" "$WORK/raw" "$START" "$END" "$FRAMES"

# ---- 2. 前景分割 ----
echo "前景分割…"
fail=0
for f in "$WORK"/raw/f_*.png; do
  b="$(basename "$f")"
  if ! "$BIN/cutout_vision" "$f" "$WORK/cut/$b"; then
    fail=$((fail + 1))
  fi
done
(( fail == 0 )) || die "有 ${fail} 帧前景分割失败（可能是主体不够明确）"

# ---- 3. 打包 ----
PACK_ARGS=(
  --input "$WORK/cut"
  --output "$OUT"
  --cell "$CELL"
  --cols "$COLS"
  --margin "$MARGIN"
  --fps "$FPS"
)
if (( DO_GIF == 1 )); then
  PACK_ARGS+=(--gif "${OUT%.png}.gif")
fi
if (( DO_PREVIEW == 1 )); then
  PACK_ARGS+=(--preview "${OUT%.png}_preview.png")
fi
if (( DECONTAM == 0 )); then
  PACK_ARGS+=(--no-decontaminate)
fi

"$PY" "$HERE/python/pack_spritesheet.py" "${PACK_ARGS[@]}"

if (( KEEP_WORK == 0 )); then
  rm -rf "$WORK"
  echo "已清理中间帧。"
else
  echo "中间帧保留在：$WORK"
fi
