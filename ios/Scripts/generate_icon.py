"""Original geometric Obsidian icon. Requires Pillow; no downloaded artwork."""
from pathlib import Path
from PIL import Image, ImageDraw

SIZE = 2048
image = Image.new("RGB", (SIZE, SIZE), "#111416")
draw = ImageDraw.Draw(image)
gold = "#DCC59D"
muted = "#93836A"
draw.rounded_rectangle((190, 190, 1858, 1858), radius=380, fill="#1C2125")
# An open book forms the lower arc; the center rises into a voice waveform.
draw.polygon([(445, 680), (875, 750), (990, 830), (990, 1490), (860, 1420), (445, 1350)], fill=gold)
draw.polygon([(1058, 830), (1173, 750), (1603, 680), (1603, 1350), (1188, 1420), (1058, 1490)], fill=muted)
draw.line([(505, 794), (845, 852), (916, 899)], fill="#1C2125", width=22)
draw.line([(505, 905), (845, 963), (916, 1010)], fill="#1C2125", width=22)
draw.line([(1538, 794), (1203, 852), (1130, 899)], fill="#1C2125", width=22)
draw.line([(1538, 905), (1203, 963), (1130, 1010)], fill="#1C2125", width=22)
for x, top, bottom in [(844, 492, 622), (964, 420, 657), (1084, 462, 647), (1204, 510, 603)]:
    draw.rounded_rectangle((x, top, x + 40, bottom), radius=20, fill=gold)
destination = Path(__file__).parents[1] / "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
image.resize((1024, 1024), Image.Resampling.LANCZOS).save(destination)
print(destination)
