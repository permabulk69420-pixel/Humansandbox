# Builds the club's seating texture atlas: one 1024 x 1024 set of maps (colour, normal, ARM) holding every surface the stools and booths
# are made of, so each of them is ONE material and costs ONE draw call (and all of them in a room can be drawn together as a MultiMesh).
#
#   python3 tools/make_club_atlas.py
#
# Quadrants (image space, origin top left; make_club_seating.py maps its faces into them):
#   top left     red leather  (Poly Haven leather_red_03, the whole 1k tile shrunk to 512, tinted like the club's other leather)
#   top right    chrome       (flat; a metal of 0.8 and not 1.0: with nothing round it to reflect, a full metal renders black)
#   bottom left  black lacquer (flat, glossy)
#   bottom right brushed dark steel (flat; spare)
# Maps come out as assets/club/textures/seating_atlas/seating_atlas_{diff,nor,arm}.jpg, ARM being occlusion, roughness, metal in R, G, B.
import os
from PIL import Image, ImageChops

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LEATHER = os.path.join(ROOT, "art/club/leather_red_03/leather_red_03_%s.jpg")
OUT = os.path.join(ROOT, "assets/club/textures/seating_atlas")
TINT = (204, 166, 179)          # the club's leather tint, Color(0.8, 0.65, 0.7)
SIZE = 1024
Q = SIZE // 2

FLAT = {
    # name: (colour, ARM)
    "chrome": ((199, 199, 209), (255, 56, 204)),       # rough 0.22, metal 0.8
    "lacquer": ((13, 11, 14), (255, 77, 0)),           # rough 0.3, no metal
    "steel": ((20, 20, 24), (255, 115, 153)),          # rough 0.45, metal 0.6
}
NORMAL_FLAT = (128, 128, 255)


def build():
    os.makedirs(OUT, exist_ok=True)
    diff = Image.new("RGB", (SIZE, SIZE))
    nor = Image.new("RGB", (SIZE, SIZE), NORMAL_FLAT)
    arm = Image.new("RGB", (SIZE, SIZE))
    # leather, top left
    d = Image.open(LEATHER % "diff").convert("RGB").resize((Q, Q), Image.LANCZOS)
    diff.paste(ImageChops.multiply(d, Image.new("RGB", (Q, Q), TINT)), (0, 0))
    nor.paste(Image.open(LEATHER % "nor").convert("RGB").resize((Q, Q), Image.LANCZOS), (0, 0))
    arm.paste(Image.open(LEATHER % "arm").convert("RGB").resize((Q, Q), Image.LANCZOS), (0, 0))
    # the flat ones
    for name, (col, row) in (("chrome", (1, 0)), ("lacquer", (0, 1)), ("steel", (1, 1))):
        colour, armv = FLAT[name]
        diff.paste(Image.new("RGB", (Q, Q), colour), (col * Q, row * Q))
        arm.paste(Image.new("RGB", (Q, Q), armv), (col * Q, row * Q))
    for name, img in (("diff", diff), ("nor", nor), ("arm", arm)):
        path = os.path.join(OUT, "seating_atlas_%s.jpg" % name)
        img.save(path, quality=92, subsampling=0)
        print(path, os.path.getsize(path))


if __name__ == "__main__":
    build()
