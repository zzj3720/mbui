# (bench-corners) a draw list of 48 cards rounded 20 and 96 rows rounded 12 in them, 960x720 at 2x
import sys
out = ["mbui-dl 4", "window 960 720 2", "clear 1 1 1"]
def box(x, y, w, h, r, c):
    n = [x, y, w, h, r, 0, 0, 0, c, c, c, 1, 0, 0, 0, 0, 0, 0, 1000000000, 1000000000] + [0] * 12
    out.append("i " + " ".join(str(v) for v in n))
for j in range(6):
    for i in range(8):
        x, y = 10 + i * 118, 10 + j * 118
        box(x, y, 110, 110, 20, 0.9)
        box(x + 8, y + 8, 94, 44, 12, 0.7)
        box(x + 8, y + 58, 94, 44, 12, 0.7)
open(sys.argv[1], "w").write("\n".join(out) + "\n")
