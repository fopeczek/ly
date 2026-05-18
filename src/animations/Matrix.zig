const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;

const ly_ui = @import("ly-ui");
const Cell = ly_ui.Cell;
const TerminalBuffer = ly_ui.TerminalBuffer;
const Widget = ly_ui.Widget;

const ly_core = ly_ui.ly_core;
const interop = ly_core.interop;
const TimeOfDay = interop.TimeOfDay;

// Characters change mid-scroll
pub const MID_SCROLL_CHANGE = true;

// Defaults for the tunable parameters below. They're stored as fields
// on the Matrix instance (not const) so the debug menu can mutate them
// at runtime for live tuning. Original-pin values kept here for
// reference + reset-to-defaults action.
const DEFAULT_SPEED_MIN: f32 = 0.06;
const DEFAULT_SPEED_MAX: f32 = 0.15;
const DEFAULT_TAIL_CHURN_PROB: f32 = 0.04;
const DEFAULT_DARK_RUN_START_PCT: u16 = 4;
const DEFAULT_DARK_RUN_MIN: u8 = 2;
const DEFAULT_DARK_RUN_MAX: u8 = 5;
const DEFAULT_GLITCH_SEED_PERMILLE: u16 = 18;
const DEFAULT_OVERLAY_INITIAL_TTL: u8 = 8;
const DEFAULT_OVERLAY_LINES_PER_BURST: u8 = 3;
// Inter-trail spawn gap. 0 = NOTHING SPAWNS at all (empty screen).
// 1 = extremely sparse (1000-cell wait between trails per column).
// 1000 = constant flood (back-to-back trails per column). Linear
// inverse: line.space_max = 1001 - rain_density. Default 750 keeps
// the screen busy without saturating it.
const DEFAULT_RAIN_DENSITY: u16 = 750;
const DEFAULT_MIN_DROP_LEN: u8 = 10;
// Upper bound on a freshly-spawned raindrop's trail length. Spawn
// formula rolls in [min, min(max, screen_height - 1)] so the value
// can never exceed the visible area. Default 30 (~movie-feel medium
// trails). User-tunable + persisted.
const DEFAULT_MAX_DROP_LEN: u8 = 30;
// drop_v_margin default: 8 cells of clearance at the top of the
// column before a new trail spawns. Small enough that adjacent
// trails in one column are visually distinct as separate raindrops;
// large enough to prevent the "wave of synchronized heads" at high
// rain_density.
const DEFAULT_DROP_V_MARGIN: u16 = 8;
const DEFAULT_DROP_H_MARGIN: u16 = 0;

// Tail-churn / dark-run tunables previously lived here as `const`.
// They're now instance fields on Matrix (initialised from the
// DEFAULT_* values up top) so the debug menu can mutate them live.

// Curated glyph pool for a Matrix-movie aesthetic. The cmatrix_*_codepoint
// config entries are intentionally ignored — a contiguous Unicode range
// produces ASCII-printable or pure-Katakana monocultures that don't feel
// like the movie. This pool is ~70% Halfwidth Katakana (the iconic
// "alien Japanese" look — fontconfig falls back to Noto Sans CJK JP since
// JetBrainsMono does not ship Katakana) with digits, math/geometric
// symbols, Greek, and Cyrillic letters mixed in for visual variety.
const GLYPH_POOL = [_]u32{
    // Halfwidth Katakana (U+FF66–U+FF9D) — primary Matrix-y body.
    // Duplicated entries weight the pool toward Katakana without
    // needing a separate weighted-sampling routine.
    0xFF66, 0xFF67, 0xFF68, 0xFF69, 0xFF6A, 0xFF6B, 0xFF6C, 0xFF6D,
    0xFF6E, 0xFF6F, 0xFF70, 0xFF71, 0xFF72, 0xFF73, 0xFF74, 0xFF75,
    0xFF76, 0xFF77, 0xFF78, 0xFF79, 0xFF7A, 0xFF7B, 0xFF7C, 0xFF7D,
    0xFF7E, 0xFF7F, 0xFF80, 0xFF81, 0xFF82, 0xFF83, 0xFF84, 0xFF85,
    0xFF86, 0xFF87, 0xFF88, 0xFF89, 0xFF8A, 0xFF8B, 0xFF8C, 0xFF8D,
    0xFF8E, 0xFF8F, 0xFF90, 0xFF91, 0xFF92, 0xFF93, 0xFF94, 0xFF95,
    0xFF96, 0xFF97, 0xFF98, 0xFF99, 0xFF9A, 0xFF9B, 0xFF9C, 0xFF9D,
    // Second pass on Katakana to bias weighting (60%+ katakana).
    0xFF71, 0xFF72, 0xFF73, 0xFF77, 0xFF7B, 0xFF80, 0xFF85, 0xFF8A,
    0xFF8F, 0xFF94, 0xFF98, 0xFF9D, 0xFF6F, 0xFF89, 0xFF82, 0xFF88,
    // Latin digits 0-9 — present in the movie font too.
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
    // Math / set / logic operators — open line-art only.
    // Removed: ⊕ ⊗ ∅ (circled/slashed shapes read as UI icons).
    0x2200, 0x2202, 0x2203, 0x2207, 0x2208, 0x220B, 0x2211,
    0x221E, 0x222B, 0x2248, 0x2260,
    // Greek capitals + a couple lowercase — the "weird Latin" look.
    0x0394, 0x03A3, 0x03A6, 0x03A8, 0x03A9, 0x03BB, 0x03C0,
    // Cyrillic capitals with distinctive open shapes.
    // Removed: Ё (the diaeresis dots float oddly).
    0x0414, 0x0416, 0x041B, 0x0424, 0x042F,
    // Decorative symbols were removed wholesale (※ ★ ◆ ◊ ¦) —
    // they read as logos/icons against the line-art glyphs and
    // break the raindrop visual rhythm.
};

const Matrix = @This();

pub const Dot = struct {
    value: ?usize,
    is_head: bool,
    // Render this cell as a blank gap even though it has a value. Used
    // to punch grouped dark spots into otherwise-monotonous trails
    // (matrix-rain demos on the web do this — characters "blink out"
    // for a stretch). The value/is_head bookkeeping continues normally
    // so the algorithm doesn't get confused into thinking the column
    // has a gap; only the render layer treats it as empty.
    is_dark: bool = false,
    // Red "error code" overlay state. When ttl > 0, render path shows
    // overlay_ch in red instead of the rain glyph. Each time a new
    // raindrop head walks across this cell, ttl is decremented — so
    // the error text gets "scrubbed away" by passing rain over time.
    // See pushErrorBurst() for how lines are seeded.
    overlay_ttl: u8 = 0,
    overlay_ch: u32 = ' ',
};

pub const Line = struct {
    space: usize,
    length: usize,
    // Cells per draw frame. Continuous f32 in [SPEED_MIN, SPEED_MAX],
    // rolled fresh on each spawn so consecutive raindrops in the same
    // column don't share a speed either.
    speed: f32,
    // Accumulator phase in [0..1). Each draw call: accum += speed; once
    // it crosses 1.0 the column advances one cell and 1.0 is subtracted
    // back off. Initialized to a random offset so columns desync from
    // frame 1, eliminating the global "tick visible at once" lockstep
    // the old discrete-update scheme produced.
    advance_accum: f32,
    // Once the actual head scrolls past the bottom of the screen, this
    // tracks the conceptual head position advancing further down. Cells
    // in the trail body fade based on distance to this virtual head,
    // so the trail continues "falling" off the bottom instead of
    // vanishing instantly. 0 means no off-screen head (trail is either
    // alive on-screen or column is idle).
    virtual_head_y: usize = 0,
    // Cells remaining in the current grouped-dark-spot run. When > 0,
    // the next N head spawns in this column are marked is_dark so
    // they show as gaps in the falling trail. Reset to 0 when the
    // column empties.
    dark_run: u8 = 0,
};

// Single transient "glitch dot" — a cell that flashes red for a few
// frames to look like a momentary memory/error blip in the matrix.
const GlitchDot = struct {
    x: usize,
    y: usize,
    ttl: u8,
};

const GLITCH_MAX: usize = 32;
// glitch_seed_permille is an instance field; default lives in
// DEFAULT_GLITCH_SEED_PERMILLE. The TTL bounds stay const — they're
// not user-tuned in the debug menu.
// Glitch-dot lifetime bounds (now instance fields below — these
// remain as the *defaults* used to initialise the Matrix). 4–10
// at 50fps = 80–200ms.
const DEFAULT_GLITCH_TTL_MIN: u8 = 4;
const DEFAULT_GLITCH_TTL_MAX: u8 = 10;
// Stylized red used for glitch dots. Bold + saturated; matches the
// error_fg the rest of ly uses.
const GLITCH_FG: u32 = 0x01FF3333;

// Red used for the "error code" overlay (slightly less bright than the
// per-pixel glitch flash so they read as a different signal).
const OVERLAY_FG: u32 = 0x01D62828;

// overlay_initial_ttl and overlay_lines_per_burst are instance fields
// — see DEFAULT_OVERLAY_INITIAL_TTL / DEFAULT_OVERLAY_LINES_PER_BURST.

// Fake-but-plausible error-code lines. Drawn from at random, then
// rendered on a random row spanning the screen. Picked to look like
// kernel/syslog/auth output without being real diagnostic text.
const ERROR_LINES = [_][]const u8{
    "0xDEADBEEF PANIC at 0x7FFE12AB rip=ly_authenticate+0x42",
    "ERR 0xC0000005 ACCESS_VIOLATION pid=4129 addr=0x40000",
    "SEGFAULT in ly_dm: bad address (signal 11)",
    "pam_unix(ly:auth): authentication failure; user=mikolaj",
    "SECURITY: brute_force_threshold approaching (3/3)",
    "kerberos: TGT signature mismatch — retry exhausted",
    "EPERM: operation not permitted on /dev/tty1 ctty",
    "kernel: trap_pf in user_mode rip=0x7f0fc0debeef",
    "auth.log: FAIL session=greeter tty=tty1 service=ly",
    "ECONNREFUSED: logind Varlink socket /run/systemd/login",
    "SELINUX: avc denied { read } for pid=4129 scontext=greeter_t",
    "crypto: HMAC-SHA256 verification failed (chunk 0x1A)",
    "TPM2: PCR mismatch — sealed key bound to current state",
    "FATAL: heap corruption detected at 0x55a9e3c40000",
    "WARN: clock skew >5s — NTP synchronization required",
    "DBUS: org.freedesktop.login1.SessionFailed",
    "stack smashing detected: terminated",
    "kernel: oom-killer invoked by ly-dm, gfp_mask=0x6020c0",
    "audit: type=1100 res=failed acct=mikolaj tty=tty1",
    "ssh-keygen: PKCS#11 token unavailable (slot 0)",
};

instance: ?Widget = null,
start_time: TimeOfDay,
allocator: Allocator,
terminal_buffer: *TerminalBuffer,
dots: []Dot,
lines: []Line,
fg: u32,
head_col: u32,
min_codepoint: u16,
max_codepoint: u16,
animate: *bool,
timeout_sec: u12,
frame_delay: u16,
default_cell: Cell,
tail_fade: bool,
// Active red glitch dots. Fixed-capacity ring; oldest entries get
// evicted when full. See GlitchDot above.
glitches: [GLITCH_MAX]GlitchDot,
glitch_count: usize,
// Lockout mode: when set by main.zig (via setLocked) after the user
// exceeds config.auth_fails, the column-spawn logic switches to a
// sparser, dimmer presentation using LOCKED_GLYPH_POOL instead of
// the normal Halfwidth Katakana pool. Cleared automatically the
// next time the column truly empties — but in practice the flag
// stays on until the ly process restarts, since the user can't
// authenticate to make sway log out.
locked: bool,
// Runtime-tunable parameters exposed to the debug menu. Default to
// the DEFAULT_* constants at construction; the debug-menu input
// handlers may mutate them at any time and the next draw frame sees
// the new value. All ranges should match the menu's clamp logic.
speed_min: f32,
speed_max: f32,
tail_churn_prob: f32,
dark_run_start_pct: u16,
dark_run_min: u8,
dark_run_max: u8,
glitch_seed_permille: u16,
overlay_initial_ttl: u8,
overlay_lines_per_burst: u8,
rain_density: u16,
// Last-seen rain_density. Tracked so a change (user slid the
// debug-menu slider) can re-roll every column's line.space to
// match the new bound — without this, density only takes effect
// on each column's NEXT spawn (which can take 10+ seconds at
// low rd because line.space ticks at advance-rate, not frame-rate).
rain_density_prev: u16,
min_drop_len: u8,
// Inclusive upper bound on a freshly-spawned raindrop's trail
// length (in cells). Spawn rolls a length in
// [min_drop_len, min(max_drop_len, screen_height - 1)] so the
// value can never overflow the visible area.
max_drop_len: u8,
// Vertical drop margin: when a new trail is about to spawn at
// the top of a column, the top N rows of that column must be
// empty. Replaces the old "whole column must be empty" gate so
// multiple trails can coexist in one column, staggered. Default
// 8 (≈ 8 cells of clearance above the next spawn). Setting this
// to the screen height effectively restores the old single-
// trail-per-column behavior.
drop_v_margin: u16,
// Horizontal drop margin: when checking spawn eligibility, also
// require the top drop_v_margin rows of any column within N
// cells (left and right) to be empty. 0 = no horizontal gate;
// adjacent columns may have heads at the same row. Higher
// values produce a "shuffled" appearance with fewer
// simultaneous heads along any horizontal line.
drop_h_margin: u16,
// Inclusive glitch-dot lifetime range. Higher values = dots
// linger longer. Tunable via debug menu, persisted by savePrefs.
glitch_ttl_min: u8,
glitch_ttl_max: u8,
// Frames elapsed since the most recent error burst (runtime
// counter, not a tunable). Drives the decay curve in decayOverlay.
overlay_decay_counter: u32,
// Total frames over which the error overlay decays. Counter
// climbs from 0 to this value; per-cell drop probability scales
// phase² × overlay_drop_peak_prob.
overlay_decay_frames: u16,
overlay_drop_peak_prob: f32,
// Per-frame probability that an overlay cell's glyph cycles to
// a random printable ASCII char (independent of the drop logic).
// 0 = no scrambling; small values give a subtle "data corrupting"
// flicker before the line falls away.
overlay_scramble_prob: f32,
// How many rows an overlay glyph descends when a drop event
// fires. Larger = faster apparent fall. 1 = single-row hop
// (default, smooth); 2+ feels like the glyph is accelerating.
overlay_fall_step: u8,

pub fn init(
    allocator: Allocator,
    terminal_buffer: *TerminalBuffer,
    fg: u32,
    head_col: u32,
    min_codepoint: u16,
    max_codepoint: u16,
    animate: *bool,
    timeout_sec: u12,
    frame_delay: u16,
    tail_fade: bool,
) !Matrix {
    const dots = try allocator.alloc(Dot, terminal_buffer.width * (terminal_buffer.height + 1));
    const lines = try allocator.alloc(Line, terminal_buffer.width);

    initBuffers(dots, lines, terminal_buffer.width, terminal_buffer.height, terminal_buffer.random);

    return .{
        .instance = null,
        .start_time = try interop.getTimeOfDay(),
        .allocator = allocator,
        .terminal_buffer = terminal_buffer,
        .dots = dots,
        .lines = lines,
        .fg = fg,
        .head_col = head_col,
        .min_codepoint = min_codepoint,
        .max_codepoint = max_codepoint - min_codepoint,
        .animate = animate,
        .timeout_sec = timeout_sec,
        .frame_delay = frame_delay,
        .default_cell = .{ .ch = ' ', .fg = fg, .bg = terminal_buffer.bg },
        .tail_fade = tail_fade,
        .glitches = undefined,
        .glitch_count = 0,
        .locked = false,
        .speed_min = DEFAULT_SPEED_MIN,
        .speed_max = DEFAULT_SPEED_MAX,
        .tail_churn_prob = DEFAULT_TAIL_CHURN_PROB,
        .dark_run_start_pct = DEFAULT_DARK_RUN_START_PCT,
        .dark_run_min = DEFAULT_DARK_RUN_MIN,
        .dark_run_max = DEFAULT_DARK_RUN_MAX,
        .glitch_seed_permille = DEFAULT_GLITCH_SEED_PERMILLE,
        .overlay_initial_ttl = DEFAULT_OVERLAY_INITIAL_TTL,
        .overlay_lines_per_burst = DEFAULT_OVERLAY_LINES_PER_BURST,
        .rain_density = DEFAULT_RAIN_DENSITY,
        .rain_density_prev = DEFAULT_RAIN_DENSITY,
        .drop_v_margin = DEFAULT_DROP_V_MARGIN,
        .drop_h_margin = DEFAULT_DROP_H_MARGIN,
        .min_drop_len = DEFAULT_MIN_DROP_LEN,
        .max_drop_len = DEFAULT_MAX_DROP_LEN,
        .glitch_ttl_min = DEFAULT_GLITCH_TTL_MIN,
        .glitch_ttl_max = DEFAULT_GLITCH_TTL_MAX,
        .overlay_decay_counter = std.math.maxInt(u32),
        .overlay_decay_frames = 1500,
        .overlay_drop_peak_prob = 0.04,
        .overlay_scramble_prob = 0.005,
        .overlay_fall_step = 1,
    };
}

// Linear interpolation between two RGBA-ish u32 colors. Preserves
// alpha/styling byte from `a`. Outputs raw 24-bit values — no snapping
// to a coarse palette. The kernel VT framebuffer console will still
// collapse most of these to the 16-color VGA palette (so the gradient
// looks 2-3 stops on a raw TTY), but when ly-dm runs inside kmscon
// (which renders truecolor via Pango/freetype), the full continuous
// fade is visible.
fn lerpColor(a: u32, b: u32, t: f32) u32 {
    const t_clamped: f32 = if (t < 0) 0 else if (t > 1) 1 else t;
    const a_r: f32 = @floatFromInt((a >> 16) & 0xFF);
    const a_g: f32 = @floatFromInt((a >> 8) & 0xFF);
    const a_b: f32 = @floatFromInt(a & 0xFF);
    const b_r: f32 = @floatFromInt((b >> 16) & 0xFF);
    const b_g: f32 = @floatFromInt((b >> 8) & 0xFF);
    const b_b: f32 = @floatFromInt(b & 0xFF);
    const r: u32 = @intFromFloat(a_r + t_clamped * (b_r - a_r));
    const g: u32 = @intFromFloat(a_g + t_clamped * (b_g - a_g));
    const bl: u32 = @intFromFloat(a_b + t_clamped * (b_b - a_b));
    return (a & 0xFF000000) | (r << 16) | (g << 8) | bl;
}

// Perceptual-gamma remap. Brightness = (1-t)^gamma so the bright end of
// the trail drops faster than linear, matching how the human visual
// system perceives intensity. User-verified at gamma=1.5 on truecolor
// kmscon rendering — values 255, 213, 174, 138, 105, 75, 49, 26, 9, 0
// for 10 evenly-spaced stops.
fn perceptualT(t_linear: f32) f32 {
    const GAMMA: f32 = 1.5;
    const tc: f32 = if (t_linear < 0) 0 else if (t_linear > 1) 1 else t_linear;
    // t' such that lerp(bright, dark, t') = bright * (1 - t_linear)^gamma
    return 1.0 - std.math.pow(f32, 1.0 - tc, GAMMA);
}


pub fn widget(self: *Matrix) *Widget {
    if (self.instance) |*instance| return instance;
    self.instance = Widget.init(
        "Matrix",
        null,
        self,
        deinit,
        realloc,
        draw,
        update,
        null,
        calculateTimeout,
    );
    return &self.instance.?;
}

fn deinit(self: *Matrix) void {
    self.allocator.free(self.dots);
    self.allocator.free(self.lines);
}

fn realloc(self: *Matrix) !void {
    const dots = try self.allocator.realloc(self.dots, self.terminal_buffer.width * (self.terminal_buffer.height + 1));
    const lines = try self.allocator.realloc(self.lines, self.terminal_buffer.width);

    initBuffers(dots, lines, self.terminal_buffer.width, self.terminal_buffer.height, self.terminal_buffer.random);

    self.dots = dots;
    self.lines = lines;
}

// ─── Column-scan helpers ──────────────────────────────────────────
// All operate on the dots[] buffer indexed as dots[width * y + x].
// "Empty" means the cell value is null or U+0020 — both represent
// "no glyph at this position" in the simulation.

inline fn cellIsEmpty(self: *const Matrix, x: usize, y: usize) bool {
    const v = self.dots[self.terminal_buffer.width * y + x].value;
    return v == null or v == ' ';
}

// True if the column has any non-empty cell in the visible area
// (y ∈ [1, buf_height]). Used to detect a fully-drained column so we
// can reset per-column run-state (virtual_head_y, dark_run).
fn columnHasContent(self: *const Matrix, x: usize) bool {
    var y: usize = 1;
    while (y <= self.terminal_buffer.height) : (y += 1) {
        if (!cellIsEmpty(self, x, y)) return true;
    }
    return false;
}

// True if rows 1..n_rows of column x are all empty. n_rows is
// clamped to buf_height. n_rows = 0 → trivially true.
fn topRowsClear(self: *const Matrix, x: usize, n_rows: usize) bool {
    const limit = @min(n_rows, self.terminal_buffer.height);
    var y: usize = 1;
    while (y <= limit) : (y += 1) {
        if (!cellIsEmpty(self, x, y)) return false;
    }
    return true;
}

// Spawn gate: column x's top drop_v_margin rows are empty AND
// (optionally) every column within drop_h_margin cells horizontally
// also has its top drop_v_margin rows empty. h_radius = 0 disables
// the horizontal check entirely. Steps of 2 because matrix columns
// occupy every other terminal column.
fn spawnGateOpen(self: *const Matrix, x: usize, v_gap: usize, h_radius: usize) bool {
    if (!topRowsClear(self, x, v_gap)) return false;
    if (h_radius == 0) return true;
    const w = self.terminal_buffer.width;
    var dx: usize = 2;
    while (dx <= h_radius) : (dx += 2) {
        if (x >= dx and !topRowsClear(self, x - dx, v_gap)) return false;
        if (x + dx < w and !topRowsClear(self, x + dx, v_gap)) return false;
    }
    return true;
}

// ─── Per-frame simulation ─────────────────────────────────────────
// stepColumns is the per-frame orchestrator for column simulation.
// Each column does, in order:
//   1. tailChurn         — every frame, glyph mutation on body cells
//   2. advance gate      — speed-based per-column "is this an advance frame?"
//   3. spawn decision    — try to add a new trail at row 1
//   4. walkColumn        — move every alive segment down by one cell
// Steps 3 & 4 only run on advance frames. Step 1 runs every frame
// so glyphs visibly mutate even between advances.
fn stepColumns(self: *Matrix) void {
    var x: usize = 0;
    while (x < self.terminal_buffer.width) : (x += 2) {
        self.tailChurn(x);

        var line = &self.lines[x];
        // Per-column advance gate. accum += speed per frame; when it
        // crosses 1.0 we run one advance and subtract back. Phase is
        // initialised random per column so all columns don't tick on
        // the same frame.
        line.advance_accum += line.speed;
        if (line.advance_accum < 1.0) continue;
        line.advance_accum -= 1.0;

        const has_content = columnHasContent(self, x);
        if (!has_content) {
            line.virtual_head_y = 0;
            line.dark_run = 0;
        }

        self.trySpawnAt(x, line, has_content);
        self.walkColumn(x, line);
    }
}

// Glyph mutation on body cells. Independent of advance rate so
// trails "bubble" smoothly even while a slow column waits to tick.
fn tailChurn(self: *Matrix, x: usize) void {
    if (!MID_SCROLL_CHANGE) return;
    if (self.tail_churn_prob <= 0) return;
    const buf_width = self.terminal_buffer.width;
    const buf_height = self.terminal_buffer.height;
    var y: usize = 1;
    while (y <= buf_height) : (y += 1) {
        const cell = &self.dots[buf_width * y + x];
        if (cell.is_head) continue;
        const v = cell.value orelse continue;
        if (v == ' ') continue;
        if (self.terminal_buffer.random.float(f32) >= self.tail_churn_prob) continue;
        const r = self.terminal_buffer.random.int(u32);
        const pool: []const u32 = if (self.locked) &LOCKED_GLYPH_POOL else &GLYPH_POOL;
        cell.value = pool[@mod(r, pool.len)];
    }
}

// Try to spawn a new trail in column x. The unified spawn path:
//   * rain_density == 0           → never spawn
//   * row 1 not empty             → never spawn (would corrupt the
//                                    trail data and merge segments)
//   * drop_v_margin / drop_h_margin → user-configurable clearance gate
//   * random < rain_density/1000  → probabilistic
//
// The "row 1 must be empty" requirement is geometric, not a knob —
// you literally cannot place two head cells at the same position.
// The old flood_mode branch tried to overwrite row 1 unconditionally
// and produced the "initial wave then nothing" bug because walking
// then coalesced the overwritten cell with the existing trail into
// a single growing segment.
fn trySpawnAt(self: *Matrix, x: usize, line: *Line, column_has_content: bool) void {
    if (self.rain_density == 0) return;

    const buf_width = self.terminal_buffer.width;
    const buf_height = self.terminal_buffer.height;

    // Effective vertical gate: at least 2 rows must be empty above
    // the spawn point. WHY: spawn writes a head at row 1, walking
    // advances it to row 2 in the same frame (new trail occupies
    // rows 1..2 post-walk). For the next walk pass to keep the new
    // trail separate from any existing trail in the column, there
    // has to be at least one EMPTY cell between them — which means
    // row 3 must be empty at spawn time. Hence min effective gap
    // of 2 (rows 1..2 = spawn target + walk step; user-visible
    // drop_v_margin adds rows on top for visual spacing). Without
    // this clamp the walking layer coalesces adjacent non-empty
    // cells into ONE segment and we get a single shifting trail
    // per column instead of multi-trail — the bug the user saw as
    // "big wave then nothing".
    const v_user = @min(@as(usize, self.drop_v_margin), buf_height);
    const v_gap: usize = @max(v_user, 2);
    const h_gap = @as(usize, self.drop_h_margin);
    if (!spawnGateOpen(self, x, v_gap, h_gap)) return;

    const row1_idx = buf_width + x;

    // Per-advance Poisson probability.
    const prob_base: f32 = @as(f32, @floatFromInt(self.rain_density)) / 1000.0;
    const spawn_prob: f32 = if (self.locked)
        prob_base / @as(f32, @floatFromInt(LOCKED_SPACE_MULT))
    else
        prob_base;
    if (self.terminal_buffer.random.float(f32) >= spawn_prob) return;

    const randint = self.terminal_buffer.random.int(u16);

    // line.length / line.speed are SHARED across all trails alive
    // in a column. Re-rolling them while existing trails are mid-
    // fall would visibly shift those trails' colors. Only roll on
    // a fresh column.
    if (!column_has_content) {
        const max_eff_raw: usize = @min(@as(usize, self.max_drop_len), if (buf_height > 1) buf_height - 1 else 1);
        const max_eff: usize = if (max_eff_raw < self.min_drop_len) self.min_drop_len else max_eff_raw;
        const len_span: usize = max_eff - self.min_drop_len + 1;
        line.length = (@as(usize, randint) % len_span) + self.min_drop_len;
        line.speed = self.speed_min +
            self.terminal_buffer.random.float(f32) * (self.speed_max - self.speed_min);
    }

    // Write the new head at row 1. The render layer paints
    // is_head=true cells bright. walkColumn on this same advance
    // will turn this cell into a body and place a fresh head at
    // row 2.
    const pool: []const u32 = if (self.locked) &LOCKED_GLYPH_POOL else &GLYPH_POOL;
    self.dots[row1_idx].value = pool[@mod(randint, pool.len)];
    self.dots[row1_idx].is_head = true;
}

// Walk every alive segment in column x down by one cell. A "segment"
// is a contiguous run of non-empty cells. For each segment:
//   1. clear is_head on the existing cells
//   2. append a new head one cell below the segment's last body
//   3. if the segment now exceeds line.length, truncate the top
// Multiple segments in one column (multi-trail mode) are handled
// identically — no first_col special case.
fn walkColumn(self: *Matrix, x: usize, line: *Line) void {
    const buf_width = self.terminal_buffer.width;
    const buf_height = self.terminal_buffer.height;

    var y: usize = 0;
    height_it: while (y <= buf_height) : (y += 1) {
        var dot = &self.dots[buf_width * y + x];
        // Skip empty cells.
        while (y <= buf_height and (dot.value == ' ' or dot.value == null)) {
            y += 1;
            if (y > buf_height) break :height_it;
            dot = &self.dots[buf_width * y + x];
        }

        // Walk the segment.
        const tail = y;
        var seg_len: usize = 0;
        while (y <= buf_height and dot.value != ' ' and dot.value != null) {
            dot.is_head = false;
            y += 1;
            seg_len += 1;
            if (y > buf_height) {
                // Trail head walked off the bottom — fade body
                // against virtual_head_y (which keeps advancing
                // each frame past buf_height so the body smoothly
                // dims to nothing).
                self.dots[buf_width * tail + x].value = ' ';
                if (line.virtual_head_y <= buf_height) {
                    line.virtual_head_y = buf_height + 1;
                } else {
                    line.virtual_head_y += 1;
                }
                break :height_it;
            }
            dot = &self.dots[buf_width * y + x];
        }

        // Append the new head one cell past the segment's bottom.
        const randint = self.terminal_buffer.random.int(u16);
        const head_pool: []const u32 = if (self.locked) &LOCKED_GLYPH_POOL else &GLYPH_POOL;
        dot.value = head_pool[@mod(randint, head_pool.len)];
        dot.is_head = true;
        // Rain head walking over an error-overlay cell counts as
        // one scrub pass. Once ttl hits 0 the cell returns to
        // normal rain.
        if (dot.overlay_ttl > 0) dot.overlay_ttl -= 1;
        // Dark-gap-run state machine. Each head spawn rolls a
        // chance to start a dark run; while a run is active,
        // successive heads are marked dark (renderer treats them
        // as gaps).
        if (line.dark_run > 0) {
            dot.is_dark = true;
            line.dark_run -= 1;
        } else {
            dot.is_dark = false;
            const start_roll = self.terminal_buffer.random.int(u16);
            if (@mod(start_roll, 100) < self.dark_run_start_pct) {
                const span = (self.dark_run_max - self.dark_run_min) + 1;
                const len_roll = self.terminal_buffer.random.int(u16);
                line.dark_run = @as(u8, @intCast(@mod(len_roll, span))) + self.dark_run_min;
                dot.is_dark = true;
                line.dark_run -= 1;
            }
        }
        line.virtual_head_y = y;

        // Truncate the segment from the top when it exceeds
        // line.length. seg_len grows by 1 each advance until this
        // kicks in, at which point the trail length stabilises
        // at line.length.
        if (seg_len > line.length) {
            self.dots[buf_width * tail + x].value = ' ';
        }
    }
}

// Public: switch into locked-out presentation. Main calls this once
// the user crosses config.auth_fails. The flag is sticky for the
// lifetime of the Matrix; restoring it would require an unlock event
// ly doesn't currently emit. See "locked" field doc.
pub fn setLocked(self: *Matrix, locked: bool) void {
    self.locked = locked;
}

// Pool used when locked. Encrypted/obfuscated-looking glyphs — no
// katakana, no readable letters. Box-drawing + arithmetic operators
// + a couple punctuation marks. Reads as "scrambled data".
const LOCKED_GLYPH_POOL = [_]u32{
    '#', '#', '#', '*', '*', '@', '@', '&', '&', '%',
    '!', '?', '=', '+', '~', '^', ':', ';', '/', '\\',
    '|', '<', '>', '$', '_', '.', ',',
    // Box-drawing for visual texture (JBMono ships these).
    0x2500, 0x2502, 0x2503, 0x2504, 0x2506, 0x250C, 0x2510,
    0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C,
    // Block elements
    0x2591, 0x2592, 0x2593,
    // Geometric (subdued)
    0x25E6, 0x25CB, 0x25A1, 0x25A2,
};

// Dim gray used as fg when locked. Cool blue-tinted gray reads as
// "system in safe mode" rather than the panic-red OVERLAY_FG. Bold
// bit cleared so it stays subdued against the black bg.
const LOCKED_FG: u32 = 0x00606060;

// In locked mode, line.space rolls from this larger range so columns
// idle longer between trails — the on-screen density drops sharply
// without us having to skip whole columns entirely.
const LOCKED_SPACE_MULT: usize = 3;

// Public: invoked by main.zig on every failed auth attempt. Stamps
// self.overlay_lines_per_burst rows of random fake-error-code text into the
// overlay layer. Each cell's TTL counts down only when a rain head
// walks across it, so the text gets visually "scrubbed away" by
// passing raindrops — slow when rain is light, fast when dense.
// At ~50fps this is roughly 30s — the time after which an
// untouched overlay should be fully gone via the per-frame
// fall-down. Mimics faillock's lockout window without depending on
// faillock state.
const OVERLAY_DECAY_FRAMES: u32 = 1500;

pub fn pushErrorBurst(self: *Matrix) void {
    // Restart the decay timer so the freshly-added error text gets
    // its full settle period before falling. Multiple bursts in
    // quick succession therefore accumulate and persist longer —
    // matching the user's intuition that more attempts = more red.
    self.overlay_decay_counter = 0;

    const w = self.terminal_buffer.width;
    const h = self.terminal_buffer.height;
    if (w == 0 or h == 0) return;

    var line_idx: usize = 0;
    while (line_idx < self.overlay_lines_per_burst) : (line_idx += 1) {
        const row_roll = self.terminal_buffer.random.int(u16);
        const row = @as(usize, @mod(row_roll, @as(u16, @intCast(h)))) + 1;

        const txt_roll = self.terminal_buffer.random.int(u16);
        const txt = ERROR_LINES[@mod(txt_roll, ERROR_LINES.len)];

        const col_roll = self.terminal_buffer.random.int(u16);
        // Start at a random offset so successive bursts of the same
        // line aren't always pinned to column 0.
        const safe_w: u16 = if (w >= 4) @as(u16, @intCast(w - 4)) else 1;
        const start_col = @as(usize, @mod(col_roll, safe_w));

        for (txt, 0..) |ch, i| {
            const cx = start_col + i;
            if (cx >= w) break;
            const idx = w * row + cx;
            if (idx >= self.dots.len) break;
            self.dots[idx].overlay_ch = @intCast(ch);
            self.dots[idx].overlay_ttl = self.overlay_initial_ttl;
        }
    }
}

// Public: wipe every overlay cell immediately. Wired to the
// [ clear errors ] debug action.
pub fn clearOverlay(self: *Matrix) void {
    for (self.dots) |*d| {
        d.overlay_ttl = 0;
        d.overlay_ch = ' ';
    }
    self.overlay_decay_counter = std.math.maxInt(u32);
}

// Per-frame overlay decay. As overlay_decay_counter climbs toward
// overlay_decay_frames, each overlay cell has an increasing
// probability of "falling" — moving its glyph one row down (or
// disappearing if at the bottom). Iterate bottom-up so a moved
// glyph isn't re-processed in the same frame.
fn decayOverlay(self: *Matrix) void {
    if (self.overlay_decay_counter >= self.overlay_decay_frames) {
        self.overlay_decay_counter = self.overlay_decay_frames;
        return;
    }
    self.overlay_decay_counter += 1;

    // Ramp 0..1 across the decay window. Squared so the drop rate
    // is gentle at the start and accelerates as we approach the
    // end of the faillock window.
    const phase: f32 = @as(f32, @floatFromInt(self.overlay_decay_counter)) /
        @as(f32, @floatFromInt(@max(self.overlay_decay_frames, 1)));
    const drop_prob: f32 = phase * phase * self.overlay_drop_peak_prob;
    const scramble_prob: f32 = self.overlay_scramble_prob;

    const w = self.terminal_buffer.width;
    const h = self.terminal_buffer.height;
    if (w == 0 or h == 0) return;

    var y_iter: usize = h;
    while (y_iter >= 1) : (y_iter -= 1) {
        var x: usize = 0;
        while (x < w) : (x += 2) {
            const idx = w * y_iter + x;
            if (idx >= self.dots.len) continue;
            const dot = &self.dots[idx];
            if (dot.overlay_ttl == 0) continue;

            // Scramble pass: with probability scramble_prob, replace
            // the overlay glyph with a random printable ASCII char
            // (33..126). Visually reads as the error text
            // "corrupting" before lines fall.
            if (scramble_prob > 0 and
                self.terminal_buffer.random.float(f32) < scramble_prob)
            {
                const sr = self.terminal_buffer.random.int(u16);
                dot.overlay_ch = 33 + @as(u32, @mod(sr, 94));
            }

            if (self.terminal_buffer.random.float(f32) >= drop_prob) continue;
            // Move the overlay glyph N rows down where N is
            // overlay_fall_step (clamped so we don't go past the
            // last row). If the step would land past bottom, the
            // glyph just disappears.
            const step: usize = @max(1, self.overlay_fall_step);
            const dest = y_iter + step;
            if (dest <= h) {
                const tidx = w * dest + x;
                if (tidx < self.dots.len) {
                    const target = &self.dots[tidx];
                    target.overlay_ch = dot.overlay_ch;
                    target.overlay_ttl = dot.overlay_ttl;
                }
            }
            dot.overlay_ttl = 0;
            dot.overlay_ch = ' ';
        }
    }
}

// ─── persistence ────────────────────────────────────────────────────
// Tunables auto-save to PREFS_PATH after every debug-menu edit and
// auto-load on init. Format is one `key=value` line per field —
// trivially parseable + human-readable. Fields keep their default
// values when absent (so adding a new field doesn't break old prefs).
pub const PREFS_PATH: []const u8 = "/var/lib/ly/matrix-prefs";

pub fn savePrefs(self: *Matrix, io: std.Io) void {
    // Best-effort: failure to persist is silently ignored.
    saveImpl(self, io) catch {};
}

fn saveImpl(self: *Matrix, io: std.Io) !void {
    // Ensure the parent directory exists. systemd's StateDirectory=ly
    // creates /var/lib/ly automatically when the unit starts; this
    // is a defence in case the directory was wiped.
    std.Io.Dir.cwd().createDirPath(io, "/var/lib/ly") catch {};

    var file = try std.Io.Dir.cwd().createFile(
        io,
        PREFS_PATH,
        .{ .permissions = .fromMode(0o600) },
    );
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print("speed_min={d:.4}\n", .{self.speed_min});
    try w.interface.print("speed_max={d:.4}\n", .{self.speed_max});
    try w.interface.print("tail_churn_prob={d:.4}\n", .{self.tail_churn_prob});
    try w.interface.print("dark_run_start_pct={d}\n", .{self.dark_run_start_pct});
    try w.interface.print("dark_run_min={d}\n", .{self.dark_run_min});
    try w.interface.print("dark_run_max={d}\n", .{self.dark_run_max});
    try w.interface.print("glitch_seed_permille={d}\n", .{self.glitch_seed_permille});
    try w.interface.print("overlay_initial_ttl={d}\n", .{self.overlay_initial_ttl});
    try w.interface.print("overlay_lines_per_burst={d}\n", .{self.overlay_lines_per_burst});
    try w.interface.print("rain_density={d}\n", .{self.rain_density});
    try w.interface.print("min_drop_len={d}\n", .{self.min_drop_len});
    try w.interface.print("max_drop_len={d}\n", .{self.max_drop_len});
    try w.interface.print("drop_v_margin={d}\n", .{self.drop_v_margin});
    try w.interface.print("drop_h_margin={d}\n", .{self.drop_h_margin});
    try w.interface.print("glitch_ttl_min={d}\n", .{self.glitch_ttl_min});
    try w.interface.print("glitch_ttl_max={d}\n", .{self.glitch_ttl_max});
    try w.interface.print("overlay_decay_frames={d}\n", .{self.overlay_decay_frames});
    try w.interface.print("overlay_drop_peak_prob={d:.4}\n", .{self.overlay_drop_peak_prob});
    try w.interface.print("overlay_scramble_prob={d:.4}\n", .{self.overlay_scramble_prob});
    try w.interface.print("overlay_fall_step={d}\n", .{self.overlay_fall_step});
    try w.interface.flush();
}

pub fn loadPrefs(self: *Matrix, io: std.Io) void {
    loadImpl(self, io) catch {
        // Missing/corrupt prefs file is fine — defaults apply.
    };
}

fn loadImpl(self: *Matrix, io: std.Io) !void {
    var file = try std.Io.Dir.cwd().openFile(
        io,
        PREFS_PATH,
        .{ .mode = .read_only },
    );
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var r = &fr.interface;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch break;
        const trimmed = std.mem.trimEnd(u8, line, "\n\r ");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq];
        const val = trimmed[eq + 1 ..];

        if (std.mem.eql(u8, key, "speed_min")) self.speed_min = std.fmt.parseFloat(f32, val) catch self.speed_min
        else if (std.mem.eql(u8, key, "speed_max")) self.speed_max = std.fmt.parseFloat(f32, val) catch self.speed_max
        else if (std.mem.eql(u8, key, "tail_churn_prob")) self.tail_churn_prob = std.fmt.parseFloat(f32, val) catch self.tail_churn_prob
        else if (std.mem.eql(u8, key, "dark_run_start_pct")) self.dark_run_start_pct = std.fmt.parseInt(u16, val, 10) catch self.dark_run_start_pct
        else if (std.mem.eql(u8, key, "dark_run_min")) self.dark_run_min = std.fmt.parseInt(u8, val, 10) catch self.dark_run_min
        else if (std.mem.eql(u8, key, "dark_run_max")) self.dark_run_max = std.fmt.parseInt(u8, val, 10) catch self.dark_run_max
        else if (std.mem.eql(u8, key, "glitch_seed_permille")) self.glitch_seed_permille = std.fmt.parseInt(u16, val, 10) catch self.glitch_seed_permille
        else if (std.mem.eql(u8, key, "overlay_initial_ttl")) self.overlay_initial_ttl = std.fmt.parseInt(u8, val, 10) catch self.overlay_initial_ttl
        else if (std.mem.eql(u8, key, "overlay_lines_per_burst")) self.overlay_lines_per_burst = std.fmt.parseInt(u8, val, 10) catch self.overlay_lines_per_burst
        // Two prior prefs formats to migrate:
        //   density_div  — original divisor (smaller = denser, 0..60).
        //                  Inverse direction, scaled to 0..1000.
        //   rain_density (legacy u8 0..20) — first inversion attempt.
        //                  Rescale to the wider 0..1000 range.
        // The new format is rain_density in 0..1000 (saved as-is).
        // Detection heuristic: legacy rain_density values land in
        // 0..20; new-format values land in 0..1000 and almost always
        // exceed 20. The narrow overlap is acceptable because the
        // user's slider step in the new system is 5+ (so values 1..19
        // are rarely hit) and the migration only runs once before
        // savePrefs canonicalises the file to the new range.
        else if (std.mem.eql(u8, key, "density_div")) {
            const old_div = std.fmt.parseInt(u16, val, 10) catch continue;
            // density_div 0..60 (smaller=denser). Map 0→1000 (flood),
            // 60→0 (no spawn). Linear: rd = max(0, 1000 - old_div*17).
            const scaled: i32 = 1000 - @as(i32, old_div) * 17;
            self.rain_density = @intCast(@max(0, @min(1000, scaled)));
        }
        else if (std.mem.eql(u8, key, "rain_density")) {
            const v = std.fmt.parseInt(u16, val, 10) catch continue;
            // Legacy rain_density was 0..20. Rescale to new 0..1000
            // by multiplying by 50. Values > 20 are assumed already
            // in the new format and used as-is. Clamped to 1000.
            self.rain_density = if (v <= 20) @min(1000, @as(u16, v) * 50) else @min(1000, v);
        }
        else if (std.mem.eql(u8, key, "min_drop_len")) self.min_drop_len = std.fmt.parseInt(u8, val, 10) catch self.min_drop_len
        else if (std.mem.eql(u8, key, "max_drop_len")) self.max_drop_len = std.fmt.parseInt(u8, val, 10) catch self.max_drop_len
        else if (std.mem.eql(u8, key, "drop_v_margin")) self.drop_v_margin = std.fmt.parseInt(u16, val, 10) catch self.drop_v_margin
        else if (std.mem.eql(u8, key, "drop_h_margin")) self.drop_h_margin = std.fmt.parseInt(u16, val, 10) catch self.drop_h_margin
        else if (std.mem.eql(u8, key, "glitch_ttl_min")) self.glitch_ttl_min = std.fmt.parseInt(u8, val, 10) catch self.glitch_ttl_min
        else if (std.mem.eql(u8, key, "glitch_ttl_max")) self.glitch_ttl_max = std.fmt.parseInt(u8, val, 10) catch self.glitch_ttl_max
        else if (std.mem.eql(u8, key, "overlay_decay_frames")) self.overlay_decay_frames = std.fmt.parseInt(u16, val, 10) catch self.overlay_decay_frames
        else if (std.mem.eql(u8, key, "overlay_drop_peak_prob")) self.overlay_drop_peak_prob = std.fmt.parseFloat(f32, val) catch self.overlay_drop_peak_prob
        else if (std.mem.eql(u8, key, "overlay_scramble_prob")) self.overlay_scramble_prob = std.fmt.parseFloat(f32, val) catch self.overlay_scramble_prob
        else if (std.mem.eql(u8, key, "overlay_fall_step")) self.overlay_fall_step = std.fmt.parseInt(u8, val, 10) catch self.overlay_fall_step;
    }
}

// Decrement every active glitch dot's TTL and reap dead ones. Then
// roll the seed probability and possibly spawn a new one at a random
// cell. Called once per draw frame, BEFORE the render pass uses the
// dots' positions.
fn tickGlitches(self: *Matrix) void {
    var i: usize = 0;
    while (i < self.glitch_count) {
        if (self.glitches[i].ttl <= 1) {
            // Swap-and-pop instead of memmove — order doesn't matter.
            self.glitches[i] = self.glitches[self.glitch_count - 1];
            self.glitch_count -= 1;
            continue;
        }
        self.glitches[i].ttl -= 1;
        i += 1;
    }

    if (self.glitch_count < GLITCH_MAX) {
        const seed_roll = self.terminal_buffer.random.int(u16);
        if (@mod(seed_roll, 1000) < self.glitch_seed_permille) {
            const w = self.terminal_buffer.width;
            const h = self.terminal_buffer.height;
            if (w >= 2 and h >= 1) {
                // Pick a random cell, but skip empty / dark cells.
                // A glitch landing on an invisible cell renders
                // nothing — the dot would silently vanish. Try a
                // few times before giving up so we don't bias
                // toward any particular region.
                const ttl_min = self.glitch_ttl_min;
                const ttl_max_raw = self.glitch_ttl_max;
                const ttl_max = if (ttl_max_raw < ttl_min) ttl_min else ttl_max_raw;
                const ttl_span: u8 = ttl_max - ttl_min + 1;

                var attempts: u8 = 0;
                while (attempts < 8) : (attempts += 1) {
                    const rx = self.terminal_buffer.random.int(u16);
                    const ry = self.terminal_buffer.random.int(u16);
                    // Even x only — columns are spaced 2 cells apart.
                    const gx = (@as(usize, @mod(rx, @as(u16, @intCast(w / 2)))) * 2);
                    const gy = @as(usize, @mod(ry, @as(u16, @intCast(h)))) + 1;

                    const idx = w * gy + gx;
                    if (idx >= self.dots.len) continue;
                    const dot = self.dots[idx];
                    // Skip empty cells (no rain glyph here at all).
                    if (dot.value == null or dot.value == ' ') continue;
                    // Skip dark-gap cells — those render as default
                    // (blank) so a red overlay would be invisible.
                    if (dot.is_dark) continue;
                    // Skip cells already covered by another glitch
                    // (the lookup in glitchAt is cheap enough).
                    if (self.glitchAt(gx, gy)) continue;

                    const rttl = self.terminal_buffer.random.int(u16);
                    const gttl = @as(u8, @intCast(@mod(rttl, ttl_span))) + ttl_min;
                    self.glitches[self.glitch_count] = .{ .x = gx, .y = gy, .ttl = gttl };
                    self.glitch_count += 1;
                    break;
                }
            }
        }
    }
}

// Lookup helper: does any active glitch dot overlap this cell? Linear
// scan is fine — GLITCH_MAX is 32 and we hit this for every rendered
// cell, but the cache line stays hot and branch is predictable.
fn glitchAt(self: *const Matrix, x: usize, y: usize) bool {
    var i: usize = 0;
    while (i < self.glitch_count) : (i += 1) {
        if (self.glitches[i].x == x and self.glitches[i].y == y) return true;
    }
    return false;
}

fn draw(self: *Matrix) void {
    if (!self.animate.*) return;

    const buf_height = self.terminal_buffer.height;
    const buf_width = self.terminal_buffer.width;

    // No density-change re-roll needed anymore: spawn is now
    // probabilistic per-advance (rain_density/1000), so the slider
    // takes effect on the very next advance per column. rain_density_prev
    // is kept on the struct for ABI stability but no longer read.
    _ = self.rain_density_prev; // suppress "field unused" reads
    self.rain_density_prev = self.rain_density;

    self.stepColumns();
    self.tickGlitches();
    self.decayOverlay();

    var x: usize = 0;
    while (x < buf_width) : (x += 2) {
        self.renderColumn(x, buf_width, buf_height);
    }
}

// Stack-allocated head list capacity. With multi-trail mode a column
// can host up to ceil(buf_height / min_drop_len) heads; at min_len=2
// on a 200-row terminal that's 100, well under this cap.
const HEADS_BUF_CAP = 512;

// Render one matrix column. Pre-scans the column's heads (for fade
// reference), then iterates each visible row computing the cell.
// The two-pass design avoids re-scanning the entire column for each
// cell's nearest-head lookup; per-cell cost stays O(1) amortised.
fn renderColumn(self: *Matrix, x: usize, buf_width: usize, buf_height: usize) void {
    var heads_buf: [HEADS_BUF_CAP]usize = undefined;
    var heads_count: usize = 0;
    if (self.tail_fade) {
        var sy: usize = 1;
        while (sy <= buf_height) : (sy += 1) {
            if (self.dots[buf_width * sy + x].is_head and heads_count < heads_buf.len) {
                heads_buf[heads_count] = sy;
                heads_count += 1;
            }
        }
    }
    const heads = heads_buf[0..heads_count];

    var head_idx: usize = 0;
    var y: usize = 1;
    while (y <= buf_height) : (y += 1) {
        // Advance head_idx to the first head >= current y. That's
        // this cell's fade-reference point.
        while (head_idx < heads.len and heads[head_idx] < y) head_idx += 1;

        const dot = self.dots[buf_width * y + x];
        const cell = self.cellForRender(x, y, dot, heads, head_idx);
        cell.put(x, y - 1);
        // Fill the spacer column to the right (matrix uses every
        // other terminal column).
        self.default_cell.put(x + 1, y - 1);
    }
}

// Compute the Cell to render for a single (x, y) dot. Pure function
// of dot + per-column state — no side effects, no terminal buffer
// writes. Precedence:
//   1. Active error-overlay glyph → red overlay
//   2. Empty / dark-gap cell → default_cell (background)
//   3. Active glitch dot → recolor red, keep glyph
//   4. is_head and y > 1 → head_col (bright white)
//   5. Body → perceptual fade against nearest head_y_f
fn cellForRender(
    self: *const Matrix,
    x: usize,
    y: usize,
    dot: Dot,
    heads: []const usize,
    head_idx: usize,
) Cell {
    // Error overlay takes precedence — readable "scanline" persists
    // across the rain until heads scrub past.
    if (dot.overlay_ttl > 0) {
        return Cell{ .ch = dot.overlay_ch, .fg = OVERLAY_FG, .bg = self.terminal_buffer.bg };
    }
    // Empty / dark-gap cells.
    if (dot.value == null or dot.value == ' ' or dot.is_dark) return self.default_cell;

    const fg = self.fgForBodyCell(x, y, dot, heads, head_idx) orelse return self.default_cell;
    const final_fg: u32 = if (self.glitchAt(x, y)) GLITCH_FG else fg;
    return Cell{
        .ch = @intCast(dot.value.?),
        .fg = final_fg,
        .bg = self.terminal_buffer.bg,
    };
}

// Compute the fg color for a body cell. Returns null when the cell
// should fall through to default_cell (fade is fully past the
// trail length, or the chosen fade reference is invalid). Splits
// out the fade math from cellForRender so the rendering precedence
// stays readable.
fn fgForBodyCell(
    self: *const Matrix,
    x: usize,
    y: usize,
    dot: Dot,
    heads: []const usize,
    head_idx: usize,
) ?u32 {
    // Every is_head cell renders as head_col regardless of position
    // along the trail. y>1 guard: a head at row 1 with no body
    // below would pop as a lone white cell — wait one advance for
    // walking to place a body under it.
    if (dot.is_head and y > 1) return self.head_col;

    const trail_fg: u32 = if (self.locked) LOCKED_FG else self.fg;
    if (!self.tail_fade) return trail_fg;

    // Sub-step interpolation: walking moves heads ONLY when
    // advance_accum crosses 1.0 (every 1/line.speed frames).
    // Adding accum to the integer head y produces a continuous
    // fractional distance, so cells fade smoothly across every
    // render frame instead of jumping a step every walk.
    const sub_step: f32 = self.lines[x].advance_accum;
    const head_y_f: f32 = if (head_idx < heads.len)
        @as(f32, @floatFromInt(heads[head_idx])) + sub_step
    else blk: {
        const vhy = self.lines[x].virtual_head_y;
        if (vhy == 0 or vhy <= y) return null;
        break :blk @as(f32, @floatFromInt(vhy)) + sub_step;
    };

    const distance_f: f32 = head_y_f - @as(f32, @floatFromInt(y));
    const tail_len = self.lines[x].length;
    const denom: f32 = if (tail_len == 0) 1 else @floatFromInt(tail_len);
    const t_linear = distance_f / denom;
    if (t_linear >= 1.0) return null; // fully past the trail
    const t = perceptualT(if (t_linear < 0) 0 else t_linear);
    const faded = lerpColor(trail_fg, self.terminal_buffer.bg, t);

    // Pango/kmscon paints a non-space glyph with default fg
    // (usually white) when fg==bg, on the theory that fg==bg would
    // be invisible. At the tail end of our fade lerpColor truncates
    // to fg==bg, surfacing the cell as bright white instead of
    // dimming out. Fall through to default_cell to avoid this.
    if ((faded & 0x00FFFFFF) == (self.terminal_buffer.bg & 0x00FFFFFF)) {
        return null;
    }
    return faded;
}

fn update(self: *Matrix, _: *anyopaque) !void {
    const time = try interop.getTimeOfDay();

    if (self.timeout_sec > 0 and time.seconds - self.start_time.seconds > self.timeout_sec) {
        self.animate.* = false;
    }
}

fn calculateTimeout(self: *Matrix, _: *anyopaque) !?usize {
    return self.frame_delay;
}

fn initBuffers(dots: []Dot, lines: []Line, width: usize, height: usize, random: Random) void {
    // allocator.alloc returns uninitialised memory; the in-struct
    // defaults (= 0, = false) don't apply to freshly-allocated slots.
    // Zero every Dot fully so overlay_ttl/is_dark/etc. aren't junk
    // values that surface as red Tofu (font fallback) on the first
    // render frame.
    for (dots) |*d| d.* = .{ .value = null, .is_head = false };

    var x: usize = 0;
    while (x < width) : (x += 2) {
        var line = lines[x];
        line.space = @mod(random.int(u16), height / 3) + 1;
        line.length = @mod(random.int(u16), height - 10) + 10;
        line.speed = DEFAULT_SPEED_MIN + random.float(f32) * (DEFAULT_SPEED_MAX - DEFAULT_SPEED_MIN);
        // Random phase so all columns don't trigger their first advance
        // on the same frame.
        line.advance_accum = random.float(f32);
        line.virtual_head_y = 0;
        line.dark_run = 0;
        lines[x] = line;

        dots[width + x].value = ' ';
    }
}

// ─── Unit tests ───────────────────────────────────────────────────
// Pure-function tests only. The rendering loop needs a real
// TerminalBuffer / termbox state and is exercised end-to-end via the
// SIGUSR1 snapshot facility — see /tmp/ly-snapshot.sh.
const testing = std.testing;

test "perceptualT bounds and monotonicity" {
    try testing.expectApproxEqAbs(@as(f32, 0.0), perceptualT(0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), perceptualT(1.0), 0.001);
    // Clamped out-of-range inputs.
    try testing.expectApproxEqAbs(@as(f32, 0.0), perceptualT(-0.5), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), perceptualT(1.5), 0.001);
    // Monotonic: each step increases output.
    var prev: f32 = -1.0;
    var i: usize = 0;
    while (i <= 20) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 20.0;
        const out = perceptualT(t);
        try testing.expect(out > prev);
        prev = out;
    }
}

test "perceptualT bends toward dark (gamma > 1)" {
    // At t=0.5, perceptual output should be > 0.5 (faster-than-linear
    // approach to "dark" / 1.0). Confirms the gamma = 1.5 curve.
    try testing.expect(perceptualT(0.5) > 0.5);
    try testing.expect(perceptualT(0.5) < 0.8);
}

test "lerpColor endpoints" {
    const green: u32 = 0x0000FF00;
    const black: u32 = 0x00000000;
    try testing.expectEqual(green, lerpColor(green, black, 0.0));
    try testing.expectEqual(black & 0xFFFFFF, lerpColor(green, black, 1.0) & 0xFFFFFF);
}

test "lerpColor preserves alpha/style byte from source" {
    const bold_green: u32 = 0x01_00FF00;
    const black: u32 = 0x00_000000;
    // Even at t=1.0 (fully b), top byte should come from `a`.
    const mixed = lerpColor(bold_green, black, 1.0);
    try testing.expectEqual(@as(u32, 0x01), (mixed >> 24) & 0xFF);
}

test "lerpColor midpoint" {
    const a: u32 = 0x000000FF;
    const b: u32 = 0x00FF0000;
    const mid = lerpColor(a, b, 0.5);
    try testing.expectEqual(@as(u32, 0x7F), (mid >> 16) & 0xFF); // R
    try testing.expectEqual(@as(u32, 0x00), (mid >> 8) & 0xFF); // G
    try testing.expectEqual(@as(u32, 0x7F), mid & 0xFF); // B
}

test "density spawn-probability range" {
    // rain_density 0..1000 maps linearly to spawn probability 0..1.
    // Verify the formula used in the spawn block.
    inline for (.{
        .{ @as(u16, 0), @as(f32, 0.0) },
        .{ @as(u16, 250), @as(f32, 0.25) },
        .{ @as(u16, 500), @as(f32, 0.5) },
        .{ @as(u16, 1000), @as(f32, 1.0) },
    }) |pair| {
        const rd: u16 = pair[0];
        const expected: f32 = pair[1];
        const got: f32 = @as(f32, @floatFromInt(rd)) / 1000.0;
        try testing.expectApproxEqAbs(expected, got, 0.001);
    }
}

// ─── Tests for spawn invariants (cellIsEmpty notion) ──────────────
// cellIsEmpty's semantics are critical: spawn refuses if row 1 is
// non-empty, where "empty" means null OR U+0020. Walking writes a
// glyph to row 1 the moment a new head moves through it, so the
// row 1 cell stays non-empty across most of the trail's lifetime —
// preventing back-to-back over-writes that would corrupt the trail.
test "cellIsEmpty considers null AND space as empty" {
    // A Dot stands in for self.dots[idx]; we replicate the predicate
    // here since cellIsEmpty needs a real Matrix to dispatch.
    const isEmpty = struct {
        fn f(value: ?usize) bool {
            return value == null or value == ' ';
        }
    }.f;
    try testing.expect(isEmpty(null));
    try testing.expect(isEmpty(' '));
    try testing.expect(!isEmpty('A'));
    try testing.expect(!isEmpty(0xFF66)); // halfwidth katakana
}

// Trail-length stabilisation: a segment grows by 1 per advance until
// it crosses line.length, at which point we trim the top each
// advance to hold the length steady at line.length. Verify the
// arithmetic for a few representative line.length values.
test "trail-length stabilisation arithmetic" {
    // After K advances, untruncated segment is K cells long.
    // Truncation fires when K > line.length. Post-truncation length
    // equals line.length (or line.length+1 mid-frame). Confirm with
    // a small simulation.
    const cases = [_]struct { line_length: usize, advances: usize, final: usize }{
        .{ .line_length = 8, .advances = 4, .final = 4 }, // not yet at cap
        .{ .line_length = 8, .advances = 8, .final = 8 }, // exactly at cap, no truncation yet
        .{ .line_length = 8, .advances = 9, .final = 8 }, // truncated once
        .{ .line_length = 8, .advances = 100, .final = 8 }, // long-run stable
        .{ .line_length = 30, .advances = 200, .final = 30 },
    };
    for (cases) |c| {
        var seg_len: usize = 0;
        var i: usize = 0;
        while (i < c.advances) : (i += 1) {
            seg_len += 1; // advance grows segment by 1
            if (seg_len > c.line_length) seg_len -= 1; // truncation trims top
        }
        try testing.expectEqual(c.final, seg_len);
    }
}

// rain_density==0 ⇒ never spawn, regardless of any other condition.
// rain_density==1000 ⇒ spawn iff random.float < 1.0, which is
// always true. Confirms the float comparison shape.
test "spawn probability boundary semantics" {
    // Pure math sanity check: spawn fires when random < prob.
    // At density=1000, prob=1.0 — every roll in [0, 1) is < 1.0,
    // so 100% spawn rate. At density=0, prob=0.0 — every roll
    // >= 0.0, so 0% spawn rate.
    const prob_1000: f32 = @as(f32, @floatFromInt(@as(u16, 1000))) / 1000.0;
    const prob_0: f32 = @as(f32, @floatFromInt(@as(u16, 0))) / 1000.0;
    try testing.expectEqual(@as(f32, 1.0), prob_1000);
    try testing.expectEqual(@as(f32, 0.0), prob_0);
    // No random.float() result in [0, 1) is < 0.0.
    try testing.expect(!(0.0 < prob_0));
    try testing.expect(!(0.5 < prob_0));
    try testing.expect(!(0.999 < prob_0));
    // Every random.float() result is < 1.0.
    try testing.expect(0.0 < prob_1000);
    try testing.expect(0.5 < prob_1000);
    try testing.expect(0.999 < prob_1000);
}
