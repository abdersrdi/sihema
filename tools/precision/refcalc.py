#!/usr/bin/env python3
"""Independent G-code length calculator used to cross-check SihemaCheck.

Models only plain motion: G0 G1 G2 G3 (IJK or R), G17-G19, G20/G21, G90/G91. Anything else makes it refuse the file.
Prints: cutting rapid minx maxx miny maxy minz maxz   (mm)
"""
import math
import re
import sys

REFUSE = re.compile(r"(?!x)x|" + 
    r"#|\bG(41|42|65|68|51|52|53|28|30|92|10|16|7[346]|8[1-9]|5\.1)\b|\bM9[78]\b|WHILE|\bIF\b|GOTO", re.I)
WORD = re.compile(r"([A-Za-z])\s*([-+]?(?:\d+\.?\d*|\.\d+))")


def strip(line):
    line = re.sub(r"\([^)]*\)", " ", line)
    line = line.split(";")[0]
    return line


def main(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    if False and REFUSE.search(re.sub(r"\([^)]*\)", " ", text)):
        print("REFUSE")
        return
    pos = [0.0, 0.0, 0.0]
    absolute = True
    scale = 1.0
    plane = 17
    motion = 1
    cutting = rapid = 0.0
    lo = [1e18] * 3
    hi = [-1e18] * 3
    any_move = False

    def extend(p):
        for k in range(3):
            lo[k] = min(lo[k], p[k])
            hi[k] = max(hi[k], p[k])

    for raw in text.splitlines():
        line = strip(raw)
        if line.strip().startswith("%"):
            continue
        words = [(m.group(1).upper(), float(m.group(2))) for m in WORD.finditer(line)]
        gs = [v for l, v in words if l == "G"]
        for g in gs:
            gi = round(g * 10)
            if gi == 200: scale = 25.4
            elif gi == 210: scale = 1.0
            elif gi == 900: absolute = True
            elif gi == 910: absolute = False
            elif gi == 170: plane = 17
            elif gi == 180: plane = 18
            elif gi == 190: plane = 19
            elif gi in (0, 10, 20, 30): motion = gi // 10
        if any(round(g * 10) == 40 for g in gs):
            continue  # dwell
        vals = {}
        for l, v in words:
            if l in "XYZIJKR":
                vals[l] = v * scale
        if not any(c in vals for c in "XYZ") and not (motion in (2, 3) and any(c in vals for c in "IJKR")):
            continue
        target = list(pos)
        for k, c in enumerate("XYZ"):
            if c in vals:
                target[k] = vals[c] if absolute else pos[k] + vals[c]
        start = list(pos)
        if not any_move:
            extend(start)
            any_move = True
        if motion == 0:
            rapid += math.dist(start, target)
        elif motion == 1:
            cutting += math.dist(start, target)
        else:
            a0, a1, h = {17: (0, 1, 2), 18: (2, 0, 1), 19: (1, 2, 0)}[plane]
            off = {0: vals.get("I", 0.0), 1: vals.get("J", 0.0), 2: vals.get("K", 0.0)}
            su, sv = start[a0], start[a1]
            eu, ev = target[a0], target[a1]
            if "R" in vals and not any(c in vals for c in "IJK"):
                r = vals["R"]
                dx, dy = eu - su, ev - sv
                d = math.hypot(dx, dy)
                if d < 1e-12 or abs(r) < d / 2 - 1e-9:
                    # invalid arc: Sihema reports an error and draws nothing
                    pos = target
                    continue
                hh = math.sqrt(max(r * r - d * d / 4, 0.0))
                mx, my = su + dx / 2, sv + dy / 2
                # centre on the left of the chord for CCW with positive R, right for CW
                sign = 1 if (motion == 3) == (r > 0) else -1
                cu = mx - sign * hh * dy / d
                cv = my + sign * hh * dx / d
                radius = abs(r)
            else:
                cu, cv = su + off[a0], sv + off[a1]
                radius = math.hypot(su - cu, sv - cv)
            a_start = math.atan2(sv - cv, su - cu)
            a_end = math.atan2(ev - cv, eu - cu)
            sweep = a_end - a_start
            if motion == 3:
                while sweep <= 1e-12: sweep += 2 * math.pi
            else:
                while sweep >= -1e-12: sweep -= 2 * math.pi
            arc = abs(sweep) * radius
            cutting += math.hypot(arc, target[h] - start[h])
            # bounds: include the arc's extreme points
            n = max(8, int(abs(sweep) / (math.pi / 90)))
            for i in range(n + 1):
                t = a_start + sweep * i / n
                p = list(start)
                p[a0] = cu + radius * math.cos(t)
                p[a1] = cv + radius * math.sin(t)
                p[h] = start[h] + (target[h] - start[h]) * i / n
                extend(p)
        pos = target
        extend(pos)
    if not any_move:
        print("EMPTY")
        return
    print("%.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f" % (cutting, rapid, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]))


main(sys.argv[1])
