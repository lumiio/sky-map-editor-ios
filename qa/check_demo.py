"""模拟器自测：把 app 截的图找一遍，画面如果还是 clearColor 就判定一帧都没画上去。"""
import sys
from PIL import Image

CLEAR = (8, 13, 23)          # clearColor 0.03/0.05/0.09，sRGB 下约等于这个值
TOLERANCE = 6

path = sys.argv[1]
image = Image.open(path).convert("RGB")
width, height = image.size
pixels = list(image.getdata())

distinct = len(set(pixels))
clear = 0
for r, g, b in pixels:
    if abs(r - CLEAR[0]) <= TOLERANCE and abs(g - CLEAR[1]) <= TOLERANCE and abs(b - CLEAR[2]) <= TOLERANCE:
        clear += 1
clear_ratio = clear / len(pixels)
top = sorted(set(pixels), key=pixels.count, reverse=True)[:5]
print(f"{width}x{height} distinct={distinct} clear={clear_ratio:.3f} top={top}")

if distinct < 8 or clear_ratio > 0.97:
    print("FAIL: 画面与清屏色一致，说明没有画出地形")
    sys.exit(1)
print("PASS: 画面有真实渲染内容")
