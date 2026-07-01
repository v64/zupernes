#!/usr/bin/env python3
"""Generate minimal Mode 7 test ROMs.

Produces LoROM images that set up a Mode 7 plane and display it with a
chosen transform matrix. The plane is tile 0 repeated everywhere, and
tile 0 contains vertical stripes (columns alternate palette colors 1/2)
with the top-left pixel marked color 3, so orientation, scale, and
rotation are all visually verifiable:

  mode7-identity.sfc  - 1:1 view: vertical white/red stripes, 8px wide
  mode7-rot45.sfc     - 45-degree rotation, ~1.4x zoom out: diagonal stripes

Usage: python3 make_mode7_rom.py <output_dir>
"""

import struct
import sys


def asm(code_bytes):
    return bytes(code_bytes)


def lda_imm(v):  # LDA #imm (8-bit A)
    return [0xA9, v & 0xFF]


def sta_abs(addr):
    return [0x8D, addr & 0xFF, (addr >> 8) & 0xFF]


def build_rom(m7a, m7b, m7c, m7d):
    code = []
    code += [0x78]              # SEI
    code += [0x18, 0xFB]        # CLC; XCE (enter native mode, M/X stay 8-bit)

    code += lda_imm(0x80) + sta_abs(0x2100)   # INIDISP: force blank

    # --- CGRAM: 0=dark blue, 1=white, 2=red, 3=green ---
    code += lda_imm(0x00) + sta_abs(0x2121)
    for lo, hi in ((0x00, 0x28), (0xFF, 0x7F), (0x1F, 0x00), (0xE0, 0x03)):
        code += lda_imm(lo) + sta_abs(0x2122)
        code += lda_imm(hi) + sta_abs(0x2122)

    # --- Tile 0 pixel data (Mode 7 chr = HIGH bytes of words 0-63) ---
    # VMAIN = $80: increment word address after writing $2119 (high byte)
    code += lda_imm(0x80) + sta_abs(0x2115)
    code += lda_imm(0x00) + sta_abs(0x2116) + sta_abs(0x2117)  # VMADD = 0
    # 64 pixels: column stripes (1,1,1,1,2,2,2,2), row 0 col 0 = 3 (marker)
    for row in range(8):
        for col in range(8):
            if row == 0 and col == 0:
                color = 3
            else:
                color = 1 if col < 4 else 2
            code += lda_imm(color) + sta_abs(0x2119)

    # Tilemap (LOW bytes) is left at 0 = tile 0 everywhere. Our emulator
    # zero-fills VRAM; a hardware version of this test would clear it here.

    # --- Mode 7 matrix (write-twice: low byte then high byte) ---
    for reg, val in ((0x211B, m7a), (0x211C, m7b), (0x211D, m7c), (0x211E, m7d)):
        code += lda_imm(val & 0xFF) + sta_abs(reg)
        code += lda_imm((val >> 8) & 0xFF) + sta_abs(reg)
    # Center and scroll = 0
    for reg in (0x211F, 0x2120, 0x210D, 0x210E):
        code += lda_imm(0x00) + sta_abs(reg) + sta_abs(reg)

    code += lda_imm(0x07) + sta_abs(0x2105)   # BGMODE = 7
    code += lda_imm(0x01) + sta_abs(0x212C)   # TM: BG1 on main screen
    code += lda_imm(0x0F) + sta_abs(0x2100)   # INIDISP: screen on, full bright

    # forever: JMP forever
    loop_addr = 0x8000 + len(code)
    code += [0x4C, loop_addr & 0xFF, (loop_addr >> 8) & 0xFF]

    rom = bytearray(0x8000)  # one 32KB LoROM bank
    rom[0 : len(code)] = bytes(code)

    # --- Internal header at $7FC0 ---
    title = b"MODE7 TEST           "
    rom[0x7FC0 : 0x7FC0 + 21] = title
    rom[0x7FD5] = 0x20  # LoROM, SlowROM
    rom[0x7FD6] = 0x00  # ROM only
    rom[0x7FD7] = 0x08  # 256KB (log2(size/1KB)) - conventional minimum
    rom[0x7FD8] = 0x00  # No SRAM
    rom[0x7FD9] = 0x01  # NTSC
    # Checksum: complement pair (not validated by our loader, keep sane)
    checksum = sum(rom) & 0xFFFF
    rom[0x7FDC:0x7FDE] = struct.pack("<H", checksum ^ 0xFFFF)
    rom[0x7FDE:0x7FE0] = struct.pack("<H", checksum)
    # Emulation-mode reset vector -> $8000
    rom[0x7FFC:0x7FFE] = struct.pack("<H", 0x8000)

    return bytes(rom)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    # Identity: A=D=1.0 (0x0100), B=C=0
    with open(f"{outdir}/mode7-identity.sfc", "wb") as f:
        f.write(build_rom(0x0100, 0x0000, 0x0000, 0x0100))
    # 45 degrees, matrix = [cos -sin; sin cos] scaled by 256:
    # cos45*256 = sin45*256 = 181 (0xB5). Screen-to-texture mapping uses
    # [A B; C D] directly, so B = -181 = 0xFF4B two's complement.
    with open(f"{outdir}/mode7-rot45.sfc", "wb") as f:
        f.write(build_rom(0x00B5, 0xFF4B, 0x00B5, 0x00B5))
    print(f"Wrote mode7-identity.sfc and mode7-rot45.sfc to {outdir}")


if __name__ == "__main__":
    main()
