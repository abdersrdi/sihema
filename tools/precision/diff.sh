#!/bin/bash
S="$1"; C=/c/Dev/sihema-build/out/Products/Debug-windows-x86_64/SihemaCheck.exe
shift
n=0; bad=0; skip=0
for f in "$@"; do
  [ -f "$f" ] || continue
  orig="$f"; tmp=/tmp/cleaned.nc; st=$(python -I "$S/clean.py" "$f" $tmp); [ "$st" = OK ] || { skip=$((skip+1)); continue; }; f=$tmp
  ref=$(timeout 60 python -I "$S/refcalc.py" "$f" 2>&1)
  case "$ref" in REFUSE|EMPTY|"") skip=$((skip+1)); continue;; esac
  out=$(timeout 60 $C "$f" 2>&1)
  cut=$(echo "$out" | sed -nE 's/.*cutting ([0-9.]+) mm, rapid ([0-9.]+) mm.*/\1 \2/p')
  bnd=$(echo "$out" | sed -nE 's/^- bounds X (-?[0-9.]+)\.\.(-?[0-9.]+), Y (-?[0-9.]+)\.\.(-?[0-9.]+), Z (-?[0-9.]+)\.\.(-?[0-9.]+)/\1 \2 \3 \4 \5 \6/p')
  n=$((n+1))
  res=$(python -I - "$ref" "$cut" "$bnd" <<'PY'
import sys
r=[float(x) for x in sys.argv[1].split()]
c=[float(x) for x in sys.argv[2].split()]
b=[float(x) for x in sys.argv[3].split()] if sys.argv[3].strip() else []
msgs=[]
if len(c)!=2: print("NOPARSE"); sys.exit()
tol=lambda a: 0.06+1e-4*abs(a)
if abs(r[0]-c[0])>tol(r[0]): msgs.append("cut ref=%.2f sih=%.2f"%(r[0],c[0]))
if abs(r[1]-c[1])>tol(r[1]): msgs.append("rapid ref=%.2f sih=%.2f"%(r[1],c[1]))
if len(b)==6:
    for name,i,j in (("X",2,0),("X+",3,1),("Y",4,2),("Y+",5,3),("Z",6,4),("Z+",7,5)):
        if abs(r[i]-b[j])>0.06+1e-3*abs(r[i]): msgs.append("bound %s ref=%.2f sih=%.2f"%(name,r[i],b[j]))
print("; ".join(msgs) if msgs else "OK")
PY
)
  if [ "$res" != "OK" ]; then bad=$((bad+1)); echo "DIFF $(basename "$orig"): $res"; fi
done
echo "compared=$n different=$bad refused=$skip"
