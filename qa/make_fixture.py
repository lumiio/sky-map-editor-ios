"""造一个结构合法、能被 App 真正解析的最小关卡，用来做端到端回归。

输出布局模拟真实 ipa：
    Payload/SkyMapEditor.app/Data/Levels/Demo/Objects.level.bin
    Payload/SkyMapEditor.app/Data/Levels/Demo/BstBaked.meshes

TGCL：44 字节头 + 1 个类（0 个字段）+ 1 个节点。
LVL0：52 版，1 个 LOD0 段，1 条地形记录（一个三角形）。
"""
import struct
import sys
import zlib
from pathlib import Path


def tgcl() -> bytes:
    name_pool = b"Demo\0"
    class_offset = 44
    field_offset = class_offset + 12
    name_pool_offset = field_offset
    node_offset = name_pool_offset + len(name_pool)
    node = struct.pack("<I", 0) + b"Demo\0"
    total = node_offset + len(node)
    header = struct.pack(
        "<10I", 1, 1, 0, 1, 0,
        class_offset, field_offset, name_pool_offset, node_offset, total,
    )
    class_entry = struct.pack("<III", 0, 0, 0)      # nameOffset, firstField, fieldCount
    return b"TGCL" + header + class_entry + name_pool + node


def lz4_literal(payload: bytes) -> bytes:
    n = len(payload)
    out = bytearray([min(n, 15) << 4])
    if n >= 15:
        extra = n - 15
        while extra >= 255:
            out.append(255)
            extra -= 255
        out.append(extra)
    out += payload
    return bytes(out)


def vertex(x: float, y: float, z: float) -> bytes:
    out = struct.pack("<3f", x, y, z)
    out += bytes([0, 127, 0, 0])          # 法线朝上
    out += bytes([1, 0, 0, 0])            # 材质 id 1
    out += bytes([255, 0, 0, 0])          # 权重
    out += bytes(12)                       # light0..2
    assert len(out) == 36
    return out


def lvl0() -> bytes:
    body = b""
    body += struct.pack("<I", 0)                              # 烘焙记录数
    body += struct.pack("<I", 1)                              # 地形记录数
    body += struct.pack("<I", 0)                              # linkedId
    body += struct.pack("<B", 0)                              # flags
    body += struct.pack("<6f", -10, -10, -10, 10, 10, 10)      # bounds
    body += struct.pack("<II", 3, 3)                           # vc / ic
    body += vertex(-10, 0, -10) + vertex(10, 0, -10) + vertex(0, 0, 10)
    body += struct.pack("<I", 0)                              # collisionBytes
    body += struct.pack("<6f", -10, -10, -10, 10, 10, 10)      # gridBounds
    body += struct.pack("<f", 1.0)                             # cellSize
    body += struct.pack("<3I", 1, 1, 1)                        # dimensions
    body += struct.pack("<I", 1)                               # patchCount
    body += struct.pack("<2I", 3, 0)                           # patchIndices / patchFlags
    body += struct.pack("<3I", 0, 0, 0)                        # nec / ne / ni
    body += struct.pack("<3H", 0, 1, 2)                        # 索引
    body += struct.pack("<I", 0)                              # 云：不存在
    body += struct.pack("<I", 0)                              # 裙边数量
    body += struct.pack("<I", 0)                              # 遮挡体数量

    packed = lz4_literal(body)
    header = b"LVL0" + struct.pack("<I", 52) + bytes([1, 0, 0, 0])
    header += b"LOD0" + struct.pack("<II", 132, len(packed))
    header += bytes(132 - len(header))
    return header + packed


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/fixture") / "Payload" / "SkyMapEditor.app" / "Data" / "Levels" / "Demo"
    root.mkdir(parents=True, exist_ok=True)
    (root / "Objects.level.bin").write_bytes(tgcl())
    (root / "BstBaked.meshes").write_bytes(lvl0())
    print(f"fixture: {root}")
    print(f"  Objects.level.bin {(root / 'Objects.level.bin').stat().st_size} bytes")
    print(f"  BstBaked.meshes  {(root / 'BstBaked.meshes').stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
