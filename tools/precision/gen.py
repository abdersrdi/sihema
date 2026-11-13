import math, random, sys
seed = int(sys.argv[1]); out = sys.argv[2]
rnd = random.Random(seed)
inch = rnd.random() < 0.3
absolute_default = rnd.random() < 0.6
lines = ["G20" if inch else "G21", "G90" if absolute_default else "G91"]
scale = 1 / 25.4 if inch else 1.0
fmt = (lambda v: ("%.4f" % v)) if inch else (lambda v: ("%.3f" % v))
pos = [0.0, 0.0, 0.0]  # mm
absolute = absolute_default
plane = 17
def word(c, v): return c + fmt(v * scale)
n = rnd.randint(8, 30)
for _ in range(n):
    kind = rnd.choice(["g0", "g1", "g1", "arcij", "arcr", "mode", "plane", "helix"])
    if kind == "mode":
        absolute = not absolute
        lines.append("G90" if absolute else "G91"); continue
    if kind == "plane":
        plane = rnd.choice([17, 18, 19]); lines.append("G%d" % plane); continue
    if kind in ("g0", "g1"):
        t = [pos[k] + rnd.uniform(-40, 40) if rnd.random() < 0.8 else pos[k] for k in range(3)]
        parts = ["G0" if kind == "g0" else "G1"]
        for k, c in enumerate("XYZ"):
            if t[k] != pos[k]:
                # round the way the file will, so both tools see the same number
                v = float(fmt((t[k] if absolute else t[k] - pos[k]) * scale)) / scale
                parts.append(word(c, v))
                t[k] = v if absolute else pos[k] + v
        if kind == "g1": parts.append("F300")
        lines.append(" ".join(parts)); pos = t; continue
    # arcs: pick centre, radius, angles in the plane; start from current position
    a0, a1, h = {17: (0, 1, 2), 18: (2, 0, 1), 19: (1, 2, 0)}[plane]
    r = rnd.uniform(3, 30)
    ang0 = rnd.uniform(0, 2 * math.pi)
    sweep = rnd.uniform(0.3, 5.8) * rnd.choice([1, -1])
    cu = pos[a0] - r * math.cos(ang0); cv = pos[a1] - r * math.sin(ang0)
    eu = cu + r * math.cos(ang0 + sweep); ev = cv + r * math.sin(ang0 + sweep)
    t = list(pos); t[a0] = eu; t[a1] = ev
    if kind == "helix": t[h] = pos[h] + rnd.uniform(-10, 10)
    # numbers as the file will carry them
    tv = {}
    for k, c in enumerate("XYZ"):
        if abs(t[k] - pos[k]) > 1e-9:
            tv[c] = float(fmt((t[k] if absolute else t[k] - pos[k]) * scale)) / scale
    t2 = list(pos)
    for k, c in enumerate("XYZ"):
        if c in tv: t2[k] = tv[c] if absolute else pos[k] + tv[c]
    g = "G3" if sweep > 0 else "G2"
    parts = [g] + [word(c, v) for c, v in tv.items()]
    ok = True
    if kind == "arcr":
        # R must describe the arc between the *rounded* endpoints; the sign picks the arc size
        d = math.hypot(t2[a0] - pos[a0], t2[a1] - pos[a1])
        if d < 1e-3 or r < d / 2 + 0.01: continue
        big = abs(sweep) > math.pi
        parts.append(word("R", -r if big else r))
        # an R arc is defined by the endpoints, so keep the generator's endpoints
    else:
        ijk = {0: "I", 1: "J", 2: "K"}
        parts.append(word(ijk[a0], cu - pos[a0])); parts.append(word(ijk[a1], cv - pos[a1]))
        # end point must lie on the circle: use the rounded endpoint (small error, same for both tools)
    parts.append("F300")
    lines.append(" ".join(parts)); pos = t2
open(out, "w").write("\n".join(lines) + "\nM30\n")
