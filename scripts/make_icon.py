import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096  # supersampled canvas; final 1024
k = S / 1024

def sc(v): return v * k

def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def vertical_gradient(size, top, bottom):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        g.putpixel((0, y), lerp(top, bottom, y / 255))
    return g.resize((size, size), Image.BICUBIC)

def bezier(p0, p1, p2, p3, n=400):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        x = u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0]
        y = u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]
        pts.append((x, y))
    return pts

def polyline_len(pts):
    return sum(math.dist(pts[i], pts[i+1]) for i in range(len(pts)-1))

def split_at(pts, frac):
    total = polyline_len(pts); target = total * frac; run = 0
    for i in range(len(pts)-1):
        seg = math.dist(pts[i], pts[i+1])
        if run + seg >= target:
            t = (target - run) / seg
            p = (pts[i][0] + (pts[i+1][0]-pts[i][0])*t, pts[i][1] + (pts[i+1][1]-pts[i][1])*t)
            return pts[:i+1] + [p], [p] + pts[i+1:], p, (pts[i+1][0]-pts[i][0], pts[i+1][1]-pts[i][1])
        run += seg
    return pts, [pts[-1]], pts[-1], (1, 0)

def dashed(pts, dash, gap):
    out = []; cur = [pts[0]]; on = True; left = dash
    for i in range(len(pts)-1):
        a, b = pts[i], pts[i+1]
        seg = math.dist(a, b); pos = 0
        while seg - pos > left:
            pos += left
            t = pos / seg
            p = (a[0] + (b[0]-a[0])*t, a[1] + (b[1]-a[1])*t)
            if on: cur.append(p); out.append(cur)
            cur = [p]; on = not on; left = dash if on else gap
        left -= seg - pos
        if on: cur.append(b)
        else: cur = [b]
    if on and len(cur) > 1: out.append(cur)
    return out

def thick_line(draw, pts, width, fill):
    # Stamp discs densely along the path for a clean, evenly rounded stroke.
    r = width / 2
    step = max(1.0, r * 0.25)
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        n = max(1, int(math.dist(a, b) / step))
        for j in range(n + 1):
            t = j / n
            x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)

def rounded_star(cx, cy, ro, ri, points=5, n=900, rot=-math.pi/2):
    # Smooth star: radius blends between ro and ri with a cosine, so tips and valleys are rounded.
    pts = []
    for i in range(n + 1):
        a = rot + 2 * math.pi * i / n
        f = (math.cos(points * (a - rot)) + 1) / 2
        f = f ** 1.6
        r = ri + (ro - ri) * f
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts

inset, radius = sc(100), sc(185)
mask = squircle_mask(S, inset, radius)

# Background: deep slate to teal.
bg = vertical_gradient(S, (24, 38, 56), (12, 92, 96)).convert("RGBA")

# Faint cutting-mat grid.
grid = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(grid)
step = sc(64)
x = inset
while x < S - inset:
    gd.line([(x, 0), (x, S)], fill=(255, 255, 255, 22), width=int(sc(3)))
    x += step
y = inset
while y < S - inset:
    gd.line([(0, y), (S, y)], fill=(255, 255, 255, 22), width=int(sc(3)))
    y += step
bg = Image.alpha_composite(bg, grid)

# Material sheet (a rounded board) slightly lighter.
art = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# The cut path: a bold S-curve swoosh across the icon.
star = rounded_star(sc(512), sc(600), sc(270), sc(150), rot=-math.pi/2)
# Start the run just after the top tip and travel clockwise; the head sits at the upper-left shoulder.
start = 40
p = star[start:] + star[1:start + 1]
cut, todo, head, tan = split_at(p, 0.80)

ad = ImageDraw.Draw(art)
# Remaining path: dashed white.
for seg in dashed(todo, sc(30), sc(24)):
    thick_line(ad, seg, sc(20), (235, 245, 245, 230))

# Finished cut: glowing orange.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gl = ImageDraw.Draw(glow)
thick_line(gl, cut, sc(80), (255, 120, 30, 170))
glow = glow.filter(ImageFilter.GaussianBlur(sc(26)))
art = Image.alpha_composite(art, glow)
ad = ImageDraw.Draw(art)
thick_line(ad, cut, sc(34), (255, 140, 40, 255))
thick_line(ad, cut, sc(14), (255, 232, 190, 255))

# Beam from the top down to the cutting point.
beam = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(beam)
nozzle_y = sc(250)
bd.polygon([(head[0]-sc(10), nozzle_y), (head[0]+sc(10), nozzle_y), (head[0]+sc(4), head[1]), (head[0]-sc(4), head[1])], fill=(255, 190, 110, 255))
beam_glow = beam.filter(ImageFilter.GaussianBlur(sc(18)))
art = Image.alpha_composite(art, beam_glow)
art = Image.alpha_composite(art, beam)

# Spark burst at the cutting point.
spark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(spark)
r = sc(70)
sd.ellipse([head[0]-r, head[1]-r, head[0]+r, head[1]+r], fill=(255, 170, 60, 200))
spark = spark.filter(ImageFilter.GaussianBlur(sc(30)))
art = Image.alpha_composite(art, spark)
ad = ImageDraw.Draw(art)
r = sc(20)
ad.ellipse([head[0]-r, head[1]-r, head[0]+r, head[1]+r], fill=(255, 255, 240, 255))
for ang in range(0, 360, 45):
    a = math.radians(ang + 22)
    l1, l2 = sc(36), sc(36 + (40 if ang % 90 == 0 else 26))
    ad.line([(head[0]+math.cos(a)*l1, head[1]+math.sin(a)*l1), (head[0]+math.cos(a)*l2, head[1]+math.sin(a)*l2)],
            fill=(255, 225, 160, 255), width=int(sc(9)))

# Laser head: a rounded metal block with a nozzle, at the top.
hd = ImageDraw.Draw(art)
hx = head[0]
body = [hx - sc(110), sc(150), hx + sc(110), sc(235)]
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([body[0], body[1]+sc(14), body[2], body[3]+sc(24)], radius=sc(26), fill=(0, 0, 0, 120))
shadow = shadow.filter(ImageFilter.GaussianBlur(sc(14)))
art = Image.alpha_composite(art, shadow)
hd = ImageDraw.Draw(art)
metal = vertical_gradient(S, (236, 240, 244), (150, 162, 176)).convert("RGBA")
mmask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mmask)
md.rounded_rectangle(body, radius=sc(26), fill=255)
md.polygon([(hx - sc(42), sc(232)), (hx + sc(42), sc(232)), (hx + sc(16), sc(272)), (hx - sc(16), sc(272))], fill=255)
art.paste(metal, (0, 0), mmask)
hd = ImageDraw.Draw(art)
hd.rounded_rectangle([hx - sc(70), sc(180), hx + sc(70), sc(198)], radius=sc(9), fill=(255, 140, 40, 255))

# Composite inside the squircle.
icon = Image.alpha_composite(bg, art)
# Soft top highlight.
hl = vertical_gradient(S, (255, 255, 255), (255, 255, 255)).convert("RGBA")
hl.putalpha(vertical_gradient(S, (40,), (0,)).convert("L") if False else Image.linear_gradient("L").resize((S, S)).point(lambda v: int((255 - v) * 0.10)))
icon = Image.alpha_composite(icon, hl)

out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# Drop shadow under the tile.
ds = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ds).rounded_rectangle([inset, inset + sc(12), S - inset, S - inset + sc(12)], radius=radius, fill=(0, 0, 0, 110))
ds = ds.filter(ImageFilter.GaussianBlur(sc(18)))
out = Image.alpha_composite(out, ds)
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tile.paste(icon, (0, 0), mask)
out = Image.alpha_composite(out, tile)
# Thin inner edge.
edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(edge).rounded_rectangle([inset, inset, S - inset, S - inset], radius=radius, outline=(255, 255, 255, 40), width=int(sc(4)))
out = Image.alpha_composite(out, edge)

final = out.resize((1024, 1024), Image.LANCZOS)
final.save(sys.argv[1])
