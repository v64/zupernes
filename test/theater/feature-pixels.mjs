// Pixel comparison helpers for the theater feature gate (feature-check.mjs).
// PNG decoding happens in the browser page (createImageBitmap + canvas),
// so the check needs no native image dependencies. Used to show the CRT
// on/off captures clearly differ while both stay non-blank; also asserts
// the fixture's asymmetric palette markers survive presentation (top-left
// green \| top-right red means correct orientation and channel order).
export async function createCanvasCompare(capturedScreens) {
  // capturedScreens: page -> {bytes on the on/off captures}.
  let onPng, offPng;
  return {
    capture(onBytes, offBytes) { onPng = onBytes; offPng = offBytes; },
    async diffInPage(page) {
      return await page.evaluate(async ([onB, offB]) => {
        async function rgb(bytes) {
          const bmp = await createImageBitmap(new Blob([new Uint8Array(bytes)], { type: "image/png" }));
          const c = document.createElement("canvas");
          c.width = bmp.width; c.height = bmp.height;
          const ctx = c.getContext("2d");
          ctx.drawImage(bmp, 0, 0);
          const d = ctx.getImageData(0, 0, c.width, c.height);
          return { w: c.width, h: c.height, d: Array.from(d.data) };
        }
        const a = await rgb(onB), b = await rgb(offB);
        if (a.w !== b.w || a.h !== b.h) throw new Error("capture sizes differ");
        let changed = 0, onNonBlank = 0, offNonBlank = 0;
        for (let i = 0; i < a.d.length; i += 4) {
          const onB1 = !!(a.d[i] | a.d[i + 1] | a.d[i + 2]);
          const offB1 = !!(b.d[i] | b.d[i + 1] | b.d[i + 2]);
          if (onB1) onNonBlank++;
          if (offB1) offNonBlank++;
          if (onB1 !== offB1 || Math.abs(a.d[i] - b.d[i]) > 8 ||
              Math.abs(a.d[i + 1] - b.d[i + 1]) > 8 || Math.abs(a.d[i + 2] - b.d[i + 2]) > 8) changed++;
        }
        function topRegion(day) { // average color of the top rows
          let r = 0, g = 0, b = 0, n = 0;
          for (let y = 0; y < 3; y++) for (let x = 0; x < day.w; x++) {
            const i = (y * day.w + x) * 4;
            r += day.d[i]; g += day.d[i + 1]; b += day.d[i + 2]; n++;
          }
          return [r / n, g / n, b / n];
        }
        const markerRow = function(day, x0, x1, y) {
          let r = 0, g = 0, b = 0, n = 0;
          for (let y2 = y; y2 < y + 4; y2++) for (let x = x0; x < x1; x++) {
            const i = (y2 * day.w + x) * 4;
            r += day.d[i]; g += day.d[i + 1]; b += day.d[i + 2]; n++;
          }
          return [r / n, g / n, b / n];
        };
        return {
          ratio: changed / (a.w * a.h),
          onNonBlank: onNonBlank / (a.w * a.h),
          offNonBlank: offNonBlank / (a.w * a.h),
          topOn: topRegion(a), topOff: topRegion(b),
          // leftmost / rightmost tile of the first tilemap row (tile 1
          // palette 1 = green at word 31's palette? see fixtures: word 31
          // uses palette 2 = red (0x7c00), word 0 uses palette 1 = green)
          leftOn: markerRow(a, 0, 6, 2), rightOn: markerRow(a, a.w - 6, a.w, 2),
          w: a.w, h: a.h,
        };
      }, [onPng, offPng]);
    },
    async assertMarkers(page) {
      const d = await this.diffInPage(page);
      // word 0 (left) tile 1 palette 1 -> CGRAM 1 = 0x03e0 green;
      // word 31 (right) palette 2 -> 0x7c00 red. With <<3 expansion these
      // are (0,0xF8,0) and (0xF8,0,0). Sample near the top row.
      // Fixture palette markers in SNES RGB15 (-bbbbbg gggrrrrr):
      //   word 0, palette 1, CGRAM 0x03e0 -> G=31: a GREEN tile.
      //   word 31, palette 2, CGRAM 0x7c00 -> B=31: a BLUE tile.
      // Seeing green left / blue right in the CAPTURE proves orientation
      // (left/right not mirrored) and channel order (B path -> blue output).
      const greenLeft = d.leftOn, blueRight = d.rightOn;
      if (greenLeft[1] < greenLeft[0] + 10 || greenLeft[1] < greenLeft[2] + 10)
        throw new Error(`left marker not green: ${greenLeft}`);
      if (blueRight[2] < blueRight[0] + 10 || blueRight[2] < blueRight[1] + 10)
        throw new Error(`right marker not blue: ${blueRight}`);
      return d;
    },
  };
}
