import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()
out = []
for line in text.splitlines():
    code = re.sub(r"\([^)]*\)", " ", line).split(";")[0]
    if re.search(r"\bG(28|30|53|92|10|91\.1|90\.1)\b|\bG(28|30|92)\.\d\b|\bM(98|97|99)\b", code, re.I):
        continue
    out.append(code)
body = "\n".join(out) + "\n"
if re.search(r"#|WHILE|\bIF\b|GOTO|\bG(41|42|43\.1|65|68|69|51|52|16|7[346]|8[1-9])\b", body, re.I):
    print("REFUSE"); sys.exit()
open(dst, "w").write(body)
print("OK")
