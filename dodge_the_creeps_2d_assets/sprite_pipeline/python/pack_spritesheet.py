#!/usr/bin/env python3
"""把已抠好的透明帧打包成精灵图（PNG），可选输出 GIF 预览。

设计要点（都是踩过的坑，改之前先读）：

1. **锚点 = 躯干质心，不是包围盒中心**
   角色手里的长矛会把包围盒拉向一侧。按包围盒居中，身体会偏到格子左边，
   游戏里就得给每一帧算不同偏移量。按躯干质心居中，偏移量是常数。

2. **左右留白对称**
   以锚点为中心向两侧取相同的半宽 M，M 取所有帧里左右最大超伸的较大者。
   于是"长矛向右伸 x，左边也空 x"——锚点永远在格子水平中心。

3. **统一全局缩放，不逐帧缩放**
   逐帧按包围盒缩放会让角色在动画里"呼吸"，还会放大测量噪声。
   只允许一个 scale，保留原动作的位移与比例。

4. **底部对齐**
   脚/地面是棋子的稳定接触点。垂直方向按内容框底部对齐，不按包围盒中心。

5. **白底去污染**
   半透明边缘像素的 RGB 往往混了白背景，深色棋盘上会变成白边。
   按 C = A·F + (1-A)·白 反解 F，只改 RGB，不动 alpha。

6. **预乘 alpha 再缩放**
   Pillow 的 RGBA 缩放不预乘，直接缩会在透明边缘产生白边/黑边。
   这里先乘 alpha、缩放、再反预乘。

7. **裁剪框可以越界**
   对称留白可能要求左边超出原图。越界时把帧贴到更大的透明画布上，
   而不是把裁剪框夹回图内（夹回去会破坏对称）。
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image


# ---------------------------------------------------------------- 图像处理


def decontaminate_white(im: Image.Image) -> Image.Image:
    """去掉半透明边缘里的白背景残色。alpha 不变。"""
    arr = np.asarray(im).astype(np.float32) / 255.0
    rgb, alpha = arr[..., :3], arr[..., 3:4]
    # C = A·F + (1-A)·1  →  F = (C - (1-A)) / A
    fg = (rgb - (1.0 - alpha)) / np.maximum(alpha, 0.08)
    fg = np.clip(fg, 0.0, 1.0)
    # alpha 太低时除法会放大噪声，保持原样
    fg = np.where(alpha < 0.08, rgb, fg)
    out = np.concatenate([fg, alpha], axis=-1)
    return Image.fromarray((out * 255).round().astype(np.uint8))


def resize_premult(im: Image.Image, size: tuple[int, int]) -> Image.Image:
    """预乘 alpha 的缩放，避免透明边缘出现白边/黑边。"""
    arr = np.asarray(im).astype(np.float32) / 255.0
    rgb, alpha = arr[..., :3], arr[..., 3:4]
    pm = np.concatenate([rgb * alpha, alpha], axis=-1)
    pm_im = Image.fromarray((pm * 255).round().clip(0, 255).astype(np.uint8))
    resized = np.asarray(pm_im.resize(size, Image.LANCZOS)).astype(np.float32) / 255.0
    rgb2, alpha2 = resized[..., :3], resized[..., 3:4]
    straight = np.concatenate([rgb2 / np.maximum(alpha2, 1e-6), alpha2], axis=-1)
    return Image.fromarray((straight.clip(0, 1) * 255).round().astype(np.uint8))


def torso_anchor(im: Image.Image):
    """返回 (躯干质心 x, 可见像素 y0, y1, alpha bbox)。

    躯干 = 包围盒上部 55%。实测比脚部质心稳得多：
    跑步姿势下脚在动，脚部质心 std 14.5px；躯干质心 std 5.1px。
    """
    alpha = np.asarray(im.getchannel("A")).astype(np.float32)
    ys, xs = np.nonzero(alpha > 8)
    if len(xs) == 0:
        return None
    y0, y1 = int(ys.min()), int(ys.max()) + 1
    band = alpha[y0 : y0 + max(1, int((y1 - y0) * 0.55)), :]
    yy, xx = np.nonzero(band > 8)
    if len(xx) == 0:
        return None
    cx = float((band[yy, xx] * xx).sum() / band[yy, xx].sum())
    bbox = im.getchannel("A").getbbox()
    return cx, y0, y1, bbox


# ---------------------------------------------------------------- 主流程


def parse_cell(text: str) -> tuple[int, int]:
    try:
        w, h = text.lower().split("x")
        w, h = int(w), int(h)
    except ValueError:
        raise argparse.ArgumentTypeError("--cell 格式应为 256x192")
    if w <= 0 or h <= 0:
        raise argparse.ArgumentTypeError("--cell 必须为正")
    return w, h


def main() -> int:
    ap = argparse.ArgumentParser(description="透明帧 → 精灵图 PNG")
    ap.add_argument("--input", required=True, help="抠好的透明帧目录（f_00.png …）")
    ap.add_argument("--output", required=True, help="输出精灵图 PNG")
    ap.add_argument("--cell", type=parse_cell, default=(256, 192), help="单元格 WxH，默认 256x192")
    ap.add_argument("--cols", type=int, default=4, help="列数，默认 4")
    ap.add_argument("--margin", type=int, default=8, help="安全边距（像素），默认 8")
    ap.add_argument("--fps", type=float, default=10.0, help="GIF 预览帧率，默认 10")
    ap.add_argument("--gif", default=None, help="GIF 预览输出路径（可选）")
    ap.add_argument("--preview", default=None, help="深色背景预览 PNG（可选）")
    ap.add_argument("--take", type=int, default=0, help="从输入帧里均匀取 N 帧（0 = 全取）")
    ap.add_argument("--no-decontaminate", action="store_true", help="跳过白底去污染")
    args = ap.parse_args()

    src_dir = Path(args.input)
    files = sorted(src_dir.glob("*.png"))
    if not files:
        print(f"错误：{src_dir} 里没有 PNG", file=sys.stderr)
        return 2
    if args.take and args.take > 0:
        if args.take > len(files):
            print(f"错误：--take {args.take} 超过输入帧数 {len(files)}", file=sys.stderr)
            return 2
        step = len(files) / args.take
        files = [files[min(len(files) - 1, int((i + 0.5) * step))] for i in range(args.take)]

    cell_w, cell_h = args.cell
    frames = []
    for p in files:
        im = Image.open(p).convert("RGBA")
        if not args.no_decontaminate:
            im = decontaminate_white(im)
        info = torso_anchor(im)
        if info is None:
            print(f"错误：{p.name} 没有可见像素（前景分割失败？）", file=sys.stderr)
            return 3
        frames.append((p.name, im, *info))

    sizes = {(im.width, im.height) for _, im, *_ in frames}
    if len(sizes) != 1:
        print(f"错误：输入帧尺寸不一致：{sizes}", file=sys.stderr)
        return 3

    anchor = sum(f[2] for f in frames) / len(frames)
    half_width = max(max(anchor - f[5][0], f[5][2] - anchor) for f in frames)

    crop_x0 = round(anchor - half_width - args.margin)
    crop_x1 = round(anchor + half_width + args.margin)
    crop_y0 = min(f[3] for f in frames) - args.margin
    crop_y1 = max(f[4] for f in frames) + args.margin
    crop_w, crop_h = crop_x1 - crop_x0, crop_y1 - crop_y0

    scale = min((cell_w - 2 * args.margin) / crop_w, (cell_h - 2 * args.margin) / crop_h)
    out_w, out_h = round(crop_w * scale), round(crop_h * scale)

    cols = max(1, args.cols)
    rows = math.ceil(len(frames) / cols)
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (0, 0, 0, 0))

    for i, (_, im, *_rest) in enumerate(frames):
        # 裁剪框可能越界：贴到更大的透明画布上，保持对称
        canvas = Image.new("RGBA", (crop_w, crop_h), (0, 0, 0, 0))
        canvas.alpha_composite(im, (-crop_x0, -crop_y0))
        piece = resize_premult(canvas, (out_w, out_h))

        # 让锚点落在格子水平中心，而不是让内容框居中
        px = round(cell_w / 2 - (anchor - crop_x0) * scale)
        py = cell_h - args.margin - out_h
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        sheet.alpha_composite(piece, (x + px, y + py))

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_path)

    # ---- QA 摘要 ----
    left_over, right_over, heights, edge_px, white_px = [], [], [], 0, 0
    for i in range(len(frames)):
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        cell = sheet.crop((x, y, x + cell_w, y + cell_h))
        arr = np.asarray(cell).astype(np.float32)
        alpha = arr[..., 3]
        bb = cell.getchannel("A").getbbox()
        if bb is None:
            continue
        left_over.append(cell_w // 2 - bb[0])
        right_over.append(bb[2] - cell_w // 2)
        heights.append(bb[3] - bb[1])
        edge = (alpha > 20) & (alpha < 250)
        rgb = arr[edge][:, :3]
        if len(rgb):
            mx, mn = rgb.max(axis=1), rgb.min(axis=1)
            edge_px += len(rgb)
            white_px += int(((mx > 225) & ((mx - mn) < 20)).sum())

    print("== 精灵图 ==")
    print(f"  输出      : {out_path}  ({sheet.width}x{sheet.height}, {len(frames)} 帧, {cols} 列 x {rows} 行)")
    print(f"  单元格    : {cell_w}x{cell_h}  安全边距 {args.margin}px")
    print(f"  裁剪框    : x[{crop_x0},{crop_x1}) y[{crop_y0},{crop_y1})  {crop_w}x{crop_h}")
    print(f"  锚点      : {anchor:.1f}px（源图尺度）  半宽 M={half_width:.1f}px")
    print(f"  缩放      : {scale:.4f}  内容 {out_w}x{out_h}")
    print(f"  左右超伸  : 左 max {max(left_over)}  /  右 max {max(right_over)}  （锚点在格子中心，两侧各 {cell_w // 2}px）")
    print(f"  内容高度  : {min(heights)}~{max(heights)}px")
    if edge_px:
        print(f"  边缘接近白: {white_px / edge_px * 100:.1f}%（越低越好）")

    problems = []
    for i in range(len(frames)):
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        bb = sheet.crop((x, y, x + cell_w, y + cell_h)).getchannel("A").getbbox()
        if bb is None:
            problems.append(f"第 {i} 帧为空")
        elif bb[0] < args.margin or bb[1] < args.margin or bb[2] > cell_w - args.margin or bb[3] > cell_h - args.margin:
            problems.append(f"第 {i} 帧触到安全边距: {bb}")

    if args.gif:
        gif_path = Path(args.gif)
        gif_path.parent.mkdir(parents=True, exist_ok=True)
        cells = []
        for i in range(len(frames)):
            x, y = (i % cols) * cell_w, (i // cols) * cell_h
            cells.append(sheet.crop((x, y, x + cell_w, y + cell_h)))
        cells[0].save(
            gif_path,
            save_all=True,
            append_images=cells[1:],
            duration=max(20, round(1000 / max(0.1, args.fps))),
            loop=0,
            disposal=2,
        )
        print(f"  GIF 预览  : {gif_path}  ({args.fps:g} fps)")

    if args.preview:
        prev_path = Path(args.preview)
        prev_path.parent.mkdir(parents=True, exist_ok=True)
        bg = Image.new("RGBA", sheet.size, (32, 34, 38, 255))
        bg.alpha_composite(sheet)
        bg.convert("RGB").save(prev_path)
        print(f"  深色预览  : {prev_path}")

    if problems:
        print("== 警告 ==", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 4

    print("  安全边距  : 全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
