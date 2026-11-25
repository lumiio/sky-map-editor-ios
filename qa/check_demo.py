"""模拟器自测：截图里必须真的有渲染内容。

判据：颜色种类够多、最大单色占比不高、中部区域不是纯色。
不看具体颜色：清屏色是线性色经 sRGB 转换后的值，硬编码会误判。
"""
import sys
from collections import Counter
from PIL import Image

path = sys.argv[1]
image = Image.open(path).convert("RGB")
width, height = image.size
pixels = list(image.getdata())
counter = Counter(pixels)
top_color, top_count = counter.most_common(1)[0]
ratio = top_count / len(pixels)

center = image.crop((width // 4, height // 3, width * 3 // 4, height * 2 // 3))
center_colors = len(Counter(center.getdata()))

print(f"{width}x{height} distinct={len(counter)} top={top_color} ratio={ratio:.3f} centerDistinct={center_colors}")

failed = []
if len(counter) < 64:
    failed.append("颜色种类太少")
if ratio > 0.90:
    failed.append("最大单色占比过高")
if center_colors < 16:
    failed.append("画面中部是纯色")
if failed:
    print("FAIL:", "，".join(failed))
    sys.exit(1)
print("PASS: 画面有真实渲染内容")
