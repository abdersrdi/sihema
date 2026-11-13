#!/bin/bash
S="$1"; N="$2"; C=/c/Dev/sihema-build/out/Products/Debug-windows-x86_64/SihemaCheck.exe
bad=0; ok=0
for i in $(seq 1 $N); do
  python -I "$S/gen.py" $i /tmp/fz.nc
  ref=$(python -I "$S/refcalc.py" /tmp/fz.nc)
  out=$($C /tmp/fz.nc 2>&1)
  cut=$(echo "$out" | sed -nE 's/.*cutting ([0-9.]+) mm, rapid ([0-9.]+) mm.*/\1 \2/p')
  bnd=$(echo "$out" | sed -nE 's/^- bounds X (-?[0-9.]+)\.\.(-?[0-9.]+), Y (-?[0-9.]+)\.\.(-?[0-9.]+), Z (-?[0-9.]+)\.\.(-?[0-9.]+)/\1 \2 \3 \4 \5 \6/p')
  res=$(python -I - "$ref" "$cut" "$bnd" <<'PY'
import sys
r=[float(x) for x in sys.argv[1].split()]
c=[float(x) for x in sys.argv[2].split()]
b=[float(x) for x in sys.argv[3].split()] if sys.argv[3].strip() else []
m=[]
if len(c)!=2 or len(r)!=8: print("NOPARSE"); sys.exit()
tol=lambda a: 0.06+2e-4*abs(a)
if abs(r[0]-c[0])>tol(r[0]): m.append("cut ref=%.3f sih=%.3f"%(r[0],c[0]))
if abs(r[1]-c[1])>tol(r[1]): m.append("rapid ref=%.3f sih=%.3f"%(r[1],c[1]))
if len(b)==6:
    for nme,i,j in (("X-",2,0),("X+",3,1),("Y-",4,2),("Y+",5,3),("Z-",6,4),("Z+",7,5)):
        if abs(r[i]-b[j])>0.08+1e-3*abs(r[i]): m.append("%s ref=%.3f sih=%.3f"%(nme,r[i],b[j]))
print("; ".join(m) if m else "OK")
PY
)
  if [ "$res" = OK ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "seed $i: $res"; fi
done
echo "ok=$ok different=$bad"
