#!/usr/bin/env python3
"""生成文档截图:四个场景的「有内容」画面 → docs/screenshots/*.png

前置: cd nakama && docker compose up -d(harness 要真实登录拿 user_id)
原理: 临时把 main_scene 指向 tests/ShotHarness.tscn,movie 模式渲染,
      取最后一帧。SHOT 环境变量选场景。
"""
import io, re, os, shutil, subprocess, sys

GODOT = "/Applications/Godot.app/Contents/MacOS/Godot"
PROJ = "godot/project.godot"
OUT = "docs/screenshots"
SHOTS = ["login", "lobby", "room", "rps"]
FRAMES = {"login": 40, "lobby": 160, "room": 80, "rps": 80}

orig = io.open(PROJ, encoding="utf-8").read()
os.makedirs(OUT, exist_ok=True)
try:
    io.open(PROJ, "w", encoding="utf-8").write(re.sub(
        r'run/main_scene="[^"]*"',
        'run/main_scene="res://tests/ShotHarness.tscn"', orig))
    for shot in SHOTS:
        tmp = "/tmp/shot_%s" % shot
        shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
        env = dict(os.environ, SHOT=shot)
        subprocess.run(
            [GODOT, "--path", "godot", "--write-movie", tmp + "/f.png",
             "--quit-after", str(FRAMES[shot]), "--resolution", "1280x800"],
            env=env, capture_output=True, timeout=180)
        pngs = sorted(f for f in os.listdir(tmp) if f.endswith(".png"))
        if not pngs:
            sys.exit("✗ %s 没有产出帧" % shot)
        shutil.copy(os.path.join(tmp, pngs[-1]), os.path.join(OUT, shot + ".png"))
        print("  %s.png  (%d KB)" % (shot, os.path.getsize(os.path.join(OUT, shot + ".png")) // 1024))
finally:
    io.open(PROJ, "w", encoding="utf-8").write(orig)
