#!/usr/bin/env python3
"""Audit and normalize the four-frame cleaning sprite sheet."""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


@dataclass(frozen=True)
class Component:
    area: int
    box: tuple[int, int, int, int]


def components(image: Image.Image, threshold: int = 32) -> list[Component]:
    rgba = image.convert("RGBA")
    black = Image.new("RGBA", rgba.size, (0, 0, 0, 255))
    gray = Image.alpha_composite(black, rgba).convert("L")
    width, height = gray.size
    pixels = gray.load()
    foreground = bytearray(width * height)
    for y in range(height):
        row = y * width
        for x in range(width):
            foreground[row + x] = pixels[x, y] > threshold

    visited = bytearray(width * height)
    found: list[Component] = []
    for y in range(height):
        for x in range(width):
            index = y * width + x
            if not foreground[index] or visited[index]:
                continue
            queue = deque([(x, y)])
            visited[index] = 1
            area = 0
            left = right = x
            top = bottom = y
            while queue:
                current_x, current_y = queue.popleft()
                area += 1
                left = min(left, current_x)
                right = max(right, current_x)
                top = min(top, current_y)
                bottom = max(bottom, current_y)
                for neighbor_y in range(max(0, current_y - 1), min(height, current_y + 2)):
                    for neighbor_x in range(max(0, current_x - 1), min(width, current_x + 2)):
                        neighbor = neighbor_y * width + neighbor_x
                        if foreground[neighbor] and not visited[neighbor]:
                            visited[neighbor] = 1
                            queue.append((neighbor_x, neighbor_y))
            found.append(Component(area, (left, top, right + 1, bottom + 1)))
    return sorted(found, key=lambda item: item.area, reverse=True)


def split_frames(sheet: Image.Image) -> list[Image.Image]:
    width, height = sheet.size
    if width != height or width % 2:
        raise ValueError(f"Expected an even square sprite sheet, got {width}x{height}")
    side = width // 2
    return [
        sheet.crop((0, 0, side, side)),
        sheet.crop((side, 0, width, side)),
        sheet.crop((0, side, side, height)),
        sheet.crop((side, side, width, height)),
    ]


def character_box(frame: Image.Image) -> tuple[int, int, int, int]:
    significant = [component for component in components(frame) if component.area >= 800]
    if not significant:
        raise ValueError("Could not identify the character foreground")
    return (
        min(component.box[0] for component in significant),
        min(component.box[1] for component in significant),
        max(component.box[2] for component in significant),
        max(component.box[3] for component in significant),
    )


def normalize_frame(
    frame: Image.Image,
    target_height: int,
    target_bottom: int,
    target_center_x: float,
) -> tuple[Image.Image, tuple[int, int, int, int], float]:
    left, top, right, bottom = character_box(frame)
    scale = target_height / (bottom - top)
    resized = frame.convert("RGB").resize(
        (round(frame.width * scale), round(frame.height * scale)),
        Image.Resampling.LANCZOS,
    )
    translated_x = round(target_center_x - ((left + right) / 2) * scale)
    translated_y = round(target_bottom - bottom * scale)
    canvas = Image.new("RGB", frame.size, "black")
    canvas.paste(resized, (translated_x, translated_y))
    baseline_adjustment = target_bottom - character_box(canvas)[3]
    if baseline_adjustment:
        adjusted = Image.new("RGB", frame.size, "black")
        adjusted.paste(canvas, (0, baseline_adjustment))
        canvas = adjusted
    return canvas, (left, top, right, bottom), scale


def normalized_sheet(
    frames: list[Image.Image],
    target_height: int,
    target_bottom: int,
) -> tuple[Image.Image, list[tuple[tuple[int, int, int, int], float]]]:
    side = frames[0].width
    target_center_x = side / 2
    normalized: list[Image.Image] = []
    metrics: list[tuple[tuple[int, int, int, int], float]] = []
    for frame in frames:
        output, source_box, scale = normalize_frame(
            frame,
            target_height=target_height,
            target_bottom=target_bottom,
            target_center_x=target_center_x,
        )
        normalized.append(output)
        metrics.append((source_box, scale))

    sheet = Image.new("RGB", (side * 2, side * 2), "black")
    for index, frame in enumerate(normalized):
        sheet.paste(frame, ((index % 2) * side, (index // 2) * side))
    transparent = Image.new("RGBA", sheet.size, (255, 255, 255, 0))
    transparent.putalpha(sheet.convert("L"))
    return transparent, metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--audit-only", action="store_true")
    parser.add_argument("--target-height", type=int, default=325)
    parser.add_argument("--target-bottom", type=int, default=520)
    args = parser.parse_args()

    sheet = Image.open(args.input).convert("RGBA")
    frames = split_frames(sheet)
    for index, frame in enumerate(frames):
        print(f"frame {index}: {frame.width}x{frame.height}")
        print(f"  character={character_box(frame)}")
        for component in components(frame)[:12]:
            left, top, right, bottom = component.box
            print(
                f"  area={component.area:6d} box={component.box} "
                f"size={right - left}x{bottom - top}"
            )

    if args.audit_only:
        return
    if args.output is None:
        parser.error("--output is required unless --audit-only is used")

    output, metrics = normalized_sheet(
        frames,
        target_height=args.target_height,
        target_bottom=args.target_bottom,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.save(args.output, optimize=True)
    print(f"saved {args.output}")
    for index, ((source_box, scale), frame) in enumerate(zip(metrics, split_frames(output))):
        normalized_box = character_box(frame)
        expected_top = args.target_bottom - args.target_height
        print(
            f"normalized {index}: source={source_box} scale={scale:.5f} "
            f"layout_height={args.target_height} layout_top={expected_top} "
            f"baseline={normalized_box[3]} detected_components={normalized_box}"
        )


if __name__ == "__main__":
    main()
