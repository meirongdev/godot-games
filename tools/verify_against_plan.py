#!/usr/bin/env python3
"""把仓库里的文件与计划文档中对应的代码块逐字节比对。

计划里的每个 ```lang 块都由前面一行 "Create `path`:" 或 "Replace `path` 全文:" 锚定。
誊抄型任务用这个校验,比让 LLM 重读一遍可靠。
"""
import io, re, sys, os, difflib

PLAN = 'docs/superpowers/plans/2026-08-25-lobby-and-rps.md'
s = io.open(PLAN, encoding='utf-8').read()

# 锚点 -> 代码块
blocks = {}
for m in re.finditer(r'(?:Create|Replace) `([^`]+)`[^\n]*:\n+```[a-z]*\n(.*?)\n```', s, re.S):
    path, body = m.group(1), m.group(2)
    blocks[path] = body   # 同名取最后一次(后续步骤可能整体替换)

targets = sys.argv[1:] or sorted(blocks)
rc = 0
for path in targets:
    if path not in blocks:
        print('?  %-46s 计划里没有这个文件的完整代码块' % path); continue
    if not os.path.exists(path):
        print('✗  %-46s 文件不存在' % path); rc = 1; continue
    actual = io.open(path, encoding='utf-8').read().rstrip('\n')
    expect = blocks[path].rstrip('\n')
    if actual == expect:
        print('✓  %-46s %d 行,与计划一致' % (path, actual.count('\n') + 1))
    else:
        print('✗  %-46s 与计划有差异:' % path)
        for line in list(difflib.unified_diff(
                expect.split('\n'), actual.split('\n'),
                'plan', 'repo', lineterm='', n=1))[:40]:
            print('     ' + line)
        rc = 1
sys.exit(rc)
