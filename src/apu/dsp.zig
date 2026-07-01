// =============================================================================
// S-DSP - Sony Digital Signal Processor (audio synthesis)
// =============================================================================
// The S-DSP is the second half of the SNES audio system. While the SPC700
// CPU runs the game's sound driver, the DSP does the actual sound
// generation: it reads compressed (BRR) sample data from the shared 64KB
// audio RAM, decodes and pitch-shifts it across 8 voices, applies
// per-voice envelopes and volumes, mixes everything, and feeds an echo
// (delay + FIR filter) effect. Output is one stereo sample pair every 32
// SPC700 clocks: 1.024 MHz / 32 = 32000 Hz.
//
// The SPC700 talks to the DSP through two of its I/O ports:
//   $F2 (DSPADDR) selects one of 128 DSP registers
//   $F3 (DSPDATA) reads/writes the selected register
//
// DSP REGISTER MAP (x = voice number 0-7):
//   $x0 VOL(L)   - Left volume, signed 8-bit
//   $x1 VOL(R)   - Right volume, signed 8-bit
//   $x2 P(L)     - Pitch low 8 bits
//   $x3 P(H)     - Pitch high 6 bits (14-bit total; $1000 = 32kHz native)
//   $x4 SRCN     - Sample source number (index into the DIR directory)
//   $x5 ADSR(1)  - Bit 7: use ADSR; bits 6-4: decay rate; 3-0: attack rate
//   $x6 ADSR(2)  - Bits 7-5: sustain level; 4-0: sustain (decay 2) rate
//   $x7 GAIN     - Alternative envelope control (used when ADSR1 bit 7 = 0)
//   $x8 ENVX     - Current envelope value (read-only, top 7 bits of 11)
//   $x9 OUTX     - Current voice output (read-only, signed)
//
//   $0C MVOL(L)  - Main volume left       $1C MVOL(R) - right
//   $2C EVOL(L)  - Echo volume left       $3C EVOL(R) - right
//   $4C KON      - Key on  (bit per voice: start playing)
//   $5C KOF      - Key off (bit per voice: enter release)
//   $6C FLG      - Bit 7: soft reset; 6: mute; 5: echo write disable;
//                  bits 4-0: noise generator frequency
//   $7C ENDX     - Bit per voice: BRR end block reached (read clears... on
//                  write; reads return current state)
//   $0D EFB      - Echo feedback, signed
//   $2D PMON     - Pitch modulation enable (bits 7-1: voice x modulated
//                  by voice x-1's output)
//   $3D NON      - Noise enable (bit per voice: replace sample with noise)
//   $4D EON      - Echo enable (bit per voice: voice feeds the echo bus)
//   $5D DIR      - Sample directory page (address = DIR * $100)
//   $6D ESA      - Echo buffer start page (address = ESA * $100)
//   $7D EDL      - Echo delay, bits 3-0 (buffer = EDL * 2KB, 0 = 4 bytes)
//   $xF FIR(x)   - 8-tap echo FIR filter coefficients, signed
//
// BRR SAMPLE FORMAT:
// -----------------------------------------------------------------------------
// Samples are stored as 9-byte blocks: 1 header + 8 data bytes holding 16
// 4-bit nibbles (one block = 16 PCM samples). Header:
//   Bits 7-4: range (left shift applied to each nibble, 0-12 valid)
//   Bits 3-2: filter (IIR prediction filter using the 2 previous samples)
//   Bit 1:    loop flag (with end: jump to loop point instead of stopping)
//   Bit 0:    end flag (last block of the sample)
// The DIR directory holds 4 bytes per sample number: start address and
// loop address of the BRR stream.
//
// References:
//   - https://snes.nesdev.org/wiki/S-DSP
//   - fullsnes "SNES APU DSP" chapter
//   - docs/spc700-hardware.md (register overview)
// =============================================================================

const std = @import("std");

/// Envelope/noise rate table. Index 0-31 selects how many 32kHz ticks pass
/// between envelope steps (0 = never). These exact periods come from the
/// hardware's global rate generator.
const RATE_TABLE = [32]u16{
    0,    2048, 1536, 1280, 1024, 768, 640, 512,
    384,  320,  256,  192,  160,  128, 96,  80,
    64,   48,   40,   32,   24,   20,  16,  12,
    10,   8,    6,    5,    4,    3,   2,   1,
};

/// Gaussian interpolation table (first half; the hardware table is
/// symmetric). These 512 values are the actual coefficients from the DSP
/// ROM - using them (instead of linear interpolation) reproduces the
/// characteristic "soft" SNES sound and is required for sample-accurate
/// output.
const GAUSS = [512]i16{
    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,
    1,    1,    1,    1,    1,    1,    1,    1,    1,    1,    1,    2,    2,    2,    2,    2,
    2,    2,    3,    3,    3,    3,    3,    4,    4,    4,    4,    4,    5,    5,    5,    5,
    6,    6,    6,    6,    7,    7,    7,    8,    8,    8,    9,    9,    9,    10,   10,   10,
    11,   11,   11,   12,   12,   13,   13,   14,   14,   15,   15,   15,   16,   16,   17,   17,
    18,   19,   19,   20,   20,   21,   21,   22,   23,   23,   24,   24,   25,   26,   27,   27,
    28,   29,   29,   30,   31,   32,   32,   33,   34,   35,   36,   36,   37,   38,   39,   40,
    41,   42,   43,   44,   45,   46,   47,   48,   49,   50,   51,   52,   53,   54,   55,   56,
    58,   59,   60,   61,   62,   64,   65,   66,   67,   69,   70,   71,   73,   74,   76,   77,
    78,   80,   81,   83,   84,   86,   87,   89,   90,   92,   94,   95,   97,   99,   100,  102,
    104,  106,  107,  109,  111,  113,  115,  117,  118,  120,  122,  124,  126,  128,  130,  132,
    134,  137,  139,  141,  143,  145,  147,  150,  152,  154,  156,  159,  161,  163,  166,  168,
    171,  173,  175,  178,  180,  183,  186,  188,  191,  193,  196,  199,  201,  204,  207,  210,
    212,  215,  218,  221,  224,  227,  230,  233,  236,  239,  242,  245,  248,  251,  254,  257,
    260,  263,  267,  270,  273,  276,  280,  283,  286,  290,  293,  297,  300,  304,  307,  311,
    314,  318,  321,  325,  328,  332,  336,  339,  343,  347,  351,  354,  358,  362,  366,  370,
    374,  378,  381,  385,  389,  393,  397,  401,  405,  410,  414,  418,  422,  426,  430,  434,
    439,  443,  447,  451,  456,  460,  464,  469,  473,  477,  482,  486,  491,  495,  499,  504,
    508,  513,  517,  522,  527,  531,  536,  540,  545,  550,  554,  559,  563,  568,  573,  577,
    582,  587,  592,  596,  601,  606,  611,  615,  620,  625,  630,  635,  640,  644,  649,  654,
    659,  664,  669,  674,  678,  683,  688,  693,  698,  703,  708,  713,  718,  723,  728,  732,
    737,  742,  747,  752,  757,  762,  767,  772,  777,  782,  787,  792,  797,  802,  806,  811,
    816,  821,  826,  831,  836,  841,  846,  851,  855,  860,  865,  870,  875,  880,  884,  889,
    894,  899,  904,  908,  913,  918,  923,  927,  932,  937,  941,  946,  951,  955,  960,  965,
    969,  974,  978,  983,  988,  992,  997,  1001, 1005, 1010, 1014, 1019, 1023, 1027, 1032, 1036,
    1040, 1045, 1049, 1053, 1057, 1061, 1066, 1070, 1074, 1078, 1082, 1086, 1090, 1094, 1098, 1102,
    1106, 1109, 1113, 1117, 1121, 1125, 1128, 1132, 1136, 1139, 1143, 1146, 1150, 1153, 1157, 1160,
    1164, 1167, 1170, 1174, 1177, 1180, 1183, 1186, 1190, 1193, 1196, 1199, 1202, 1205, 1207, 1210,
    1213, 1216, 1219, 1221, 1224, 1227, 1229, 1232, 1234, 1237, 1239, 1241, 1244, 1246, 1248, 1251,
    1253, 1255, 1257, 1259, 1261, 1263, 1265, 1267, 1269, 1270, 1272, 1274, 1275, 1277, 1279, 1280,
    1282, 1283, 1284, 1286, 1287, 1288, 1290, 1291, 1292, 1293, 1294, 1295, 1296, 1297, 1297, 1298,
    1299, 1300, 1300, 1301, 1302, 1302, 1303, 1303, 1303, 1304, 1304, 1304, 1304, 1304, 1305, 1305,
};

/// Per-voice playback state (the DSP-internal part; the register values
/// themselves live in the flat regs[] array so register reads work).
const Voice = struct {
    // BRR decoding
    brr_addr: u16 = 0, // Current BRR block address
    brr_offset: u8 = 1, // Byte offset within the block (1-8; 0 is header)
    decode_buf: [12]i16 = [_]i16{0} ** 12, // Ring of decoded samples for interpolation
    buf_pos: u8 = 0, // Write position in decode_buf (wraps at 12)
    last1: i16 = 0, // Previous decoded sample (BRR filter state)
    last2: i16 = 0, // Sample before that

    // Pitch
    counter: u16 = 0, // 16-bit pitch counter; top 4 bits index decode_buf,
    // next 8 bits are the gaussian interpolation fraction

    // Envelope
    env: i16 = 0, // Current envelope 0-2047 (11-bit)
    env_mode: EnvMode = .release,
    env_timer: u16 = 0, // Ticks until next envelope step

    // Output of this voice's last sample (pre-volume), used for pitch mod
    out_sample: i16 = 0,

    // Key-on happens with a short delay on hardware; we start immediately
    // but track a "just keyed" state to reset BRR decoding cleanly.
    keyed_on: bool = false,
};

const EnvMode = enum { attack, decay, sustain, release, gain };

pub const Dsp = struct {
    regs: [128]u8,

    voices: [8]Voice,

    // Noise generator: 15-bit LFSR clocked at the rate in FLG bits 0-4
    noise_lfsr: u15,
    noise_timer: u16,

    // Echo state
    echo_pos: u16, // Current offset within the echo buffer
    echo_length: u16, // Buffer size in bytes (EDL * 2048, min 4)
    fir_history: [2][8]i16, // FIR filter delay lines (L/R)
    fir_pos: u8,

    // ENDX register state (bit per voice, set when the end block is decoded)
    endx: u8,

    // ---------------------------------------------------------------------
    // Output: a small ring buffer of stereo frames the frontend drains.
    // At 32kHz and 60fps that's ~533 frames per video frame; 8192 gives
    // plenty of slack before overwrite.
    // ---------------------------------------------------------------------
    out_buf: [8192][2]i16,
    out_write: usize,
    out_read: usize,

    pub fn init() Dsp {
        var dsp = Dsp{
            .regs = [_]u8{0} ** 128,
            .voices = [_]Voice{.{}} ** 8,
            .noise_lfsr = 0x4000,
            .noise_timer = 0,
            .echo_pos = 0,
            .echo_length = 4,
            .fir_history = [_][8]i16{[_]i16{0} ** 8} ** 2,
            .fir_pos = 0,
            .endx = 0,
            .out_buf = undefined,
            .out_write = 0,
            .out_read = 0,
        };
        dsp.regs[0x6C] = 0xE0; // FLG: reset + mute + echo disable at power-on
        return dsp;
    }

    pub fn read(self: *Dsp, addr: u8) u8 {
        const a = addr & 0x7F;
        return switch (a) {
            0x7C => self.endx, // ENDX reads live state
            else => self.regs[a],
        };
    }

    pub fn write(self: *Dsp, addr: u8, value: u8) void {
        if (addr >= 0x80) return; // $80-$FF are read-only mirrors of $00-$7F
        const a = addr & 0x7F;

        switch (a) {
            0x4C => { // KON - key on
                // Store it; voices start at the next sample tick
                self.regs[a] = value;
            },
            0x7C => {
                // Any write to ENDX clears all bits (hardware quirk)
                self.endx = 0;
                self.regs[a] = 0;
                return;
            },
            else => self.regs[a] = value,
        }
        self.regs[a] = value;
    }

    // =========================================================================
    // SAMPLE GENERATION - called once per 32 SPC700 cycles (32kHz)
    // =========================================================================
    pub fn tick(self: *Dsp, ram: *[65536]u8) void {
        const flg = self.regs[0x6C];

        // Soft reset: silence everything and force release
        if ((flg & 0x80) != 0) {
            for (&self.voices) |*v| {
                v.env = 0;
                v.env_mode = .release;
            }
        }

        // ---------------- Key on / key off ----------------
        const kon = self.regs[0x4C];
        const kof = self.regs[0x5C];
        for (0..8) |i| {
            const bit = @as(u8, 1) << @intCast(i);
            const v = &self.voices[i];
            if ((kon & bit) != 0 and !v.keyed_on) {
                self.keyOn(@intCast(i), ram);
            }
            if ((kof & bit) != 0 and v.env_mode != .release) {
                v.env_mode = .release;
            }
            if ((kon & bit) == 0) {
                v.keyed_on = false;
            }
        }

        // ---------------- Noise generator ----------------
        const noise_rate = RATE_TABLE[flg & 0x1F];
        if (noise_rate != 0) {
            self.noise_timer += 1;
            if (self.noise_timer >= noise_rate) {
                self.noise_timer = 0;
                const n: u15 = self.noise_lfsr;
                const fb: u15 = (n ^ (n >> 1)) & 1;
                self.noise_lfsr = (n >> 1) | (fb << 14);
            }
        }
        // Noise sample: sign-extend the 15-bit LFSR to 16 bits
        const noise_sample: i16 = @bitCast(@as(u16, self.noise_lfsr) << 1);

        // ---------------- Voices ----------------
        var main_l: i32 = 0;
        var main_r: i32 = 0;
        var echo_l: i32 = 0;
        var echo_r: i32 = 0;
        var prev_out: i16 = 0; // Previous voice's output for pitch modulation

        for (0..8) |i| {
            const v = &self.voices[i];
            const base: u8 = @intCast(i << 4);

            // ---- Pitch step (with optional modulation by previous voice) ----
            var pitch: i32 = (@as(i32, self.regs[base + 2])) |
                (@as(i32, self.regs[base + 3] & 0x3F) << 8);
            if (i > 0 and (self.regs[0x2D] & (@as(u8, 1) << @intCast(i))) != 0) {
                // PMON: scale pitch by previous voice output (-1..+1 range)
                pitch += (pitch * @as(i32, prev_out)) >> 15;
                pitch = std.math.clamp(pitch, 0, 0x3FFF);
            }

            // ---- Interpolate output sample ----
            // counter top 4 bits: position in the 12-entry decode ring
            // (relative to buf_pos), next 8 bits: gaussian fraction.
            var sample: i16 = undefined;
            if ((self.regs[0x3D] & (@as(u8, 1) << @intCast(i))) != 0) {
                // NON: noise replaces the sample (envelope still applies)
                sample = noise_sample;
            } else {
                sample = self.interpolate(v);
            }

            // ---- Envelope ----
            self.stepEnvelope(@intCast(i));
            const env = v.env;

            // Apply envelope (11-bit) to sample
            var out: i32 = (@as(i32, sample) * @as(i32, env)) >> 11;
            out = std.math.clamp(out, -32768, 32767);
            v.out_sample = @intCast(out);
            prev_out = v.out_sample;

            // Expose ENVX/OUTX for the driver to read
            self.regs[base + 8] = @intCast((env >> 4) & 0x7F);
            self.regs[base + 9] = @bitCast(@as(i8, @intCast(out >> 8)));

            // ---- Mix with per-voice volumes ----
            const vol_l: i8 = @bitCast(self.regs[base + 0]);
            const vol_r: i8 = @bitCast(self.regs[base + 1]);
            const contrib_l = (out * @as(i32, vol_l)) >> 7;
            const contrib_r = (out * @as(i32, vol_r)) >> 7;
            main_l += contrib_l;
            main_r += contrib_r;
            if ((self.regs[0x4D] & (@as(u8, 1) << @intCast(i))) != 0) {
                echo_l += contrib_l;
                echo_r += contrib_r;
            }

            // ---- Advance pitch counter / decode more BRR as needed ----
            const new_counter = @as(u32, v.counter) + @as(u32, @intCast(pitch));
            // Each 0x1000 of counter = one source sample consumed
            var steps = new_counter >> 12;
            v.counter = @intCast(new_counter & 0xFFF);
            while (steps > 0) : (steps -= 1) {
                self.decodeNextSample(@intCast(i), ram);
            }
        }

        // ---------------- Echo ----------------
        var out_l = (main_l * @as(i32, @as(i8, @bitCast(self.regs[0x0C])))) >> 7;
        var out_r = (main_r * @as(i32, @as(i8, @bitCast(self.regs[0x1C])))) >> 7;

        {
            // Read the current echo buffer sample (16-bit LE, L then R)
            const esa = @as(u16, self.regs[0x6D]) << 8;
            const addr = esa +% self.echo_pos;
            const raw_l: i16 = @bitCast(@as(u16, ram[addr]) | (@as(u16, ram[addr +% 1]) << 8));
            const raw_r: i16 = @bitCast(@as(u16, ram[addr +% 2]) | (@as(u16, ram[addr +% 3]) << 8));

            // 8-tap FIR filter over the echo history
            self.fir_history[0][self.fir_pos] = raw_l >> 1;
            self.fir_history[1][self.fir_pos] = raw_r >> 1;
            var fir_l: i32 = 0;
            var fir_r: i32 = 0;
            for (0..8) |t| {
                const coeff: i32 = @as(i8, @bitCast(self.regs[@as(u8, @intCast(t)) * 0x10 + 0x0F]));
                const idx = (self.fir_pos + 1 + t) & 7;
                fir_l += (@as(i32, self.fir_history[0][idx]) * coeff) >> 6;
                fir_r += (@as(i32, self.fir_history[1][idx]) * coeff) >> 6;
            }
            self.fir_pos = @intCast((self.fir_pos + 1) & 7);

            // Echo contribution to the output mix
            const evol_l: i32 = @as(i8, @bitCast(self.regs[0x2C]));
            const evol_r: i32 = @as(i8, @bitCast(self.regs[0x3C]));
            out_l += (fir_l * evol_l) >> 7;
            out_r += (fir_r * evol_r) >> 7;

            // Write back into the echo buffer: voice echo bus + feedback
            if ((flg & 0x20) == 0) { // FLG bit 5: echo write disable
                const efb: i32 = @as(i8, @bitCast(self.regs[0x0D]));
                const wr_l = std.math.clamp(echo_l + ((fir_l * efb) >> 7), -32768, 32767);
                const wr_r = std.math.clamp(echo_r + ((fir_r * efb) >> 7), -32768, 32767);
                const ul: u16 = @bitCast(@as(i16, @intCast(wr_l)));
                const ur: u16 = @bitCast(@as(i16, @intCast(wr_r)));
                ram[addr] = @truncate(ul);
                ram[addr +% 1] = @truncate(ul >> 8);
                ram[addr +% 2] = @truncate(ur);
                ram[addr +% 3] = @truncate(ur >> 8);
            }

            // Advance the echo position; reload length from EDL at wrap
            self.echo_pos += 4;
            if (self.echo_pos >= self.echo_length) {
                self.echo_pos = 0;
                const edl = self.regs[0x7D] & 0x0F;
                self.echo_length = if (edl == 0) 4 else @as(u16, edl) * 2048;
            }
        }

        // ---------------- Final output ----------------
        if ((flg & 0x40) != 0) { // FLG bit 6: mute
            out_l = 0;
            out_r = 0;
        }

        const frame_l: i16 = @intCast(std.math.clamp(out_l, -32768, 32767));
        const frame_r: i16 = @intCast(std.math.clamp(out_r, -32768, 32767));
        self.out_buf[self.out_write & (self.out_buf.len - 1)] = .{ frame_l, frame_r };
        self.out_write +%= 1;
    }

    /// Drain up to dst.len stereo frames from the output ring buffer.
    /// Returns the number of frames written.
    pub fn readSamples(self: *Dsp, dst: [][2]i16) usize {
        var n: usize = 0;
        while (n < dst.len and self.out_read != self.out_write) {
            dst[n] = self.out_buf[self.out_read & (self.out_buf.len - 1)];
            self.out_read +%= 1;
            n += 1;
        }
        return n;
    }

    // =========================================================================
    // KEY ON - start a voice from its sample directory entry
    // =========================================================================
    fn keyOn(self: *Dsp, voice: u3, ram: *[65536]u8) void {
        const v = &self.voices[voice];
        const base: u8 = @as(u8, voice) << 4;

        // Directory entry: DIR*$100 + SRCN*4 -> [start lo, start hi, loop lo, loop hi]
        const dir = @as(u16, self.regs[0x5D]) << 8;
        const srcn = self.regs[base + 4];
        const entry = dir +% @as(u16, srcn) * 4;
        v.brr_addr = @as(u16, ram[entry]) | (@as(u16, ram[entry +% 1]) << 8);
        v.brr_offset = 1;
        v.buf_pos = 0;
        v.decode_buf = [_]i16{0} ** 12;
        v.last1 = 0;
        v.last2 = 0;
        v.counter = 0;
        v.env = 0;
        v.env_timer = 0;
        v.keyed_on = true;
        v.env_mode = if ((self.regs[base + 5] & 0x80) != 0) .attack else .gain;
        self.endx &= ~(@as(u8, 1) << voice);

        // Prime the interpolation buffer with the first samples
        for (0..3) |_| {
            self.decodeNextSample(voice, ram);
        }
    }

    // =========================================================================
    // BRR DECODING - one sample at a time
    // =========================================================================
    fn decodeNextSample(self: *Dsp, voice: u3, ram: *[65536]u8) void {
        const v = &self.voices[voice];
        const header = ram[v.brr_addr];
        const range: u4 = @intCast(header >> 4);
        const filter: u2 = @intCast((header >> 2) & 3);

        // Fetch the next nibble. Data bytes follow the header (offsets 1-8
        // within the 9-byte block), two samples per byte, high nibble
        // first: sample offset 1 -> byte 1 high, 2 -> byte 1 low, ...
        const byte = ram[v.brr_addr +% ((v.brr_offset + 1) >> 1)];
        const nibble_raw: u4 = if ((v.brr_offset & 1) != 0)
            @intCast(byte >> 4)
        else
            @intCast(byte & 0x0F);
        // Sign-extend 4-bit nibble
        var s: i32 = @as(i4, @bitCast(nibble_raw));

        // Apply range shift. Ranges 13-15 are invalid: hardware yields
        // 0 or -4096 depending on sign.
        if (range <= 12) {
            s = (s << range) >> 1;
        } else {
            s = if (s < 0) -2048 else 0;
        }

        // Apply the IIR prediction filter (fullsnes coefficients)
        const l1: i32 = v.last1;
        const l2: i32 = v.last2;
        switch (filter) {
            0 => {},
            1 => s += l1 - (l1 >> 4), // + 15/16 * last1
            2 => s += (l1 * 2) - ((l1 * 3) >> 5) - l2 + (l2 >> 4), // +61/32*l1 -15/16*l2
            3 => s += (l1 * 2) - ((l1 * 13) >> 6) - l2 + ((l2 * 3) >> 4), // +115/64*l1 -13/16*l2
        }

        // Clamp to 16-bit, then the DSP wraps to 15-bit precision
        s = std.math.clamp(s, -32768, 32767);
        const result: i16 = @intCast(s);

        v.last2 = v.last1;
        v.last1 = result;
        v.decode_buf[v.buf_pos] = result;
        v.buf_pos = (v.buf_pos + 1) % 12;

        // Advance within the block; 16 nibbles = offsets 1..16 over 8 bytes
        v.brr_offset += 1;
        if (v.brr_offset > 16) {
            v.brr_offset = 1;
            // Block finished - handle end/loop flags
            if ((header & 0x01) != 0) {
                self.endx |= @as(u8, 1) << voice;
                if ((header & 0x02) != 0) {
                    // Loop: jump to the loop address from the directory
                    const dir = @as(u16, self.regs[0x5D]) << 8;
                    const base: u8 = @as(u8, voice) << 4;
                    const srcn = self.regs[base + 4];
                    const entry = dir +% @as(u16, srcn) * 4;
                    v.brr_addr = @as(u16, ram[entry +% 2]) | (@as(u16, ram[entry +% 3]) << 8);
                } else {
                    // End without loop: voice goes silent (release to 0)
                    v.env = 0;
                    v.env_mode = .release;
                    v.brr_addr +%= 9; // Keep advancing (hardware reads on)
                }
            } else {
                v.brr_addr +%= 9;
            }
        }
    }

    // =========================================================================
    // GAUSSIAN INTERPOLATION
    // =========================================================================
    // The DSP looks at 4 consecutive decoded samples around the playback
    // position and weights them with the gaussian table indexed by the
    // 8-bit fraction of the pitch counter. The table is symmetric, so the
    // second half is read backwards.
    // =========================================================================
    fn interpolate(self: *Dsp, v: *Voice) i16 {
        _ = self;
        const frac: u16 = (v.counter >> 4) & 0xFF;
        // The 4 most recently decoded samples, oldest first. buf_pos points
        // at the next write slot, so the newest sample is at buf_pos-1.
        const newest = (@as(usize, v.buf_pos) + 12 - 1) % 12;
        const s0 = v.decode_buf[(newest + 12 - 3) % 12];
        const s1 = v.decode_buf[(newest + 12 - 2) % 12];
        const s2 = v.decode_buf[(newest + 12 - 1) % 12];
        const s3 = v.decode_buf[newest];

        var out: i32 = 0;
        out += (@as(i32, GAUSS[255 - frac]) * s0) >> 11;
        out += (@as(i32, GAUSS[511 - frac]) * s1) >> 11;
        out += (@as(i32, GAUSS[256 + frac]) * s2) >> 11;
        out += (@as(i32, GAUSS[frac]) * s3) >> 11;
        out = std.math.clamp(out, -32768, 32767);
        return @intCast(out);
    }

    // =========================================================================
    // ENVELOPE - ADSR and GAIN modes
    // =========================================================================
    // The envelope is an 11-bit value (0-2047). ADSR mode:
    //   Attack:  linear rise, rate = AR*2+1 (+32/step, +1024 at rate 31)
    //   Decay:   exponential fall to the sustain level, rate = DR*2+16
    //   Sustain: exponential fall to 0, rate = SR
    //   Release: linear fall, -8 per 32kHz tick (rate 31)
    // GAIN mode (ADSR1 bit 7 clear) either sets the level directly or
    // ramps it linearly/exponentially per the GAIN register mode bits.
    // =========================================================================
    fn stepEnvelope(self: *Dsp, voice: u3) void {
        const v = &self.voices[voice];
        const base: u8 = @as(u8, voice) << 4;
        const adsr1 = self.regs[base + 5];
        const adsr2 = self.regs[base + 6];
        const gain = self.regs[base + 7];

        if (v.env_mode == .release) {
            // Release always ticks at full speed: -8 per sample
            v.env -= 8;
            if (v.env < 0) v.env = 0;
            return;
        }

        if ((adsr1 & 0x80) != 0) {
            // ---- ADSR mode ----
            switch (v.env_mode) {
                .attack => {
                    const rate: u5 = @intCast((@as(u8, adsr1 & 0x0F) << 1) + 1);
                    if (!self.envTick(v, rate)) return;
                    v.env += if (rate == 31) 1024 else 32;
                    if (v.env >= 0x7E0) {
                        if (v.env > 2047) v.env = 2047;
                        v.env_mode = .decay;
                    }
                },
                .decay => {
                    const rate: u5 = @intCast((((adsr1 >> 4) & 0x07) << 1) + 16);
                    const sustain_level = (@as(i16, (adsr2 >> 5)) + 1) << 8;
                    if (!self.envTick(v, rate)) return;
                    v.env -= ((v.env - 1) >> 8) + 1;
                    if (v.env < 0) v.env = 0;
                    if (v.env <= sustain_level) v.env_mode = .sustain;
                },
                .sustain => {
                    const rate: u5 = @intCast(adsr2 & 0x1F);
                    if (!self.envTick(v, rate)) return;
                    v.env -= ((v.env - 1) >> 8) + 1;
                    if (v.env < 0) v.env = 0;
                },
                else => {},
            }
        } else {
            // ---- GAIN mode ----
            if ((gain & 0x80) == 0) {
                // Direct: envelope = value * 16
                v.env = @as(i16, gain & 0x7F) << 4;
            } else {
                const rate: u5 = @intCast(gain & 0x1F);
                if (!self.envTick(v, rate)) return;
                switch (@as(u2, @truncate(gain >> 5))) {
                    0 => { // Linear decrease
                        v.env -= 32;
                        if (v.env < 0) v.env = 0;
                    },
                    1 => { // Exponential decrease
                        v.env -= ((v.env - 1) >> 8) + 1;
                        if (v.env < 0) v.env = 0;
                    },
                    2 => { // Linear increase
                        v.env += 32;
                        if (v.env > 2047) v.env = 2047;
                    },
                    3 => { // Bent-line increase: +32 until $600, then +8
                        v.env += if (v.env < 0x600) 32 else 8;
                        if (v.env > 2047) v.env = 2047;
                    },
                }
            }
        }
    }

    /// Envelope rate timer: returns true when the envelope should step.
    fn envTick(self: *Dsp, v: *Voice, rate: u5) bool {
        _ = self;
        const period = RATE_TABLE[rate];
        if (period == 0) return false; // Rate 0 = never
        v.env_timer += 1;
        if (v.env_timer >= period) {
            v.env_timer = 0;
            return true;
        }
        return false;
    }
};

test "dsp init" {
    var dsp = Dsp.init();
    try std.testing.expectEqual(@as(u8, 0xE0), dsp.read(0x6C));
}

test "brr decode filter 0" {
    var dsp = Dsp.init();
    var ram = [_]u8{0} ** 65536;
    // Directory at page 2, sample 0 -> start $0300
    dsp.regs[0x5D] = 0x02;
    ram[0x200] = 0x00;
    ram[0x201] = 0x03;
    // BRR block at $0300: range 12, filter 0, end+loop clear
    ram[0x300] = 0xC0;
    ram[0x301] = 0x70; // First nibble 7 -> 7 << 12 >> 1 = 14336
    dsp.keyOn(0, &ram);
    // keyOn primes 3 samples; first decoded is nibble 7
    try std.testing.expectEqual(@as(i16, 14336), dsp.voices[0].decode_buf[0]);
}
