#!/usr/bin/env python3
"""Copies the screenshots exported from an .xcresult into one folder with readable names.

    python tools/export_shots.py exported-folder output-folder
"""
import json
import os
import re
import shutil
import sys

source, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
found = []


def walk(node):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            found.append((node["exportedFileName"], node.get("suggestedHumanReadableName", node["exportedFileName"])))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)


manifest = os.path.join(source, "manifest.json")
if os.path.exists(manifest):
    walk(json.load(open(manifest)))
for exported, name in found:
    name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", name)
    if not os.path.splitext(name)[1]:
        name += ".png"
    path = os.path.join(source, exported)
    if os.path.exists(path):
        shutil.copy(path, os.path.join(target, name))
print(f"{len(found)} attachments, copied to {target}")
