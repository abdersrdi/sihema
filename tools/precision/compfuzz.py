#!/usr/bin/env python3
"""Cutter radius compensation check, independent of the Swift code.

Generates a random closed profile (lines, tangent fillet arcs and sharp corners), writes a G41/G42 program for it,
runs SihemaCheck with --dump, and checks the tool-centre path it produced against the programmed contour:

  A  no gouging: every point of the cutting path is at least one radius from the contour
  B  complete:   every point of the ideal offset curve that no other part of the contour invalidates lies on the path
  C  connected:  each segment starts where the previous one ended

Corner handling at outside corners differs between controllers, so it is not compared; both A and B hold for any
correct choice. Usage:  compfuzz.py FIRST_SEED LAST_SEED
"""
import math
import os
import random
import subprocess
import sys

CHECK = r"C:\Dev\sihema-build\out\Products\Debug-windows-x86_64\SihemaCheck.exe"
TOL_A = 0.01      # how far inside one radius a path point may be
TOL_B = 0.02      # how far an ideal offset point may be from the path
TWO_PI = 2 * math.pi


def sub(a, b): return (a[0] - b[0], a[1] - b[1])
def add(a, b): return (a[0] + b[0], a[1] + b[1])
def mul(a, k): return (a[0] * k, a[1] * k)
def dot(a, b): return a[0] * b[0] + a[1] * b[1]
def cross(a, b): return a[0] * b[1] - a[1] * b[0]
def norm(a): return math.hypot(a[0], a[1])
def unit(a):
    n = norm(a)
    return (a[0] / n, a[1] / n)


# ---- primitives: ("L", a, b) or ("A", a, b, centre, ccw) ------------------------------------------------------

def arc_params(p):
    _, a, b, c, ccw = p
    radius = (norm(sub(a, c)) + norm(sub(b, c))) / 2
    a0 = math.atan2(a[1] - c[1], a[0] - c[0])
    a1 = math.atan2(b[1] - c[1], b[0] - c[0])
    sweep = (a1 - a0) % TWO_PI if ccw else -((a0 - a1) % TWO_PI)
    if abs(sweep) < 1e-9:
        sweep = TWO_PI if ccw else -TWO_PI
    return c, radius, a0, sweep


def dist_to_prim(pt, p):
    if p[0] == "L":
        a, b = p[1], p[2]
        d = sub(b, a)
        l2 = dot(d, d)
        t = 0 if l2 == 0 else max(0, min(1, dot(sub(pt, a), d) / l2))
        return norm(sub(pt, add(a, mul(d, t))))
    c, radius, a0, sweep = arc_params(p)
    ang = math.atan2(pt[1] - c[1], pt[0] - c[0])
    rel = (ang - a0) % TWO_PI if sweep > 0 else (a0 - ang) % TWO_PI
    if rel <= abs(sweep):
        return abs(norm(sub(pt, c)) - radius)
    return min(norm(sub(pt, p[1])), norm(sub(pt, p[2])))


def dist_to_prims(pt, prims):
    return min(dist_to_prim(pt, p) for p in prims)


def samples(p, step=0.4):
    """Points along a primitive with the left normal of the direction of travel."""
    out = []
    if p[0] == "L":
        a, b = p[1], p[2]
        length = norm(sub(b, a))
        t = unit(sub(b, a))
        n = (-t[1], t[0])
        k = max(2, int(length / step))
        for i in range(k + 1):
            out.append((add(a, mul(sub(b, a), i / k)), n))
        return out
    c, radius, a0, sweep = arc_params(p)
    k = max(4, int(abs(sweep) * radius / step))
    for i in range(k + 1):
        ang = a0 + sweep * i / k
        pt = (c[0] + radius * math.cos(ang), c[1] + radius * math.sin(ang))
        radial = (math.cos(ang), math.sin(ang))
        tangent = (-radial[1], radial[0]) if sweep > 0 else (radial[1], -radial[0])
        out.append((pt, (-tangent[1], tangent[0])))
    return out


# ---- generator ---------------------------------------------------------------------------------------------

def generate(seed):
    rnd = random.Random(seed)
    for _attempt in range(200):
        n = rnd.randint(4, 8)
        angles = sorted(rnd.uniform(0, TWO_PI) for _ in range(n))
        gaps = [(angles[(i + 1) % n] - angles[i]) % TWO_PI for i in range(n)]
        if min(gaps) < math.radians(25):
            continue
        scale = rnd.uniform(40, 80)
        verts = [(scale * rnd.uniform(0.6, 1.0) * math.cos(a), scale * rnd.uniform(0.6, 1.0) * math.sin(a))
                 for a in angles]
        r = round(rnd.uniform(1.0, 6.0), 3)
        prims = []
        ends = []  # (entry point, exit point, arc or None) for each vertex
        for i in range(n):
            a, v, b = verts[i - 1], verts[i], verts[(i + 1) % n]
            u, w = unit(sub(a, v)), unit(sub(b, v))
            theta = math.acos(max(-1, min(1, dot(u, w))))
            fillet = None
            if rnd.random() < 0.6 and 0.2 < theta < math.pi - 0.05:
                f = rnd.uniform(r * 1.3, r * 6)
                t = f / math.tan(theta / 2)
                limit = 0.4 * min(norm(sub(a, v)), norm(sub(b, v)))
                if t > limit:
                    t = limit
                    f = t * math.tan(theta / 2)
                if f >= r * 1.25:
                    bis = unit(add(u, w))
                    centre = add(v, mul(bis, f / math.sin(theta / 2)))
                    t1, t2 = add(v, mul(u, t)), add(v, mul(w, t))
                    left_turn = cross(sub(v, a), sub(b, v)) > 0
                    fillet = (t1, t2, centre, left_turn)
            if fillet:
                ends.append((fillet[0], fillet[1], fillet))
            else:
                ends.append((v, v, None))
        for i in range(n):
            prev_exit = ends[i - 1][1]
            entry = ends[i][0]
            if norm(sub(entry, prev_exit)) > 1e-6:
                prims.append(("L", prev_exit, entry))
            if ends[i][2]:
                t1, t2, centre, ccw = ends[i][2]
                prims.append(("A", t1, t2, centre, ccw))
        # start in the middle of a long line, so the lead-in and lead-out are normal to a straight edge
        # both halves must be longer than the lead-in and lead-out zone, or the start-up and cancel moves
        # consume them, which no real program does
        need = 4 * r + 2
        lines = [i for i, p in enumerate(prims) if p[0] == "L" and norm(sub(p[2], p[1])) > 2 * need + 1]
        if not lines:
            continue
        k = rnd.choice(lines)
        p = prims[k]
        length = norm(sub(p[2], p[1]))
        split = add(p[1], mul(sub(p[2], p[1]), rnd.uniform(need / length, 1 - need / length)))
        prims = prims[k + 1:] + prims[:k] + [("L", split, p[2])] if False else \
            [("L", split, p[2])] + prims[k + 1:] + prims[:k] + [("L", p[1], split)]
        side = rnd.choice([1, -1])  # +1 G41, -1 G42
        if rnd.random() < 0.5:      # traverse the other way round
            prims = [("L", q[2], q[1]) if q[0] == "L" else ("A", q[2], q[1], q[3], not q[4])
                     for q in reversed(prims)]
        # round every coordinate the way the file will carry it, and rebuild the contour from the rounded numbers
        def rnd4(pt): return (round(pt[0], 4), round(pt[1], 4))
        rounded = []
        for q in prims:
            if q[0] == "L":
                rounded.append(("L", rnd4(q[1]), rnd4(q[2])))
            else:
                a, b = rnd4(q[1]), rnd4(q[2])
                c = (round(q[3][0] - q[1][0], 4) + a[0], round(q[3][1] - q[1][1], 4) + a[1])
                rounded.append(("A", a, b, c, q[4]))
        prims = rounded
        first = prims[0]
        d = unit(sub(first[2], first[1]))
        normal = (-d[1], d[0])
        approach = rnd4(add(first[1], mul(normal, side * (3 * r + 2))))
        # the lead-in must be clear of the contour except at its end
        lead = 3 * r + 2
        steps = [2 * r + (lead - 2 * r) * i / 20 for i in range(21)]  # includes the end, where the tool waits
        clear = all(dist_to_prims(add(first[1], mul(normal, side * s)), prims) >= r - 1e-3 for s in steps)
        if not clear:
            continue
        plane = rnd.choice([17, 17, 18, 19])
        inches = rnd.random() < 0.3
        return r, side, approach, prims, plane, inches
    raise RuntimeError("no profile for seed %d" % seed)


def program(r, side, approach, prims, plane=17, inches=False):
    """The program for the profile. Coordinates (u, v) are the first and second axis of the plane."""
    letters = {17: ("X", "Y", "I", "J"), 18: ("Z", "X", "K", "I"), 19: ("Y", "Z", "J", "K")}[plane]
    scale = 1 / 25.4 if inches else 1.0
    f = (lambda v: "%.7f" % (v * scale)) if inches else (lambda v: "%.4f" % v)
    au, av, iu, iv = letters
    def pt(q): return "%s%s %s%s" % (au, f(q[0]), av, f(q[1]))
    lines = ["G90 G%d G17".replace("G17", "G20" if inches else "G21") % plane if False else
             "G90 G%d G%d" % (plane, 20 if inches else 21),
             "G00 " + pt(approach),
             "G%d D1 G01 %s F%s" % (41 if side > 0 else 42, pt(prims[0][1]), "20" if inches else "500")]
    for q in prims:
        if q[0] == "L":
            lines.append("G01 " + pt(q[2]))
        else:
            lines.append("G%d %s %s%s %s%s" % (3 if q[4] else 2, pt(q[2]), iu, f(q[3][0] - q[1][0]),
                                               iv, f(q[3][1] - q[1][1])))
    lines += ["G40 G01 " + pt(approach), "M30"]
    return chr(10).join(lines) + chr(10)


# ---- the path Sihema produced ---------------------------------------------------------------------------------

def read_dump(path, plane=17):
    segs = []
    for line in open(path):
        w = line.split()
        if len(w) < 12:
            continue
        kind = w[0]
        v = [float(x) for x in w[2:]]
        a0, a1 = {17: (0, 1), 18: (2, 0), 19: (1, 2)}[plane]
        start, end, centre, feed = (v[a0], v[a1]), (v[3 + a0], v[3 + a1]), (v[6 + a0], v[6 + a1]), v[9]
        if kind == "R":
            continue
        if kind == "L":
            segs.append(("L", start, end))
        else:
            segs.append(("A", start, end, centre, kind == "CCW"))
    return segs


def check(seed, keep):
    r, side, approach, prims, plane, inches = generate(seed)
    text = program(r, side, approach, prims, plane, inches)
    src = os.path.join(os.environ.get("TEMP", "/tmp"), "compfuzz_%d.nc" % seed)
    dump = src + ".dump"
    open(src, "w").write(text)
    out = subprocess.run([CHECK, src, "--radii", "1=%s" % r, "--dump", dump],
                         capture_output=True, text=True, timeout=60).stdout
    if "[error]" in out:
        return ["sihema reported an error: " + [l for l in out.splitlines() if "[error]" in l][0].strip()]
    path = read_dump(dump, plane)
    problems = []
    # C: connected
    for i in range(1, len(path)):
        if norm(sub(path[i][1], path[i - 1][2])) > 3e-3:
            problems.append("C: gap of %.4f before segment %d" % (norm(sub(path[i][1], path[i - 1][2])), i))
            break
    # A: no gouging
    worst = (1e9, None)
    for seg in path:
        for pt, _n in samples(seg, 0.3):
            d = dist_to_prims(pt, prims)
            if d < worst[0]:
                worst = (d, pt)
    if worst[0] < r - TOL_A:
        problems.append("A: path point (%.3f, %.3f) is %.4f from the contour, radius %.3f" %
                        (worst[1][0], worst[1][1], worst[0], r))
    # B: the ideal offset is covered wherever nothing else invalidates it
    miss = (0.0, None)
    checked = 0
    start = prims[0][1]
    for p in prims:
        for pt, n in samples(p, 0.4):
            # how a controller starts and ends compensation (straight to the offset point, or to the meeting
            # point of the offset lines) differs, so the stretch next to the start point is not compared
            if p is prims[0] or p is prims[-1]:
                if norm(sub(pt, start)) < 3 * r + 0.5:
                    continue
            q = add(pt, mul(n, side * r))
            if dist_to_prims(q, prims) < r - TOL_A:
                continue  # another part of the contour is in the way here
            checked += 1
            d = dist_to_prims(q, path)
            if d > miss[0]:
                miss = (d, q)
    if miss[0] > TOL_B:
        problems.append("B: ideal offset point (%.3f, %.3f) is %.4f from Sihema's path" % (miss[1][0], miss[1][1], miss[0]))
    if problems or keep:
        open(src + ".keep", "w").write(text)
    return problems


if __name__ == "__main__":
    first, last = int(sys.argv[1]), int(sys.argv[2])
    failures = 0
    for seed in range(first, last + 1):
        try:
            problems = check(seed, False)
        except Exception as e:  # noqa: BLE001
            problems = ["exception: %r" % (e,)]
        if problems:
            failures += 1
            print("seed %d: %s" % (seed, " | ".join(problems)))
    print("seeds %d..%d, failures %d" % (first, last, failures))
