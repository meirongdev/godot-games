#!/usr/bin/env python3
"""从 nakama/modules/ 生成 k8s ConfigMap 与对应的 volume items 片段。

为什么要生成而不是手写:
  · ConfigMap 的 key **不能含 `/`**,而我们的模块有 games/ 和 rules/ 两级目录。
    只能把 key 拍平成 games_rps.lua,再用 volume 的 items[].path 还原成 games/rps.lua。
  · 这意味着加一个 Lua 文件要同时改 ConfigMap 和 volume items 两处。
    手工同步迟早漏,所以两边都由这个脚本生成。

用法:  python3 tools/build_k8s_modules.py
产出:  k8s/nakama-modules-configmap.yaml
"""
import io, os, sys, hashlib

SRC = "nakama/modules"
OUT = "k8s/nakama-modules-configmap.yaml"
LIMIT = 1024 * 1024          # ConfigMap 硬上限约 1 MiB

files = []
for root, _, names in os.walk(SRC):
    for n in sorted(names):
        if n.endswith(".lua"):
            full = os.path.join(root, n)
            rel = os.path.relpath(full, SRC)          # e.g. games/rps.lua
            files.append((rel, io.open(full, encoding="utf-8").read()))
files.sort()

total = sum(len(c.encode()) for _, c in files)
if total > LIMIT:
    sys.exit(f"✗ 模块合计 {total} 字节,超过 ConfigMap 上限 {LIMIT}。\n"
             f"  改用自建镜像把模块打进去,或挂 PVC。")

digest = hashlib.sha256(
    "".join(f"{p}\0{c}" for p, c in files).encode()).hexdigest()[:12]

def key_of(rel):
    return rel.replace("/", "_")

lines = [
    "---",
    "# 由 tools/build_k8s_modules.py 生成 —— 不要手改。",
    "# 源:nakama/modules/**.lua      改完源码重新跑脚本。",
    "#",
    "# Nakama 从 <data_dir>/modules 递归加载 .lua(实测启动日志会列出全部七个,",
    "# 含 games/ 和 rules/ 子目录)。ConfigMap 的 key 不能含 `/`,所以 key 拍平成",
    "# games_rps.lua,由下面 Deployment 的 volume items[].path 还原成 games/rps.lua。",
    "apiVersion: v1",
    "kind: ConfigMap",
    "metadata:",
    "  name: nakama-modules",
    "  namespace: personal-services",
    "  annotations:",
    f"    # 内容指纹。改了模块这个值会变 —— 用它判断是否需要 rollout restart。",
    f"    godot-games/modules-sha: \"{digest}\"",
    "data:",
]
for rel, content in files:
    lines.append(f"  {key_of(rel)}: |")
    for line in content.rstrip("\n").split("\n"):
        lines.append(f"    {line}" if line else "")
io.open(OUT, "w", encoding="utf-8").write("\n".join(lines) + "\n")

# volume items 片段,贴进 homelab 的 nakama.yaml
items = "\n".join(
    f"              - key: {key_of(r)}\n                path: {r}" for r, _ in files)
snippet = f"""        - name: modules
          configMap:
            name: nakama-modules
            items:
{items}"""

print(f"  {OUT}")
print(f"  {len(files)} 个模块,{total} 字节 ({100*total//LIMIT}% of ConfigMap 上限)")
print(f"  指纹 {digest}")
io.open("k8s/_volume-items.snippet", "w", encoding="utf-8").write(snippet + "\n")
print("  k8s/_volume-items.snippet  (贴进 homelab nakama.yaml 的 volumes:)")
