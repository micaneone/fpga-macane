"""gen_font_dat.py -- regenerate prj/font_cn.dat from tools/font_cn_table.py

The .dat is the INIT_FILE of EG_PHY_BRAM32K inside b_display/font_cn.v:
    2048 lines x 16 bits, binary, MSB first (TD ROM-IP .dat format).
    address a = 2*wi + {0: low 16 bits, 1: high 8 bits}
    wi = (ch-10)*24 + gy           (gy = 0 is the TOP screen line)

Usage:  python tools/gen_font_dat.py        (from anywhere)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from font_cn_table import GLYPHS

ROOT = os.path.dirname(HERE)
# 2026-10-25: TD 在综合阶段按 ***.v 源文件所在目录*** 去找 INIT_FILE
# (先放 prj/ 试过：SYN-8142 "font_cn.dat can not be found")，所以 .dat
# 必须和 b_display/font_cn.v 放在一起。
OUT = os.path.join(ROOT, "b_display", "font_cn.dat")


def word(wi):
    if wi >= len(GLYPHS) * 24:          # 288 useful words, rest stays 0
        return 0
    ch, gy = 10 + wi // 24, wi % 24
    return GLYPHS[ch][23 - gy]


def main():
    lines = []
    for a in range(2048):
        w = word(a // 2)
        if a % 2 == 0:
            lines.append(format(w & 0xFFFF, "016b"))
        else:
            lines.append(format((w >> 16) & 0xFF, "08b").rjust(16, "0"))
    with open(OUT, "w", newline="") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s (%d bytes, %d lines)" % (OUT, os.path.getsize(OUT), len(lines)))


if __name__ == "__main__":
    main()
