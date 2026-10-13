#!/usr/bin/env bash
#
# StrikeShard 机制验证入口。
#
#   bash tools/verify.sh              # 机制回归（默认，几秒）
#   bash tools/verify.sh --energy     # 冻结/动能 A/B 测量（慢，约 20 秒）
#   bash tools/verify.sh --fresh      # 丢掉临时副本重新导入（新加了美术资源后才需要）
#
# 退出码：0 全过 / 1 有失败 / 2 环境问题（找不到 Godot 之类）
#
# ─── 为什么要拷一份再跑 ────────────────────────────────────────────────
# 你开着 Godot 编辑器时，编辑器占着项目里的 `.godot/` 缓存。直接对项目根跑 headless
# 会跟它抢这份缓存。所以这里把项目拷到临时目录再跑 —— 顺带保证探针**碰不到你的工作区**。
#
# 这条操作知识写在这儿而不是文档里，是因为**脚本比文档强**：文档会被跳过，脚本跑一次就教会了。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# $TMPDIR 在 macOS 上以 `/` 结尾，去掉免得拼出双斜杠
_TMP="${TMPDIR:-/tmp}"
WORK="${STRIKESHARD_VERIFY_DIR:-${_TMP%/}/strikeshard-verify}"
PROBE="mechanism_probe.gd"
FRESH=0

for arg in "$@"; do
  case "$arg" in
    --energy) PROBE="energy_probe.gd" ;;
    --all)    PROBE="all" ;;
    --fresh)  FRESH=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数：${arg}（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

# ─── 找 Godot ────────────────────────────────────────────────────────
find_godot() {
  local c
  for c in \
    "${GODOT:-}" \
    "$HOME/Downloads/godot/Godot.app/Contents/MacOS/Godot" \
    "/Applications/Godot.app/Contents/MacOS/Godot" \
    "$(command -v godot 2>/dev/null || true)" \
    "$(command -v godot4 2>/dev/null || true)"
  do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

GODOT_BIN="$(find_godot)" || {
  echo "找不到 Godot 可执行文件。" >&2
  echo "用法：GODOT=/path/to/Godot bash tools/verify.sh" >&2
  echo "本机默认在 ~/Downloads/godot/Godot.app/Contents/MacOS/Godot（不在 /Applications，也不在 PATH 上）。" >&2
  exit 2
}

# ─── 拷一份到临时目录 ────────────────────────────────────────────────
# 排除项里的目录**受 --delete 保护**，不会因为在临时副本里不存在而被清掉。
if [[ "$FRESH" == "1" ]]; then
  echo "· --fresh：丢掉旧的临时副本"
  rm -rf "$WORK"
fi
mkdir -p "$WORK"
rsync -a --delete \
  --exclude='.godot/' --exclude='.git/' \
  --exclude='tools/' --exclude='design/' --exclude='tmp/' \
  --exclude='.claude/' --exclude='.codex/' --exclude='.trae/' --exclude='.raven/' \
  "$ROOT/" "$WORK/"

if [[ ! -d "$WORK/.godot" ]]; then
  echo "· 首次运行：先在临时副本里导入一次资源（要一两分钟，之后就快了）"
  "$GODOT_BIN" --headless --path "$WORK" --import >/dev/null 2>&1
fi

# ─── 全局类注册表（`class_name`）──────────────────────────────────────
# ⚠️ 临时副本里的 `.godot/` 不会自动跟着脚本走：**新增或删掉 `class_name` 之后不重新扫，
# 探针会以 `Could not find type "Xxx"` 解析失败**，而且看起来像"某个功能没生效"
#（踩过：加了 `class_name GameFlow` 之后 bot 整个不跑，卡在敌方回合）。
#
# 扫一次要 5 秒（在已导入的项目上），所以只在**类的集合真的变了**时才扫 ——
# 普通改代码不需要，那只影响脚本内容，缓存里本来就只有类名。
CLASSES="$(grep -h '^class_name ' "$ROOT"/scripts/*.gd 2>/dev/null | awk '{print $2}' | sort | tr '\n' ' ')"
STAMP_FILE="$ROOT/tmp/.verify-classes"
if [[ ! -d "$WORK/.godot" || "$CLASSES" != "$(cat "$STAMP_FILE" 2>/dev/null)" ]]; then
  echo "· 类注册表变了，重新扫一遍脚本（约 5 秒）"
  "$GODOT_BIN" --headless --path "$WORK" --import >/dev/null 2>&1
  mkdir -p "$ROOT/tmp"
  printf '%s' "$CLASSES" >"$STAMP_FILE"
fi

# ─── 把探针拷进副本 ──────────────────────────────────────────────────
# 仓库里 `tools/` 被 `.gdignore` 挡在资源树外（编辑器看不见探针）；
# 在这里拷进 `res://probe/`，Godot 才看得见它们。
rm -rf "$WORK/probe"
mkdir -p "$WORK/probe"
cp "$ROOT"/tools/probe/*.gd "$WORK/probe/"

# ─── 跑 ──────────────────────────────────────────────────────────────
run_one() {
  local script="$1" out="$WORK/probe-out.txt" code
  "$GODOT_BIN" --headless --path "$WORK" --script "res://probe/$script" >"$out" 2>&1
  code=$?
  # 过滤已知噪声：Mob 的贴图还没配动画，每个物理帧刷一条警告（见 design/10-turn/DESIGN.md）。
  # 只掐这一个已知块（警告行 + 紧随的 5 行调用栈），别的原样放行。
  awk '
    /的 AnimatedSprite2D 里没有动画/ { skip = 5; n++; next }
    skip > 0 { skip--; next }
    { print }
    END { if (n > 0) printf "  （已折叠 %d 条「Mob 缺动画」警告 —— 那是待办的美术工作，不是回归失败）\n", n }
  ' "$out"
  return $code
}

STATUS=0
if [[ "$PROBE" == "all" ]]; then
  run_one mechanism_probe.gd; [[ $? -ne 0 ]] && STATUS=1
  run_one energy_probe.gd;    [[ $? -ne 0 ]] && STATUS=1
else
  run_one "$PROBE" || STATUS=$?
fi

# ─── 收尾 ────────────────────────────────────────────────────────────
if [[ "$STATUS" == "0" ]]; then
  mkdir -p "$ROOT/tmp"
  date >"$ROOT/tmp/.last-verify"
  echo
  echo "验证通过。（临时副本留在 ${WORK}，下次跑得快些；要清干净就 --fresh）"
else
  echo
  echo "验证未通过（退出码 ${STATUS}）。完整输出：$WORK/probe-out.txt" >&2
fi
exit "$STATUS"
