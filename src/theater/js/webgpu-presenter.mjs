// Copied VERBATIM from ZuperWorld src/theater/js/webgpu-presenter.mjs at
// commit 954e3f72 (main), per test/theater/TASK.md: "Use its real CRT
// shader, not a CSS filter or an unrelated approximation ... Preserve the
// shader's behavior." The ONLY additions below are device-loss tracking
// (lostdevice) so the theater host can recover visibly, and an exported
// `destroy`. Everything else - the plain 1:1 quad pipeline ("plain
// pipeline (CRT off) ... kept byte-for-byte") and the Lottes-lineage CRT
// scanline/phosphor pass - is untouched, so CRT-off remains a true bypass
// and the filter keeps its energy-neutral beam and mask behavior.
// No runtime sibling dependency: this file lives in this project.

// THE WebGPU presenter, shared by the page (main.mjs) and the engine worker.
// The worker passes a Uint8Array view over wasm memory; the page's main-thread
// lane passes the transferred framebuffer copy. Both lanes construct their
// presenter here, so there is exactly one copy of the plain and CRT pipelines
// and one place to tune them.
//
// The caller owns everything that is NOT presentation: canvas CSS fitting, the
// CRT preference key, backend selection. This module owns the device, the
// context configuration, the source texture, both pipelines, and the backing
// store resolution it was configured with.

export async function createWebGpuPresenter(canvas, gpuApi = globalThis.navigator?.gpu) {
  if (!gpuApi) throw new Error("WebGPU is unavailable");
  const adapter = await gpuApi.requestAdapter();
  if (!adapter) throw new Error("WebGPU returned no adapter");
  const device = await adapter.requestDevice();
  // ZuperNES theater addition (file otherwise verbatim from ZuperWorld):
  // track the device-lost promise so the host can fall back visibly.
  const lost = device.lost.then((info) => ({ reason: info.reason }));
  lost.catch(() => {});
  const format = gpuApi.getPreferredCanvasFormat();
  let ctx = null;
  let sourceWidth = 0, sourceHeight = 0;
  let crtOn = false;
  let frameTexture = null;
  let crtUniform = null;
  let presentBase = null, presentCRT = null;
  const counters = { canvasAttachments: 0, geometryRebuilds: 0, presents: 0 };

  function attachCanvas(nextCanvas) {
    canvas = nextCanvas;
    ctx = canvas.getContext("webgpu");
    if (!ctx) throw new Error("canvas has no WebGPU context");
    ctx.configure({ device, format, alphaMode: "opaque" });
    counters.canvasAttachments++;
  }
  attachCanvas(canvas);

  function drawQuad(pipeline, bind) {
    const encoder = device.createCommandEncoder();
    const pass = encoder.beginRenderPass({
      colorAttachments: [{ view: ctx.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store" }],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bind);
    pass.draw(3);
    pass.end();
    device.queue.submit([encoder.finish()]);
  }

  // (Re)builds every SOURCE-SIZE-DEPENDENT object against the wasm's current
  // framebuffer geometry: the source texture, both pipelines, and their bind
  // groups (the plain shader bakes the source size into its code). The device,
  // context, and format are size-independent and created exactly once.
  function buildSizedPresenters() {
    counters.geometryRebuilds++;
    frameTexture?.destroy();
    crtUniform?.destroy();
    // The SOURCE frame lives in ONE texture, re-uploaded every present and
    // SHARED by both pipelines - nothing about the source changes between the
    // plain and CRT paths, only how we sample it.
    frameTexture = device.createTexture({
      size: [sourceWidth, sourceHeight], format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    const textureView = frameTexture.createView();
    const nearest = device.createSampler({ magFilter: "nearest", minFilter: "nearest" });
    // The CRT horizontal blur samples at sub-source-pixel phase, so it needs
    // interpolation between texels - a linear sampler.
    const linear = device.createSampler({ magFilter: "linear", minFilter: "linear" });
    const uploadFrame = (frame) => device.queue.writeTexture(
      { texture: frameTexture }, frame, { bytesPerRow: sourceWidth * 4 }, [sourceWidth, sourceHeight],
    );

    // ---- plain pipeline (CRT off): the original 1:1 textured quad, kept
    //      byte-for-byte so disabling the filter is a true no-op ----
    const shader = device.createShaderModule({ code: `
      @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        var p = array<vec2f, 3>(vec2f(-1, -3), vec2f(-1, 1), vec2f(3, 1));
        return vec4f(p[i], 0, 1);
      }
      @group(0) @binding(0) var t: texture_2d<f32>;
      @group(0) @binding(1) var s: sampler;
      @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        return textureSample(t, s, pos.xy / vec2f(${sourceWidth}.0, ${sourceHeight}.0));
      }` });
    const pipeline = device.createRenderPipeline({
      layout: "auto",
      vertex: { module: shader, entryPoint: "vs" },
      fragment: { module: shader, entryPoint: "fs", targets: [{ format }] },
    });
    const bind = device.createBindGroup({
      layout: pipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: textureView },
        { binding: 1, resource: nearest },
      ],
    });
    presentBase = (frame) => { uploadFrame(frame); drawQuad(pipeline, bind); };

    // ---- CRT pipeline (single pass, crt-easymode lineage, rectilinear -
    //      deliberately NO barrel distortion) ----
    //
    // SMW's pixel art was authored for composite-fed CRTs. Two physical facts
    // of that display shaped the art, and both are LOST on a modern sharp LCD
    // showing hard nearest-neighbour pixels:
    //   1. The emitter's finite horizontal BANDWIDTH blurred neighbouring
    //      pixels together. Artists exploited this: 1px-period dither
    //      checkerboards were never meant to read as a grid - they fused into
    //      flat translucency and smooth gradients. (Look at SMW's waterfalls,
    //      cave shading, semi-transparent tides.)
    //   2. The electron BEAM painted each source row as a soft-edged
    //      horizontal SCANLINE. (Real tubes also bloomed bright rows a little
    //      wider; we tried modelling that and dropped it - see the History
    //      note in the shader constants.)
    // This shader reconstructs both, plus a faint aperture-grille phosphor
    // mask, and it does the mixing in LINEAR light (decode gamma -> blend ->
    // re-encode) so blends match the analog original instead of muddying in
    // gamma space the way a naive average would.
    const crtShader = device.createShaderModule({ code: `
      // ---- tuning constants (all lengths in SOURCE pixels unless noted) ----
      //
      // The kernel widths follow Timothy Lottes' CRT filter (public domain,
      // so direct formula reuse is licence-clean; see his "CrtsFilter" / GPU
      // Pro writeup). Lottes writes every kernel as exp2(hard * d^2).
      // Converting to our gaussian exp(-d^2 / (2*sigma^2)):
      //     exp2(h*d^2) = exp(h*ln2*d^2)  =>  sigma^2 = -1 / (2*h*ln2)
      // so a "hardness" IS just a fixed-width gaussian - the same family,
      // fed through the normalized-energy pipeline below.
      //     hardScan = -8  ->  sigma^2 = 1/(2*8*ln2) = 0.0902 -> sigma ~= 0.300
      //     hardPix  = -3  ->  sigma^2 = 1/(2*3*ln2) = 0.2405 -> sigma ~= 0.490
      //
      // History: we first shipped a hand-tuned variant (horizontal sigma 0.7,
      // beam sigma brightness-widened 0.55->1.15 so bright rows bloomed wider).
      // An A/B against Lottes' fixed-width beam was a clear win to the eye -
      // sharper scanlines, no per-row width pumping - so Lottes' constants are
      // now THE shader, not a mode. (crt-royale remains the multi-pass
      // physical reference we deliberately do NOT chase in a single pass;
      // this is the cheap one-pass cousin.)
      const GAMMA: f32 = 2.2;          // CRT-ish transfer: decode to linear, re-encode
      const BEAM_SIGMA: f32 = 0.300;   // fixed scanline beam sigma, from hardScan=-8
      const PIX_SIGMA: f32 = 0.490;    // horizontal composite blur sigma, from
                                       //   hardPix=-3. Still fuses 1px dither into
                                       //   translucency while HUD text stays legible.
      const MASK_HI_RAW: f32 = 1.5;    // Lottes' aperture-grille light/dark pair -
      const MASK_LO_RAW: f32 = 0.5;    //   a 3:1 ratio, energy-neutralised below.
      const MASK_FADE_LO: f32 = 2.0;   // below 2x device scale the RGB triad aliases
      const MASK_FADE_HI: f32 = 3.0;   //   into fringes, so fade the mask out under 3x

      struct U { srcSize: vec2f, outSize: vec2f };
      @group(0) @binding(0) var t: texture_2d<f32>;
      @group(0) @binding(1) var s: sampler;
      @group(0) @binding(2) var<uniform> u: U;

      fn toLinear(c: vec3f) -> vec3f { return pow(c, vec3f(GAMMA)); }
      fn toGamma(c: vec3f) -> vec3f { return pow(c, vec3f(1.0 / GAMMA)); }

      // Horizontal-only gaussian blur of ONE source row, evaluated at the
      // continuous source-x \`sx\` with width PIX_SIGMA (Lottes' hardPix=-3).
      // Taps step by whole source pixels (the emitter's bandwidth is a
      // horizontal property); the linear sampler resolves the sub-pixel
      // phase. Normalised by wsum, so it is a weighted AVERAGE: a flat field
      // returns itself unchanged (horizontally energy-neutral by construction).
      // Returned in LINEAR light so the caller can keep blending physically.
      fn rowBlur(sx: f32, rowCenterY: f32) -> vec3f {
        var acc = vec3f(0.0);
        var wsum = 0.0;
        let inv2s2 = 1.0 / (2.0 * PIX_SIGMA * PIX_SIGMA);
        for (var i = -2; i <= 2; i = i + 1) {
          let d = f32(i);
          let w = exp(-d * d * inv2s2);
          let uv = vec2f((sx + d) / u.srcSize.x, rowCenterY / u.srcSize.y);
          acc = acc + toLinear(textureSample(t, s, uv).rgb) * w;
          wsum = wsum + w;
        }
        return acc / wsum;
      }

      // Vertical beam ENERGY normalisation. INVARIANT: a flat field renders
      // with mean device luminance equal to the source, at ANY beam sigma and
      // ANY integer scale k. The scanline then only REDISTRIBUTES a row's
      // energy - the beam peaks on the row centre and the inter-row gaps
      // darken - instead of adding or losing brightness. This is what
      // replaced an earlier eyeballed BRIGHT multiplier outright.
      //
      // N = the beam summed over the k device rows of one source-row pitch,
      // then averaged (the beam's DISCRETE vertical integral over a pitch).
      // We use the discrete sum, NOT the continuous sigma*sqrt(2*pi): at k=3-4
      // only a handful of device rows sample the gaussian and the discrete sum
      // differs measurably from the continuous integral - the discrete value
      // is the one that makes OUR actual sampling conserve (verified to <1% by
      // src/theater/test/crt-energy-check.mjs). Each device row sees its two
      // bracketing source rows at vertical distances d and 1-d, so one pitch of
      // the beam-comb is  sum_j [ exp(-d_j^2/2s^2) + exp(-(1-d_j)^2/2s^2) ],
      // and dividing every row's weight by N=that/k makes the comb average to 1.
      fn beamNorm(sigma: f32, kf: f32) -> f32 {
        let ki = i32(kf + 0.5);
        let inv2s2 = 1.0 / (2.0 * sigma * sigma);
        var acc = 0.0;
        for (var j = 0; j < ki; j = j + 1) {
          // d = this device row's distance to the source-row centre below it,
          // exactly as the fragment picks its two rows: device-row centre sits
          // at (j+0.5)/k in source space, source-row centres on the x.5 grid.
          let d = fract((f32(j) + 0.5) / kf + 0.5);
          acc = acc + exp(-d * d * inv2s2) + exp(-(1.0 - d) * (1.0 - d) * inv2s2);
        }
        return acc / kf;
      }

      @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        var p = array<vec2f, 3>(vec2f(-1, -3), vec2f(-1, 1), vec2f(3, 1));
        return vec4f(p[i], 0, 1);
      }

      @fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        // Integer canvas factor k, recovered from the uniforms (never
        // hardcoded), so this scales with any window size or aspect mode.
        let k = u.outSize.y / u.srcSize.y;
        let src = pos.xy / k;            // continuous source-texel coords

        // Scanline beam: sum the two nearest source rows, each a fixed-width
        // gaussian centred on its own row, ENERGY-NORMALISED per row (divide
        // by beamNorm) so the scanline REDISTRIBUTES each row's brightness
        // rather than darkening the frame (an earlier build patched that loss
        // with a global BRIGHT fudge - deleted). The inter-row gaps darken;
        // the row totals are untouched. Computing against each row's centre
        // in source space makes the beam scale with any integer k
        // automatically. With BEAM_SIGMA constant, beamNorm(k) is uniform per
        // frame - the compiler can hoist it - but we keep the call in the loop
        // so the energy story reads in one place.
        let n = floor(src.y - 0.5);      // index of the upper of the two rows
        var col = vec3f(0.0);
        for (var r = 0; r <= 1; r = r + 1) {
          let center = n + f32(r) + 0.5; // source-row centre (texel space)
          let c = rowBlur(src.x, center);
          let dy = src.y - center;
          col = col + c * exp(-dy * dy / (2.0 * BEAM_SIGMA * BEAM_SIGMA)) / beamNorm(BEAM_SIGMA, k);
        }

        // Aperture-grille phosphor mask in DEVICE pixels: consecutive columns
        // lean to R, G, then B. Faded out below ~3x, where a one-device-pixel
        // triad would alias into visible colour fringes instead of reading as
        // fine texture.
        //
        // ENERGY-NEUTRAL per channel over the 3-column period, in linear light.
        // A favored channel is bright on 1 of every 3 columns and dark on the
        // other 2, so its triad-mean is (hi + 2*lo)/3. Lottes' raw pair is
        // 1.5/0.5, whose mean is (1.5 + 2*0.5)/3 = 0.833 - i.e. the raw mask
        // dims EVERY channel by 1/6. We keep his 3:1 light:dark RATIO but
        // rescale by s = 3/(hi+2*lo) so the mean is exactly 1:
        //   (s*hi + 2*s*lo)/3 = s*(hi+2*lo)/3 = 1
        // giving the shipped pair 1.8/0.6. (An earlier +-a mask had the same
        // flaw in miniature: (1+a + 2(1-a))/3 = 1 - a/3.)
        let maskFade = clamp((k - MASK_FADE_LO) / (MASK_FADE_HI - MASK_FADE_LO), 0.0, 1.0);
        let mscale = 3.0 / (MASK_HI_RAW + 2.0 * MASK_LO_RAW); // forces triad-mean to 1
        let hi = MASK_HI_RAW * mscale;   // = 1.8
        let lo = MASK_LO_RAW * mscale;   // = 0.6
        let phase = i32(floor(pos.x)) % 3;
        var mask = vec3f(lo);
        if (phase == 0) { mask.r = hi; }
        else if (phase == 1) { mask.g = hi; }
        else { mask.b = hi; }
        // Fade toward 1.0 (no mask). A mix of two triad-mean-1 fields is still
        // triad-mean-1, so energy-neutrality holds at every scale.
        mask = mix(vec3f(1.0), mask, maskFade);
        col = col * mask;

        // Re-encode to gamma for display. No brightness fudge: beam and mask
        // are each energy-neutral, so the average survives on its own.
        return vec4f(toGamma(clamp(col, vec3f(0.0), vec3f(1.0))), 1.0);
      }` });
    const crtPipeline = device.createRenderPipeline({
      layout: "auto",
      vertex: { module: crtShader, entryPoint: "vs" },
      fragment: { module: crtShader, entryPoint: "fs", targets: [{ format }] },
    });
    // 16-byte uniform: srcSize (vec2f) then outSize (vec2f). Re-written every
    // present so it tracks live resizes and aspect toggles.
    crtUniform = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    const crtBind = device.createBindGroup({
      layout: crtPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: textureView },
        { binding: 1, resource: linear },
        { binding: 2, resource: { buffer: crtUniform } },
      ],
    });
    presentCRT = (frame) => {
      uploadFrame(frame);
      device.queue.writeBuffer(crtUniform, 0, new Float32Array([
        sourceWidth, sourceHeight, canvas.width, canvas.height,
      ]));
      drawQuad(crtPipeline, crtBind);
    };
  }

  function configure({ width, height, outputWidth = width, outputHeight = height, crt = crtOn }) {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0)
      throw new Error("presenter source dimensions must be positive integers");
    if (!Number.isInteger(outputWidth) || !Number.isInteger(outputHeight) || outputWidth <= 0 || outputHeight <= 0)
      throw new Error("presenter output dimensions must be positive integers");
    const geometryChanged = width !== sourceWidth || height !== sourceHeight;
    sourceWidth = width;
    sourceHeight = height;
    crtOn = !!crt;
    if (canvas.width !== outputWidth || canvas.height !== outputHeight) {
      canvas.width = outputWidth;
      canvas.height = outputHeight;
      ctx.configure({ device, format, alphaMode: "opaque" });
    }
    if (geometryChanged) buildSizedPresenters();
  }

  function present(frame) {
    if (!presentBase) throw new Error("presenter geometry is not configured");
    (crtOn ? presentCRT : presentBase)(frame);
    counters.presents++;
  }

  function destroy() {
    frameTexture?.destroy();
    crtUniform?.destroy();
    device.destroy?.();
    frameTexture = null;
    crtUniform = null;
    presentBase = null;
    presentCRT = null;
  }

  return {
    attachCanvas, configure, present, destroy,
    stats: () => ({ ...counters }),
    backend: "webgpu",
    lost,
  };
}
