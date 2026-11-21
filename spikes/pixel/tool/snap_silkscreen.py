#!/usr/bin/env python3
# Genera una variante di Silkscreen con TUTTE le coordinate dei glifi
# arrotondate alla griglia del font (125 unità = 1/8 em). L'originale ha
# 48 glifi con controforme spostate di 5 unità (130/495) che producono pixel
# grigi anche a dimensioni intere. Licenza OFL 1.1: la modifica è permessa,
# il font non dichiara Reserved Font Name; rinominiamo comunque la famiglia.
# Uso: python3 -I tool/snap_silkscreen.py <in.ttf> <out.ttf>   (richiede fontTools, MIT)
import sys
from fontTools.ttLib import TTFont

src, dst = sys.argv[1], sys.argv[2]
f = TTFont(src)
glyf = f["glyf"]
G = 125
changed = 0
for name in f.getGlyphOrder():
    g = glyf[name]
    if g.numberOfContours <= 0:
        continue
    co = g.coordinates
    for i, (x, y) in enumerate(co):
        nx, ny = round(x / G) * G, round(y / G) * G
        if (nx, ny) != (x, y):
            co[i] = (nx, ny)
            changed += 1
    g.recalcBounds(glyf)
for rec in f["name"].names:
    if rec.nameID in (1, 4, 16):
        rec.string = rec.toUnicode().replace("Silkscreen", "Silkscreen Grid")
    if rec.nameID == 6:
        rec.string = rec.toUnicode().replace("Silkscreen", "SilkscreenGrid")
f.save(dst)
print(f"{dst}: {changed} coordinate riallineate")
