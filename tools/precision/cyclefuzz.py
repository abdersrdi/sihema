#!/usr/bin/env python3
"""Canned cycle check, independent of the Swift code.

Generates random programs with G73 G74 G81 G82 G83 G84 G85 G86 G89 (G98/G99, G90/G91, modal R Z Q P, L repeats,
several holes, G80), simulates what a Fanuc-style control does with its own small model, runs SihemaCheck with
--dump, and compares the moves one by one (collinear neighbours merged) and the total dwell time.

The model follows the Fanuc programming manual:
  - the initial level is the Z where the first cycle block was read; G98 returns to it, G99 stays at R
  - G90: R and Z are positions. G91: R counts from the initial level, Z from R, X and Y are steps
  - a hole: rapid to X Y at the current height, rapid to R, then the cycle, then the return
  - G83 retracts to R after each peck and re-enters rapid to a clearance above the last depth; G73 backs off a little
  - G84 G74 G85 G89 feed back out to R; G81 G82 G83 G73 G86 leave by rapid

Usage: cyclefuzz.py FIRST_SEED LAST_SEED
"""
import math
import os
import random
import subprocess
import sys

CHECK = r"C:\Dev\sihema-build\out\Products\Debug-windows-x86_64\SihemaCheck.exe"
PECK_CLEARANCE = 1.0   # Sihema's defaults for the two parameters a real control keeps in its settings
CHIP_BREAK = 1.0
TOL = 1e-6


class Sim:
    def __init__(self):
        self.pos = [0.0, 0.0, 0.0]
        self.absolute = True
        self.ret98 = True
        self.cycle = 0
        self.init_z = 0.0
        self.r = None
        self.z = None
        self.q = 0.0
        self.p = 0.0
        self.segs = []
        self.dwell = 0.0
        self.off = (0.0, 0.0, 0.0)  # G54 work offset

    def move(self, kind, target):
        target = [float(t) for t in target]
        if all(abs(a - b) < 1e-12 for a, b in zip(self.pos, target)):
            return
        self.segs.append((kind, tuple(self.pos), tuple(target)))
        self.pos = target

    def rapid_to(self, x, y, z):
        self.move("R", (x, y, z))

    def call(self, code, x, y, z, r, q, p, repeats):
        if self.cycle == 0:
            self.init_z = self.pos[2]
            self.r = self.z = None
            self.q = 0.0
            self.p = 0.0
        self.cycle = code
        if r is not None:
            self.r = (r + self.off[2]) if self.absolute else self.init_z + r
        if z is not None:
            base = self.r if self.r is not None else self.init_z
            self.z = (z + self.off[2]) if self.absolute else base + z
        if q is not None:
            self.q = abs(q)
        if p is not None:
            self.p = p / 1000.0
        if x is None and y is None:
            return
        if self.z is None:
            return  # no depth: nothing to drill
        if self.r is None:
            self.r = self.init_z  # no R plane given: the cycle starts at the height the tool stands at
        for _ in range(repeats):
            tx = ((x + self.off[0]) if self.absolute else self.pos[0] + x) if x is not None else self.pos[0]
            ty = ((y + self.off[1]) if self.absolute else self.pos[1] + y) if y is not None else self.pos[1]
            self.hole(tx, ty)

    def hole(self, x, y):
        r, z = self.r, self.z
        self.rapid_to(x, y, self.pos[2])
        self.rapid_to(x, y, r)
        code = self.cycle
        if code in (73, 83):
            peck = self.q if self.q > 0 else abs(z - r)
            cur = r
            while cur - z > 1e-9:
                nxt = max(cur - peck, z)
                self.move("L", (x, y, nxt))
                if nxt - z > 1e-9:
                    if code == 83:
                        self.rapid_to(x, y, r)
                        self.rapid_to(x, y, min(nxt + PECK_CLEARANCE, r))
                    else:
                        self.rapid_to(x, y, min(nxt + CHIP_BREAK, cur))
                cur = nxt
        else:
            self.move("L", (x, y, z))
        if code in (82, 89, 84, 74):
            self.dwell += self.p
        if code in (84, 74, 85, 89):
            self.move("L", (x, y, r))
        else:
            self.rapid_to(x, y, r)
        if self.ret98:
            self.rapid_to(x, y, max(self.init_z, r))

    def cancel(self):
        self.cycle = 0


def fmt(v):
    return ("%.4f" % v).rstrip("0").rstrip(".") if abs(v) >= 1e-9 else "0"


def generate(seed):
    rnd = random.Random(seed)
    sim = Sim()
    lines = ["G90 G21 G17 G98"]
    if rnd.random() < 0.5:
        ox, oy, oz = (round(rnd.uniform(-300, 300), 3), round(rnd.uniform(-300, 300), 3), round(rnd.uniform(-400, -100), 3))
        lines.append("G10 L2 P1 X%s Y%s Z%s" % (fmt(ox), fmt(oy), fmt(oz)))
        lines.append("G54")
        sim.off = (ox, oy, oz)
    for _ in range(rnd.randint(1, 3)):
        sim.absolute = True
        lines.append("G90")
        x = round(rnd.uniform(-50, 50), 3)
        y = round(rnd.uniform(-50, 50), 3)
        z0 = rnd.choice([5.0, 10.0, 25.0])
        lines.append("G00 X%s Y%s Z%s" % (fmt(x), fmt(y), fmt(z0)))
        sim.rapid_to(x + sim.off[0], y + sim.off[1], z0 + sim.off[2])
        code = rnd.choice([81, 82, 83, 84, 85, 86, 89, 73, 74])
        incremental = rnd.random() < 0.3
        repeats = 1
        if incremental:
            repeats = rnd.choice([1, 1, 2, 3])
            ret98 = True
        else:
            ret98 = rnd.random() < 0.5
        lines.append("G98" if ret98 else "G99")
        sim.ret98 = ret98
        r_abs = round(z0 - rnd.uniform(1, 4), 3)
        z_abs = round(r_abs - rnd.uniform(4, 22), 3)
        q = round(rnd.uniform(0.2, 1.4) if rnd.random() < 0.3 else rnd.uniform(1.5, 8), 3)
        p = rnd.choice([100, 500, 1000, 250])
        if incremental:
            lines.append("G91")
            sim.absolute = False
            r_val, z_val = round(r_abs - z0, 3), None
            z_val = round(z_abs - r_abs, 3)
        else:
            r_val, z_val = r_abs, z_abs
        words = []
        hx = round(rnd.uniform(-20, 20), 3)
        hy = round(rnd.uniform(-20, 20), 3)
        no_r = rnd.random() < 0.15
        if no_r:
            # the cycle starts from the current height: Z counts from there
            r_abs = z0
            z_abs = round(r_abs - rnd.uniform(4, 22), 3)
            z_val = round(z_abs - r_abs, 3) if incremental else z_abs
            words += ["X" + fmt(hx), "Y" + fmt(hy), "Z" + fmt(z_val)]
            r_val = None
        else:
            words += ["X" + fmt(hx), "Y" + fmt(hy), "Z" + fmt(z_val), "R" + fmt(r_val)]
        if code in (83, 73):
            words.append("Q" + fmt(q))
        if code in (82, 89, 84, 74):
            words.append("P" + str(p))
        if repeats > 1:
            words.append("L" + str(repeats))
        words.append("F100")
        lines.append("G%d %s" % (code, " ".join(words)))
        sim.call(code, hx, hy, z_val, r_val, q if code in (83, 73) else None,
                 p if code in (82, 89, 84, 74) else None, repeats)
        for _extra in range(rnd.randint(0, 3)):
            roll = rnd.random()
            if roll < 0.15:
                # a block with only depth data: stored, and no hole is drilled (Fanuc)
                new_z_abs = round(r_abs - rnd.uniform(3, 18), 3)
                nz = round(new_z_abs - r_abs, 3) if incremental else new_z_abs
                lines.append("G%d Z%s" % (code, fmt(nz)))
                sim.call(code, None, None, nz, None, None, None, 1)
            elif roll < 0.7:
                nx = round(rnd.uniform(-20, 20), 3)
                ny = round(rnd.uniform(-20, 20), 3)
                axes = rnd.choice([("X", "Y"), ("X",), ("Y",), ("X", "Y")])
                block = " ".join(a + fmt(nx if a == "X" else ny) for a in axes)
                lines.append(block)
                sim.call(code, nx if "X" in axes else None, ny if "Y" in axes else None, None, None, None, None, 1)
            else:
                # another cycle on the same G80-less stretch, with its own depth
                code = rnd.choice([81, 82, 83, 85, 86, 73])
                nx = round(rnd.uniform(-20, 20), 3)
                ny = round(rnd.uniform(-20, 20), 3)
                new_z_abs = round(r_abs - rnd.uniform(3, 18), 3)
                nz = round(new_z_abs - r_abs, 3) if incremental else new_z_abs
                nq = round(rnd.uniform(0.2, 1.4) if rnd.random() < 0.3 else rnd.uniform(1.5, 8), 3)
                np_ = rnd.choice([100, 500])
                w = ["X" + fmt(nx), "Y" + fmt(ny), "Z" + fmt(nz)]
                if code in (83, 73):
                    w.append("Q" + fmt(nq))
                if code == 82:
                    w.append("P" + str(np_))
                lines.append("G%d %s" % (code, " ".join(w)))
                sim.call(code, nx, ny, nz, None, nq if code in (83, 73) else None,
                         np_ if code == 82 else None, 1)
        lines.append("G80")
        sim.cancel()
        if incremental:
            lines.append("G90")
            sim.absolute = True
    lines.append("M30")
    return chr(10).join(lines) + chr(10), sim


def merge(segs):
    """Joins consecutive moves of the same kind that continue in the same direction."""
    out = []
    for kind, a, b in segs:
        if out and out[-1][0] == kind and math.dist(out[-1][2], a) < 1e-9:
            pk, pa, pb = out[-1]
            d1 = [pb[i] - pa[i] for i in range(3)]
            d2 = [b[i] - a[i] for i in range(3)]
            cross = [d1[1] * d2[2] - d1[2] * d2[1], d1[2] * d2[0] - d1[0] * d2[2], d1[0] * d2[1] - d1[1] * d2[0]]
            if max(abs(c) for c in cross) < 1e-9 and sum(u * v for u, v in zip(d1, d2)) > 0:
                out[-1] = (kind, pa, b)
                continue
        out.append((kind, a, b))
    return out


def read_dump(path):
    segs, dwell = [], 0.0
    for line in open(path):
        w = line.split()
        if not w:
            continue
        if w[0] == "D":
            dwell = float(w[1])
            continue
        v = [float(x) for x in w[2:]]
        segs.append((w[0], tuple(v[0:3]), tuple(v[3:6])))
    return segs, dwell


def compare(expected, got, sim_dwell, got_dwell):
    exp, act = merge(expected), merge(got)
    if abs(sim_dwell - got_dwell) > 1e-6:
        return "dwell expected %.4f s, Sihema %.4f s" % (sim_dwell, got_dwell)
    for i in range(min(len(exp), len(act))):
        e, a = exp[i], act[i]
        if e[0] != a[0] or math.dist(e[1], a[1]) > TOL or math.dist(e[2], a[2]) > TOL:
            return "move %d: expected %s %s -> %s, Sihema %s %s -> %s" % (
                i, e[0], tuple(round(c, 3) for c in e[1]), tuple(round(c, 3) for c in e[2]),
                a[0], tuple(round(c, 3) for c in a[1]), tuple(round(c, 3) for c in a[2]))
    if len(exp) != len(act):
        return "expected %d moves, Sihema made %d" % (len(exp), len(act))
    return None


def check(seed):
    text, sim = generate(seed)
    src = os.path.join(os.environ.get("TEMP", "/tmp"), "cyclefuzz_%d.nc" % seed)
    dump = src + ".dump"
    open(src, "w").write(text)
    out = subprocess.run([CHECK, src, "--dump", dump], capture_output=True, text=True, timeout=60).stdout
    errors = [l.strip() for l in out.splitlines() if "[error]" in l or "[warning]" in l]
    got, got_dwell = read_dump(dump)
    problem = compare(sim.segs, got, sim.dwell, got_dwell)
    if problem:
        open(src + ".keep", "w").write(text)
        return problem + ((" | diagnostics: " + errors[0]) if errors else "")
    return None


if __name__ == "__main__":
    first, last = int(sys.argv[1]), int(sys.argv[2])
    failures = 0
    for seed in range(first, last + 1):
        try:
            problem = check(seed)
        except Exception as e:  # noqa: BLE001
            problem = "exception: %r" % (e,)
        if problem:
            failures += 1
            print("seed %d: %s" % (seed, problem))
    print("seeds %d..%d, failures %d" % (first, last, failures))
