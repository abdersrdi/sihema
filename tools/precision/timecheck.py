#!/usr/bin/env python3
"""Cycle time check, independent of the Swift code.

Takes the segments Sihema dumps (SihemaCheck --dump) and plans the speeds again with a different method:

  - junction speeds are relaxed to a fixed point (forward and backward until nothing changes), not in one pass each
  - each move is timed by integrating dt = ds / v(s) numerically, with v(s) the lower of the cruise speed and the speeds
    that the acceleration allows from the start and to the end, not by the closed-form trapezoid

and compares the total with the time SihemaCheck prints. The physical model is the one Sihema documents: constant
axis acceleration, rapid limited by the slowest axis, curves limited by v^2/R <= a, and a per-axis speed step at joins.

Usage:  timecheck.py FIRST_SEED LAST_SEED          random programs
        timecheck.py --files a.nc b.nc ...         real programs, default model
"""
import math
import os
import random
import subprocess
import sys

CHECK = r"C:\Dev\sihema-build\out\Products\Debug-windows-x86_64\SihemaCheck.exe"
AXES = {0: (0, 1, 2), 1: (2, 0, 1), 2: (1, 2, 0)}  # plane code -> first, second, third axis


def sub(a, b): return [a[i] - b[i] for i in range(3)]
def norm(a): return math.sqrt(sum(c * c for c in a))


def read_dump(path):
    segs, dwell, tools = [], 0.0, 0
    for line in open(path):
        w = line.split()
        if not w:
            continue
        if w[0] == "D":
            dwell = float(w[1])
        elif w[0] == "T":
            tools = int(w[1])
        else:
            v = [float(x) for x in w[2:]]
            segs.append({"kind": w[0], "plane": int(w[1]), "s": v[0:3], "e": v[3:6], "c": v[6:9], "feed": v[9]})
    return segs, dwell, tools


def geometry(seg):
    """Length, unit direction at the start and at the end, and the radius for arcs."""
    if seg["kind"] in ("R", "L"):
        d = sub(seg["e"], seg["s"])
        n = norm(d)
        u = [c / n for c in d] if n > 1e-12 else [0.0, 0.0, 0.0]
        return n, u, u, 0.0
    a0, a1, h = AXES[seg["plane"]]
    ccw = seg["kind"] == "CCW"
    su, sv = seg["s"][a0] - seg["c"][a0], seg["s"][a1] - seg["c"][a1]
    eu, ev = seg["e"][a0] - seg["c"][a0], seg["e"][a1] - seg["c"][a1]
    radius = math.hypot(su, sv)
    t0, t1 = math.atan2(sv, su), math.atan2(ev, eu)
    sweep = (t1 - t0) % (2 * math.pi) if ccw else -((t0 - t1) % (2 * math.pi))
    if abs(sweep) < 1e-9:
        sweep = 2 * math.pi if ccw else -2 * math.pi
    planar = abs(sweep) * radius
    dh = seg["e"][h] - seg["s"][h]
    length = math.hypot(planar, dh)
    def tangent(u, v):
        n = math.hypot(u, v)
        if n < 1e-12:
            return [0.0, 0.0, 0.0]
        tp = (-v / n, u / n) if ccw else (v / n, -u / n)
        out = [0.0, 0.0, 0.0]
        out[a0], out[a1] = tp
        return out
    return length, tangent(su, sv), tangent(eu, ev), radius


def plan_time(segs, dwell, tools, rapid, accel, tool_change, corner):
    n = len(segs)
    extra = dwell + tools * tool_change
    if n == 0:
        return extra
    length, u0, u1, cruise = [], [], [], []
    for sg in segs:
        L, a, b, R = geometry(sg)
        length.append(L)
        u0.append(a)
        u1.append(b)
        if sg["kind"] == "R" or sg["feed"] <= 0:
            share = max(abs(c) for c in a) if any(a) else 1.0
            c = max(rapid, 1) / 60 / max(share, 1e-9)
        else:
            c = max(sg["feed"], 1) / 60
        if sg["kind"] in ("CW", "CCW") and R > 0:
            c = min(c, max(math.sqrt(accel * R), 1))
        cruise.append(c)
    # speed limit at each join, and zero at both ends of the program
    limit = [0.0] * (n + 1)
    for i in range(1, n):
        lim = min(cruise[i - 1], cruise[i])
        if any(u1[i - 1]) and any(u0[i]):
            step = max(abs(u0[i][k] - u1[i - 1][k]) for k in range(3))
            if step > 1e-9:
                lim = min(lim, max(corner, 0) / step)
        limit[i] = lim
    v = limit[:]
    # relax until every move can be driven from its start speed to its end speed within the acceleration
    for _ in range(10000):
        changed = False
        for i in range(n):
            cap = math.sqrt(v[i] ** 2 + 2 * accel * length[i])
            if v[i + 1] > cap + 1e-12:
                v[i + 1] = cap
                changed = True
        for i in range(n - 1, -1, -1):
            cap = math.sqrt(v[i + 1] ** 2 + 2 * accel * length[i])
            if v[i] > cap + 1e-12:
                v[i] = cap
                changed = True
        if not changed:
            break
    total = extra
    steps = 600
    for i in range(n):
        L = length[i]
        if L <= 0:
            continue
        c = cruise[i]
        v0, v1 = min(v[i], c), min(v[i + 1], c)
        t = 0.0
        for k in range(steps):
            x = (k + 0.5) / steps
            s = L * (1 - math.cos(math.pi * x)) / 2          # crowd the samples towards the ends
            ds = L * math.pi / 2 * math.sin(math.pi * x) / steps
            speed = min(c, math.sqrt(v0 * v0 + 2 * accel * s), math.sqrt(v1 * v1 + 2 * accel * (L - s)))
            t += ds / max(speed, 1e-9)
        total += t
    return total


# ---- random programs ----------------------------------------------------------------------------------------

def generate(seed):
    rnd = random.Random(seed)
    lines = ["G90 G21 G17"]
    x = y = 0.0
    for _ in range(rnd.randint(3, 25)):
        roll = rnd.random()
        feed = rnd.choice([200, 800, 1500, 3000, 6000, 9000])
        if roll < 0.15:
            x, y = round(rnd.uniform(-200, 200), 3), round(rnd.uniform(-200, 200), 3)
            lines.append("G00 X%.3f Y%.3f Z%.3f" % (x, y, rnd.uniform(-50, 50)))
        elif roll < 0.6:
            scale = rnd.choice([0.5, 5, 40, 150])
            x, y = round(x + rnd.uniform(-scale, scale) + 0.001, 3), round(y + rnd.uniform(-scale, scale), 3)
            lines.append("G01 X%.3f Y%.3f F%d" % (x, y, feed))
        elif roll < 0.85:
            # a valid arc: the end point lies on the circle round the centre
            r = rnd.choice([0.8, 3, 12, 60])
            a0 = rnd.uniform(0, 2 * math.pi)
            sweep = rnd.uniform(0.2, 6.0) * rnd.choice([1, -1])
            i, j = round(-r * math.cos(a0), 4), round(-r * math.sin(a0), 4)
            cx, cy = x + i, y + j
            ex, ey = round(cx + r * math.cos(a0 + sweep), 4), round(cy + r * math.sin(a0 + sweep), 4)
            lines.append("G0%d X%.4f Y%.4f I%.4f J%.4f F%d" % (3 if sweep > 0 else 2, ex, ey, i, j, feed))
            x, y = ex, ey
        elif roll < 0.92:
            lines.append("G04 P%d" % rnd.choice([200, 1000]))
        elif roll < 0.96:
            lines.append("T%d M6" % rnd.randint(1, 9))
        else:
            lines.append("G01 Z%.3f F%d" % (rnd.uniform(-30, 5), feed))
    lines.append("M30")
    return chr(10).join(lines) + chr(10)


def sihema(path, model_args, dump):
    out = subprocess.run([CHECK, path, "--model", model_args, "--dump", dump], capture_output=True, text=True, timeout=120).stdout
    for line in out.splitlines():
        if "cycle time with acceleration" in line:
            return float(line.split()[-2])
    return None


def parse_model(arg):
    m = dict(rapid=15000.0, accel=1500.0, tool=5.0, corner=5.0)
    for part in arg.split(","):
        k, v = part.split("=")
        m[k] = float(v)
    return m


def compare(path, model_args):
    dump = path + ".dump"
    got = sihema(path, model_args, dump)
    segs, dwell, tools = read_dump(dump)
    m = parse_model(model_args)
    want = plan_time(segs, dwell, tools, m["rapid"], m["accel"], m["tool"], m["corner"])
    if got is None:
        return "no time printed"
    if abs(got - want) > 0.0015 * want + 0.01:
        return "Sihema %.4f s, independent %.4f s (%+.2f%%)" % (got, want, 100 * (got - want) / want)
    return None


if __name__ == "__main__":
    tmp = os.environ.get("TEMP", "/tmp")
    if sys.argv[1] == "--files":
        bad = 0
        for f in sys.argv[2:]:
            try:
                problem = compare(f, "rapid=15000,accel=1500,tool=5,corner=5")
            except Exception as e:  # noqa: BLE001
                problem = "exception %r" % (e,)
            if problem:
                bad += 1
                print("%s: %s" % (os.path.basename(f), problem))
        print("files %d, different %d" % (len(sys.argv) - 2, bad))
    else:
        first, last = int(sys.argv[1]), int(sys.argv[2])
        bad = 0
        for seed in range(first, last + 1):
            rnd = random.Random(seed * 7919)
            model = "rapid=%d,accel=%d,tool=%d,corner=%s" % (
                rnd.choice([3000, 8000, 15000, 30000]), rnd.choice([200, 800, 1500, 4000]),
                rnd.choice([0, 5, 12]), rnd.choice(["0", "2", "5", "20"]))
            path = os.path.join(tmp, "timecheck_%d.nc" % seed)
            open(path, "w").write(generate(seed))
            problem = compare(path, model)
            if problem:
                bad += 1
                print("seed %d (%s): %s" % (seed, model, problem))
        print("seeds %d..%d, different %d" % (first, last, bad))
