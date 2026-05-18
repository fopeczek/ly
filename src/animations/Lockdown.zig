// Scramble→shrink→clock lockout animation. Triggered when the user
// hits config.auth_fails. Renders a multi-phase sequence on the top
// widget layer so it overdraws the rain animation and the regular
// login widgets beneath it:
//
//   scramble    Existing rain cells cycle to random katakana glyphs
//               in place — no falling, no spawning.
//   shrink_fade Per-cell shrink table progressively replaces each
//               glyph with a smaller small-Unicode glyph (◌ → ◦ →
//               · → ⋅ → blank) and lerps fg from original →
//               mid-gray → dark-gray → background. Each cell has a
//               per-cell offset so they don't all blank together.
//   blank       Empty dark screen.
//   grow_clock  MM:SS clock characters un-shrink at screen center —
//               start as ⋅, transition through · → ◦ → dim digit →
//               bright digit using the shrink palette in reverse.
//   tick        Clock counts down second-by-second. After
//               GROW_UI_DELAY_SEC the other widgets (info_line,
//               attempts, version, mod_hint) become visible too,
//               but password widget + box top_title stay hidden.
//   end_unlock  Unlock moment — caller restores password input,
//               restores top_title, resets state.auth_fails. Phase
//               returns to .idle.
//
// External-reset sync: every 2s during tick we stat /run/faillock/
// <user>. If the file no longer exists the user ran `faillock
// --reset` from elsewhere and we end the lockdown immediately.
//
// Glyph palette choice: the user explicitly rejected shaded blocks
// (▒░▓) for shrink. Real shrinking is impossible in a fixed-cell
// monospace renderer, so we substitute progressively smaller-bodied
// Unicode glyphs that visually read as "the character got smaller"
// rather than "the same character got dimmer". Combined with a
// color lerp this approximates a true shrink.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ly_ui = @import("ly-ui");
const Cell = ly_ui.Cell;
const TerminalBuffer = ly_ui.TerminalBuffer;
const Widget = ly_ui.Widget;
const Label = ly_ui.Label;
const Box = ly_ui.Box;
const ly_core = ly_ui.ly_core;
const interop = ly_core.interop;
const TimeOfDay = interop.TimeOfDay;

const Lockdown = @This();

// ─── Public types ─────────────────────────────────────────────────

pub const LockdownAnim = enum(u8) {
    // Original behaviour — Matrix.locked sparse-gray rain stays on
    // forever. Kept as an option so anyone who liked the older look
    // can opt in.
    legacy_sparse = 0,
    // New scramble→shrink→clock sequence (this module).
    scramble_shrink = 1,

    pub fn label(self: LockdownAnim) []const u8 {
        return switch (self) {
            .legacy_sparse => "legacy sparse  ",
            .scramble_shrink => "scramble→clock ",
        };
    }

    pub fn cycle(self: LockdownAnim) LockdownAnim {
        return switch (self) {
            .legacy_sparse => .scramble_shrink,
            .scramble_shrink => .legacy_sparse,
        };
    }

    pub fn fromInt(n: u8) LockdownAnim {
        return switch (n) {
            0 => .legacy_sparse,
            1 => .scramble_shrink,
            else => .scramble_shrink,
        };
    }
};

pub const Phase = enum {
    idle,
    scramble,
    shrink_fade,
    blank,
    grow_clock,
    tick,
    end_unlock,
};

// ─── Tunables ─────────────────────────────────────────────────────

pub const SCRAMBLE_SEC: f64 = 1.5;
pub const SHRINK_SEC: f64 = 2.5;
pub const BLANK_SEC: f64 = 0.8;
pub const GROW_CLOCK_SEC: f64 = 1.2;
pub const GROW_UI_DELAY_SEC: f64 = 0.7;
pub const PREVIEW_TICK_SEC: f64 = 5.0;
pub const FAILLOCK_POLL_SEC: f64 = 2.0;
pub const DEFAULT_UNLOCK_SEC: f64 = 600.0; // pam_faillock default

// Color targets.
pub const MID_GRAY: u32 = 0x01808080;
pub const DARK_GRAY: u32 = 0x01404040;
pub const VERY_DARK_GRAY: u32 = 0x01202020;
pub const CLOCK_BRIGHT: u32 = 0x01FFFFFF;
pub const CLOCK_DIM: u32 = 0x01666666;
pub const BG: u32 = 0x00000000;

// Small-glyph shrink palette. Index 0..6 ranges from "fullest" to
// "blank". Each step is a visibly smaller-bodied Unicode glyph.
//   0: original glyph (color may still fade)
//   1: original glyph (color fades further)
//   2: ◌  U+25CC dotted circle    (about same area as letter but hollow)
//   3: ◦  U+25E6 white bullet      (small open circle, mid-row)
//   4: ·  U+00B7 middle dot        (small filled dot, mid-row)
//   5: ⋅  U+22C5 dot operator      (tinier dot, often baseline-raised)
//   6: ' ' space                   (blank)
pub const SHRINK_GLYPHS = [_]u21{
    0, // sentinel — "keep original"
    0,
    0x25CC,
    0x25E6,
    0x00B7,
    0x22C5,
    ' ',
};

pub const SHRINK_STEPS: u8 = SHRINK_GLYPHS.len; // 7

// Async-signal-safe flag set by main()'s SIGUSR2 handler. Polled
// once per frame in Lockdown.updateWidget. When set: fire a preview
// run of the selected animation. Used by /tmp/ly-headless.sh so the
// scramble→clock sequence can be exercised from a `kill -USR2 <pid>`
// without typing 3 wrong passwords through a pty with no keyboard.
pub var preview_request = std.atomic.Value(bool).init(false);

// Halfwidth Katakana scramble pool — matches the Matrix rain so the
// scramble phase reads as the existing characters going haywire.
const SCRAMBLE_POOL = [_]u21{
    0xFF66, 0xFF67, 0xFF68, 0xFF69, 0xFF6A, 0xFF6B, 0xFF6C, 0xFF6D,
    0xFF6E, 0xFF6F, 0xFF70, 0xFF71, 0xFF72, 0xFF73, 0xFF74, 0xFF75,
    0xFF76, 0xFF77, 0xFF78, 0xFF79, 0xFF7A, 0xFF7B, 0xFF7C, 0xFF7D,
    0xFF7E, 0xFF7F, 0xFF80, 0xFF81, 0xFF82, 0xFF83, 0xFF84, 0xFF85,
    0xFF86, 0xFF87, 0xFF88, 0xFF89, 0xFF8A, 0xFF8B, 0xFF8C, 0xFF8D,
    0xFF8E, 0xFF8F, 0xFF90, 0xFF91, 0xFF92, 0xFF93, 0xFF94, 0xFF95,
    0xFF96, 0xFF97, 0xFF98, 0xFF99, 0xFF9A, 0xFF9B, 0xFF9C, 0xFF9D,
};

// ─── State ───────────────────────────────────────────────────────

allocator: Allocator,
buffer: *TerminalBuffer,

active: bool = false,
anim: LockdownAnim = .scramble_shrink,
preview_mode: bool = false,
// Persisted selection — read by the debug menu, used by start() as
// the default when triggered from authenticate(). The debug menu's
// "preview" action also uses this so the user can see what they
// picked.
selected_anim: LockdownAnim = .scramble_shrink,

phase: Phase = .idle,
phase_started: f64 = 0,
lockdown_started: f64 = 0,
unlock_epoch: f64 = 0,
last_external_check: f64 = 0,

// Per-cell shrink offset (in 0..SHRINK_OFFSET_MAX). Adds to
// elapsed-frame shrink index so cells reach blank at slightly
// different times.
// Per-cell START delay (0..255 → maps to [0, 0.5*SHRINK_SEC]). High
// values delay this cell's shrink onset; spreads transitions across
// the first half of the phase rather than firing on a single
// heartbeat.
shrink_t0: ?[]u8 = null,
// Per-cell DURATION (0..255 → maps to [0.5*SHRINK_SEC, 1.5*SHRINK_SEC]).
// Cells with longer durations shrink slower so they hit each
// palette index at unique times; the visual effect is alive +
// asynchronous instead of in lockstep.
shrink_dur: ?[]u8 = null,
// Per-cell scramble onset (0..255 → maps to [0, 0.7*SCRAMBLE_SEC]).
// Frame 0 of scramble shows the pristine snapshot; cells start
// flickering to random glyphs at unique times spread across most
// of the scramble phase. Avoids the "instantly half-scrambled"
// look the user reported as "running backwards".
scramble_t0: ?[]u8 = null,
// Per-cell scrambled codepoint for the scramble phase. Re-rolled
// every SCRAMBLE_REROLL_FRAMES. Index 0 means "use snapshot".
scramble_glyph: ?[]u21 = null,
// Saved rain snapshot — cells captured at start. Used as the
// "original" for shrink color fade.
snapshot: ?[]Cell = null,
// Frame-counter for scramble re-roll cadence.
scramble_frame: u32 = 0,

// True once the tick phase has progressed past GROW_UI_DELAY_SEC
// and we've handed control back to Matrix so the user sees locked-
// mode rain fall behind the clock + restored widgets. Reset by
// start(); flipped back via end_unlock through hook_matrix_locked.
tick_locked_set: bool = false,

buf_width: usize = 0,
buf_height: usize = 0,

// Faillock probe path: built once at start, reused per poll.
faillock_path_buf: [128]u8 = undefined,
faillock_path_len: usize = 0,

// Side-effect hooks set by main via attachHooks(). These let us
// perform end_unlock side-effects from inside updateWidget without
// circular-importing main's UiState. All are optional — if absent,
// the corresponding side-effect is skipped (preview mode uses this
// to avoid touching real auth state).
hook_password_should_insert: ?*bool = null,
hook_box_top_title: ?*?[]const u8 = null,
hook_auth_fails: ?*u64 = null,
hook_matrix_locked: ?*bool = null,
hook_matrix_suppressed: ?*bool = null,
hook_password_label: ?*Label = null,
// Box pointer for clock positioning — we anchor the clock 3 rows
// above the box's top border so it reads as "this is what the
// login box is waiting for". null falls back to vertical screen
// centre (only used in tests / edge cases).
hook_box: ?*Box = null,
// Saved values for restore at end_unlock. Captured at start().
saved_top_title: ?[]const u8 = null,
saved_password_label_text: []const u8 = "",

// Last-tick wall-clock time, captured by the widget update fn and
// consumed by drawWidget (draw can't return errors so it can't call
// getTimeOfDay itself).
last_now: f64 = 0,

// Cached username for faillock probe. Set by start() and (when we
// auto-fire preview from SIGUSR2) by cacheUsername.
cached_username_buf: [64]u8 = undefined,
cached_username_len: usize = 0,

// Widget instance for layer registration.
instance: ?Widget = null,

// ─── Constructor / destructor ─────────────────────────────────────

pub fn init(allocator: Allocator, buffer: *TerminalBuffer) Lockdown {
    return .{ .allocator = allocator, .buffer = buffer };
}

// Wire side-effect hooks. Called from main after UiState fields are
// stable. All four hooks are optional but the typical wiring sets
// all of them.
pub fn attachHooks(
    self: *Lockdown,
    password_should_insert: *bool,
    box_top_title: *?[]const u8,
    auth_fails: *u64,
    matrix_locked: ?*bool,
    matrix_suppressed: ?*bool,
    password_label: *Label,
    box: *Box,
) void {
    self.hook_password_should_insert = password_should_insert;
    self.hook_box_top_title = box_top_title;
    self.hook_auth_fails = auth_fails;
    self.hook_matrix_locked = matrix_locked;
    self.hook_matrix_suppressed = matrix_suppressed;
    self.hook_password_label = password_label;
    self.hook_box = box;
}

pub fn deinit(self: *Lockdown) void {
    if (self.shrink_t0) |s| self.allocator.free(s);
    if (self.shrink_dur) |s| self.allocator.free(s);
    if (self.scramble_t0) |s| self.allocator.free(s);
    if (self.scramble_glyph) |s| self.allocator.free(s);
    if (self.snapshot) |s| self.allocator.free(s);
    self.shrink_t0 = null;
    self.shrink_dur = null;
    self.scramble_t0 = null;
    self.scramble_glyph = null;
    self.snapshot = null;
}

// ─── Widget surface (top-layer overlay) ───────────────────────────

pub fn widget(self: *Lockdown) *Widget {
    if (self.instance) |*w| return w;
    self.instance = Widget.init(
        "Lockdown",
        null,
        self,
        null,
        reallocImpl,
        drawWidget,
        updateWidget,
        null,
        null,
    );
    return &self.instance.?;
}

fn reallocImpl(self: *Lockdown) !void {
    // On terminal-size change while a lockdown is active, reallocate
    // per-cell state. On inactive, drop everything — fresh alloc at
    // next start().
    self.deinit();
    if (self.active) try self.allocatePerCell(self.buffer.width, self.buffer.height);
}

fn updateWidget(self: *Lockdown, _: *anyopaque) !void {
    // Consume preview-request flag even when inactive — that's the
    // SIGUSR2 trigger for headless test sessions.
    if (preview_request.swap(false, .seq_cst) and !self.active) {
        const t = interop.getTimeOfDay() catch return;
        const now_f = todToF64(t);
        const uname = if (self.cached_username_len > 0)
            self.cached_username_buf[0..self.cached_username_len]
        else
            "preview";
        self.start(
            self.selected_anim,
            now_f + DEFAULT_UNLOCK_SEC,
            true,
            now_f,
            uname,
        ) catch return;
    }
    if (!self.active or self.phase == .idle) return;
    const t = try interop.getTimeOfDay();
    self.last_now = todToF64(t);
    const reached_end = self.update(self.last_now);
    if (reached_end) {
        self.runEndUnlockHooks();
        self.finish();
    }
}

// Cache the username for later use (SIGUSR2 preview that fires
// outside of an auth attempt). Caller can re-invoke whenever the
// active login changes.
pub fn cacheUsername(self: *Lockdown, username: []const u8) void {
    const n = @min(username.len, self.cached_username_buf.len);
    @memcpy(self.cached_username_buf[0..n], username[0..n]);
    self.cached_username_len = n;
}

fn runEndUnlockHooks(self: *Lockdown) void {
    // Restore the side-effects start() captured. Always restore the
    // UI bits (title, password input, label). auth_fails + matrix
    // locked are only flipped in non-preview mode — preview must
    // not touch the real auth state.
    if (self.hook_box_top_title) |t| {
        t.* = self.saved_top_title;
    }
    if (self.hook_password_should_insert) |p| {
        p.* = true;
    }
    if (self.hook_password_label) |lbl| {
        lbl.setText(self.saved_password_label_text);
    }
    if (!self.preview_mode) {
        if (self.hook_auth_fails) |a| a.* = 0;
        if (self.hook_matrix_locked) |m| m.* = false;
    }
    if (self.hook_matrix_suppressed) |s| s.* = false;
    self.saved_top_title = null;
    self.saved_password_label_text = "";
}

fn drawWidget(self: *Lockdown) void {
    if (!self.active or self.phase == .idle) return;
    self.draw(self.buffer);
}

// ─── Public state queries (caller uses these to gate UI) ──────────

pub fn isActive(self: *const Lockdown) bool {
    return self.active and self.phase != .idle and self.phase != .end_unlock;
}

// Password input + box top_title hide during all non-idle phases
// (including end_unlock briefly — caller restores when handling
// end_unlock).
pub fn shouldHidePasswordAndTitle(self: *const Lockdown) bool {
    if (!self.active) return false;
    return switch (self.phase) {
        .idle, .end_unlock => false,
        else => true,
    };
}

// Animation widget (rain) is suppressed by overdraw — see
// drawWidget. Returning true here lets the caller short-circuit
// Matrix's draw() too, saving CPU on the heavy column scan during
// lockdown. (Optional optimisation.)
pub fn shouldSuppressAnimation(self: *const Lockdown) bool {
    return self.isActive();
}

// Other widgets (info_line, attempts, version, mod_hint, clock,
// battery, etc.) — visible after grow_clock completes and a short
// delay into tick, OR when inactive.
pub fn shouldShowOtherWidgets(self: *const Lockdown, now: f64) bool {
    if (!self.active) return true;
    return switch (self.phase) {
        .idle, .end_unlock => true,
        .scramble, .shrink_fade, .blank, .grow_clock => false,
        .tick => (now - self.phase_started) >= GROW_UI_DELAY_SEC,
    };
}

// ─── Public lifecycle ─────────────────────────────────────────────

pub fn start(
    self: *Lockdown,
    anim: LockdownAnim,
    unlock_epoch: f64,
    preview: bool,
    now: f64,
    username: []const u8,
) !void {
    // Idempotent — re-entering start while already active resets the
    // sequence (used by preview action when user mashes Enter).
    self.active = true;
    self.anim = anim;
    self.preview_mode = preview;
    self.phase = .scramble;
    self.phase_started = now;
    self.lockdown_started = now;
    self.last_external_check = now;
    self.scramble_frame = 0;
    self.tick_locked_set = false;

    // Save + flip side-effect state for restore. Done in BOTH
    // preview AND real modes — preview is meant to look identical
    // to the real thing, including the missing password field and
    // box title. end_unlock restores everything regardless of mode.
    if (self.hook_box_top_title) |t| {
        self.saved_top_title = t.*;
        t.* = null;
    }
    if (self.hook_password_should_insert) |p| {
        p.* = false;
    }
    if (self.hook_password_label) |lbl| {
        self.saved_password_label_text = lbl.text;
        lbl.setText("");
    }

    // Preview overrides unlock to a short window so the user sees
    // the full cycle quickly in the debug menu.
    self.unlock_epoch = if (preview)
        now + SCRAMBLE_SEC + SHRINK_SEC + BLANK_SEC + GROW_CLOCK_SEC + PREVIEW_TICK_SEC
    else
        unlock_epoch;

    // Build the faillock probe path once.
    const written = std.fmt.bufPrint(
        &self.faillock_path_buf,
        "/run/faillock/{s}",
        .{username},
    ) catch self.faillock_path_buf[0..0];
    self.faillock_path_len = written.len;

    try self.allocatePerCell(self.buffer.width, self.buffer.height);
    self.snapshotBuffer();

    // Tell Matrix to skip its draw step while we're active.
    if (self.hook_matrix_suppressed) |s| s.* = true;
}

fn allocatePerCell(self: *Lockdown, w: usize, h: usize) !void {
    self.buf_width = w;
    self.buf_height = h;
    const n = w * h;

    if (self.shrink_t0) |s| self.allocator.free(s);
    if (self.shrink_dur) |s| self.allocator.free(s);
    if (self.scramble_t0) |s| self.allocator.free(s);
    if (self.scramble_glyph) |s| self.allocator.free(s);
    if (self.snapshot) |s| self.allocator.free(s);

    self.shrink_t0 = try self.allocator.alloc(u8, n);
    self.shrink_dur = try self.allocator.alloc(u8, n);
    self.scramble_t0 = try self.allocator.alloc(u8, n);
    self.scramble_glyph = try self.allocator.alloc(u21, n);
    self.snapshot = try self.allocator.alloc(Cell, n);

    // Per-cell randomised onset + duration. Full u8 range = 256
    // distinct buckets, so for a 256×72 buffer roughly every cell
    // hits a palette transition at a unique frame — no heartbeat.
    for (self.shrink_t0.?) |*v| v.* = self.buffer.random.int(u8);
    for (self.shrink_dur.?) |*v| v.* = self.buffer.random.int(u8);
    for (self.scramble_t0.?) |*v| v.* = self.buffer.random.int(u8);
    // Initialise scramble_glyph to 0 = "use snapshot".
    for (self.scramble_glyph.?) |*g| g.* = 0;
}

fn snapshotBuffer(self: *Lockdown) void {
    var y: usize = 0;
    const snap = self.snapshot orelse return;
    while (y < self.buf_height) : (y += 1) {
        var x: usize = 0;
        while (x < self.buf_width) : (x += 1) {
            const idx = y * self.buf_width + x;
            snap[idx] = TerminalBuffer.getCell(x, y) orelse
                Cell.init(' ', BG, BG);
        }
    }
}

// Per-frame phase advance. Caller invokes once per frame BEFORE
// widget draws. Returns true if state has just reached end_unlock
// — caller should clear lockout state at that moment.
pub fn update(self: *Lockdown, now: f64) bool {
    if (!self.active or self.phase == .idle) return false;

    const elapsed = now - self.phase_started;
    var new_phase: ?Phase = null;
    switch (self.phase) {
        .idle => {},
        .scramble => if (elapsed >= SCRAMBLE_SEC) {
            new_phase = .shrink_fade;
        },
        .shrink_fade => if (elapsed >= SHRINK_SEC) {
            new_phase = .blank;
        },
        .blank => if (elapsed >= BLANK_SEC) {
            new_phase = .grow_clock;
        },
        .grow_clock => if (elapsed >= GROW_CLOCK_SEC) {
            new_phase = .tick;
        },
        .tick => {
            // Once we've crossed GROW_UI_DELAY_SEC, hand the rain
            // back over to Matrix in locked mode so the user sees
            // sparse-gray drops fall behind the clock + restored
            // widgets. Idempotent via tick_locked_set so we don't
            // hammer the hook every frame.
            if (!self.tick_locked_set and elapsed >= GROW_UI_DELAY_SEC) {
                if (self.hook_matrix_suppressed) |s| s.* = false;
                if (self.hook_matrix_locked) |m| m.* = true;
                self.tick_locked_set = true;
            }
            // External-reset poll.
            if (now - self.last_external_check >= FAILLOCK_POLL_SEC) {
                self.last_external_check = now;
                if (!self.preview_mode and !systemStillLocked(self)) {
                    new_phase = .end_unlock;
                }
            }
            // Internal countdown.
            if (new_phase == null and now >= self.unlock_epoch) {
                new_phase = .end_unlock;
            }
        },
        .end_unlock => {
            // Caller handles the transition out — see main.zig.
            // We do NOT auto-reset to idle; main flips us via finish().
        },
    }
    if (new_phase) |p| {
        // Seamless scramble→shrink: bake the scrambled glyphs into
        // the snapshot so the shrink-fade palette starts from the
        // characters the user just saw, not the originals captured
        // at start(). We CAN'T re-snapshot the back buffer here —
        // renderOneFrame's clearScreen(false) just wiped it at the
        // top of this frame, before our update() ran. The scram[]
        // buffer is what drawScramble actually painted in the
        // previous frame, so copying its codepoints into
        // snapshot[].ch is the deterministic source.
        if (self.phase == .scramble and p == .shrink_fade) {
            self.bakeScrambleIntoSnapshot();
        }
        self.phase = p;
        self.phase_started = now;
        if (p == .end_unlock) return true;
    }
    return false;
}

fn bakeScrambleIntoSnapshot(self: *Lockdown) void {
    const snap = self.snapshot orelse return;
    const scram = self.scramble_glyph orelse return;
    var i: usize = 0;
    while (i < snap.len) : (i += 1) {
        if (scram[i] != 0) snap[i].ch = scram[i];
    }
}

// Caller invokes after handling .end_unlock side-effects (restore
// password input, clear top_title saved value, reset auth_fails).
pub fn finish(self: *Lockdown) void {
    self.active = false;
    self.phase = .idle;
}

// Returns seconds remaining until unlock. Clamps at 0.
pub fn remainingSeconds(self: *const Lockdown, now: f64) i64 {
    if (now >= self.unlock_epoch) return 0;
    const diff = self.unlock_epoch - now;
    return @intFromFloat(@ceil(diff));
}

// ─── Pure helpers (tested) ────────────────────────────────────────

// Convert clock seconds-remaining to MM:SS. Caller-owned buffer
// must be at least 6 bytes for "MM:SS" + NUL. Returns slice into
// buf with the result.
pub fn formatClock(secs_remaining: i64, buf: []u8) []const u8 {
    const s = if (secs_remaining < 0) 0 else secs_remaining;
    const mm: i64 = @divFloor(s, 60);
    const ss: i64 = @mod(s, 60);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ mm, ss }) catch buf[0..0];
}

// Phase math at time `now` given a start epoch — returns which
// phase the lockdown would be in if started at start_epoch. Used
// purely for tests so phase transitions are deterministic.
pub fn phaseAtTime(start_epoch: f64, now: f64, tick_unlock_at: f64) Phase {
    if (now < start_epoch) return .idle;
    const t = now - start_epoch;
    var acc: f64 = 0;
    acc += SCRAMBLE_SEC;
    if (t < acc) return .scramble;
    acc += SHRINK_SEC;
    if (t < acc) return .shrink_fade;
    acc += BLANK_SEC;
    if (t < acc) return .blank;
    acc += GROW_CLOCK_SEC;
    if (t < acc) return .grow_clock;
    if (now < tick_unlock_at) return .tick;
    return .end_unlock;
}

// Per-cell shrink index. Each cell has a random `t0` (start delay,
// 0..255 maps to [0, 0.5*total]) and `dur` (duration, 0..255 maps
// to [0.5*total, 1.5*total]). A cell stays at idx 0 until elapsed
// passes its t0, then progresses through SHRINK_STEPS over its own
// duration. The u8 spread means ~256 distinct schedules within the
// shrink phase — at any frame, each cell is at a unique progress
// point, so the dissolve reads as a live churn instead of all
// cells flipping palette stages in lockstep.
pub fn shrinkIndex(elapsed: f64, total: f64, t0: u8, dur: u8) u8 {
    if (total <= 0) return SHRINK_STEPS - 1;
    const t0_sec = (@as(f64, @floatFromInt(t0)) / 255.0) * 0.5 * total;
    const dur_sec = (0.5 + @as(f64, @floatFromInt(dur)) / 255.0) * total;
    const cell_elapsed = elapsed - t0_sec;
    if (cell_elapsed <= 0) return 0;
    if (cell_elapsed >= dur_sec) return SHRINK_STEPS - 1;
    const frac = cell_elapsed / dur_sec;
    var idx: u8 = @intFromFloat(@floor(frac * @as(f64, SHRINK_STEPS)));
    if (idx >= SHRINK_STEPS) idx = SHRINK_STEPS - 1;
    return idx;
}

// Pick the shrunk glyph for the given index + original codepoint.
// Idx 0/1 → original; later → progressively smaller substitute;
// last → blank.
pub fn shrinkGlyph(original: u21, idx: u8) u21 {
    if (idx >= SHRINK_STEPS) return ' ';
    const palette_cp = SHRINK_GLYPHS[idx];
    if (palette_cp == 0) return original;
    return palette_cp;
}

// Grow glyph for clock — symmetric inverse of shrink. Frame 0 is
// smallest (⋅), final frame is the target digit. Steps: ⋅ → · →
// ◦ → ◌ → dim target → bright target.
pub fn growGlyph(target: u21, frame: u8, total_frames: u8) u21 {
    // total_frames effectively spans 0..total. We pick a glyph
    // based on which "stage" we're in.
    if (total_frames == 0) return target;
    const stage = @as(u32, frame) * 6 / @as(u32, total_frames);
    return switch (stage) {
        0 => 0x22C5, // ⋅
        1 => 0x00B7, // ·
        2 => 0x25E6, // ◦
        3 => 0x25CC, // ◌
        4 => target, // dim
        else => target, // bright
    };
}

// Lerp two RGB colors with alpha-byte preserved from `from`.
pub fn lerpColor(from: u32, to: u32, t: f64) u32 {
    var tc = t;
    if (tc < 0) tc = 0;
    if (tc > 1) tc = 1;
    const a: u32 = from & 0xFF000000;
    const fr: i32 = @intCast((from >> 16) & 0xFF);
    const fg: i32 = @intCast((from >> 8) & 0xFF);
    const fb: i32 = @intCast(from & 0xFF);
    const tr: i32 = @intCast((to >> 16) & 0xFF);
    const tg: i32 = @intCast((to >> 8) & 0xFF);
    const tb: i32 = @intCast(to & 0xFF);
    const r: u32 = @intCast(fr + @as(i32, @intFromFloat((@as(f64, @floatFromInt(tr - fr))) * tc)));
    const g: u32 = @intCast(fg + @as(i32, @intFromFloat((@as(f64, @floatFromInt(tg - fg))) * tc)));
    const b: u32 = @intCast(fb + @as(i32, @intFromFloat((@as(f64, @floatFromInt(tb - fb))) * tc)));
    return a | (r << 16) | (g << 8) | b;
}

// Compute the color for a shrinking cell at shrink_idx (0..STEPS).
// Fades from `original` → MID_GRAY at idx ~3 → DARK_GRAY at idx
// ~5 → BG at the blank step.
pub fn colorForShrink(original: u32, idx: u8) u32 {
    if (idx <= 1) {
        // Slight cool fade so the user senses the color shift early.
        return lerpColor(original, MID_GRAY, @as(f64, @floatFromInt(idx)) * 0.25);
    }
    if (idx <= 3) {
        const t = (@as(f64, @floatFromInt(idx)) - 1.0) / 2.0; // 0..1
        return lerpColor(original, MID_GRAY, 0.25 + 0.5 * t);
    }
    if (idx <= 5) {
        const t = (@as(f64, @floatFromInt(idx)) - 3.0) / 2.0; // 0..1
        return lerpColor(MID_GRAY, DARK_GRAY, t);
    }
    return BG;
}

// Color for clock grow stage. Frame 0..total-2 use dim gray; the
// final stage uses CLOCK_BRIGHT for a "snap into focus" feel.
pub fn colorForGrow(frame: u8, total_frames: u8) u32 {
    if (total_frames == 0) return CLOCK_BRIGHT;
    const stage = @as(u32, frame) * 6 / @as(u32, total_frames);
    return switch (stage) {
        0, 1 => DARK_GRAY,
        2, 3 => MID_GRAY,
        4 => CLOCK_DIM,
        else => CLOCK_BRIGHT,
    };
}

// ─── Persistence ─────────────────────────────────────────────────

const PREFS_PATH: []const u8 = "/var/lib/ly/lockdown-prefs";

pub fn savePrefs(self: *const Lockdown, io: std.Io) void {
    saveImpl(self, io) catch {};
}

fn saveImpl(self: *const Lockdown, io: std.Io) !void {
    std.Io.Dir.cwd().createDirPath(io, "/var/lib/ly") catch {};
    var file = try std.Io.Dir.cwd().createFile(
        io,
        PREFS_PATH,
        .{ .permissions = .fromMode(0o600) },
    );
    defer file.close(io);
    var buf: [128]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print("lockout_animation={d}\n", .{@intFromEnum(self.selected_anim)});
    try w.interface.flush();
}

pub fn loadPrefs(self: *Lockdown, io: std.Io) void {
    loadImpl(self, io) catch {};
}

fn loadImpl(self: *Lockdown, io: std.Io) !void {
    var file = try std.Io.Dir.cwd().openFile(io, PREFS_PATH, .{ .mode = .read_only });
    defer file.close(io);
    var read_buf: [256]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var r = &fr.interface;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch break;
        const trimmed = std.mem.trimEnd(u8, line, "\n\r ");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq];
        const val = trimmed[eq + 1 ..];
        if (std.mem.eql(u8, key, "lockout_animation")) {
            const v = std.fmt.parseInt(u8, val, 10) catch continue;
            self.selected_anim = LockdownAnim.fromInt(v);
        }
    }
}

// ─── External-reset probe ────────────────────────────────────────

fn systemStillLocked(self: *Lockdown) bool {
    // The pam_faillock tally file lives at /run/faillock/<user>.
    // `faillock --reset` removes the file outright, so existence
    // check is sufficient. `faillock --user X` reads the file
    // straight from there; matching its contract keeps us in lockstep
    // with `--reset`.
    if (self.faillock_path_len == 0) return true;
    // Ensure null-terminated for the C syscall.
    if (self.faillock_path_len >= self.faillock_path_buf.len) return true;
    self.faillock_path_buf[self.faillock_path_len] = 0;
    const cpath: [*:0]const u8 = @ptrCast(&self.faillock_path_buf[0]);
    const rc = std.posix.system.access(cpath, std.posix.F_OK);
    return rc == 0;
}

// ─── Drawing ─────────────────────────────────────────────────────

// Convert ly's TimeOfDay (seconds + microseconds split) to a single
// f64 for phase math.
pub fn todToF64(t: TimeOfDay) f64 {
    return @as(f64, @floatFromInt(t.seconds)) +
        @as(f64, @floatFromInt(t.microseconds)) / 1_000_000.0;
}

fn draw(self: *Lockdown, buf: *TerminalBuffer) void {
    const now = self.last_now;
    switch (self.phase) {
        .idle, .end_unlock => {},
        .scramble => self.drawScramble(buf),
        .shrink_fade => self.drawShrinkFade(buf, now),
        .blank => self.drawBlank(buf),
        .grow_clock => {
            self.drawBlank(buf);
            self.drawClock(buf, now, true);
        },
        .tick => {
            // During the first GROW_UI_DELAY_SEC of tick we still
            // full-blank — only the clock should be visible. After
            // that delay we shrink the blanked area to a tight
            // RECTANGLE around the clock so the locked-mode rain
            // (Matrix sparse-gray) can fall across the rest of
            // those rows uninterrupted.
            const tick_elapsed = now - self.phase_started;
            if (tick_elapsed < GROW_UI_DELAY_SEC) {
                self.drawBlank(buf);
            } else {
                const band = self.clockBand(buf);
                const text_w: usize = 5; // "MM:SS"
                const pad: usize = 2;    // padding inside the rect
                const rx0 = if (band.cx >= pad) band.cx - pad else 0;
                const rx1 = @min(band.cx + text_w + pad, buf.width);
                self.drawBlankRect(buf, rx0, band.y0, rx1, band.y1);
            }
            self.drawClock(buf, now, false);
        },
    }
}

// Locate the clock band rows. Anchored to box top when the hook is
// attached so the clock sits 3 rows above the login box; falls back
// to screen vertical centre otherwise. The band spans cy-1..cy+1 so
// the accent dashes above and below the clock are kept blank too.
fn clockBand(self: *const Lockdown, buf: *TerminalBuffer) struct { y0: usize, y1: usize, cy: usize, cx: usize, cw: usize } {
    const text_w: usize = 5; // "MM:SS"
    var cy: usize = buf.height / 2;
    var cx: usize = if (buf.width > text_w) (buf.width - text_w) / 2 else 0;
    var cw: usize = buf.width;
    if (self.hook_box) |b| {
        // box.left_pos.y is the row of the interior (one below the
        // top border). The border is at y-1. Place clock at y-3 so
        // there's a clear gap between clock and box, and the accent
        // dash above (cy-1) doesn't overdraw the border itself.
        if (b.left_pos.y >= 3) cy = b.left_pos.y - 3;
        cw = b.width + 2; // box width + borders
        const box_centre = b.left_pos.x + b.width / 2;
        cx = if (box_centre >= text_w / 2) box_centre - text_w / 2 else 0;
    }
    const y0: usize = if (cy >= 1) cy - 1 else 0;
    const y1: usize = if (cy + 2 < buf.height) cy + 2 else buf.height;
    return .{ .y0 = y0, .y1 = y1, .cy = cy, .cx = cx, .cw = cw };
}

fn drawBlank(self: *Lockdown, buf: *TerminalBuffer) void {
    _ = self;
    var y: usize = 0;
    while (y < buf.height) : (y += 1) {
        TerminalBuffer.drawCharMultiple(' ', 0, y, buf.width, BG, BG);
    }
}

fn drawBlankBand(self: *Lockdown, buf: *TerminalBuffer, y0: usize, y1: usize) void {
    _ = self;
    var y: usize = y0;
    while (y < y1 and y < buf.height) : (y += 1) {
        TerminalBuffer.drawCharMultiple(' ', 0, y, buf.width, BG, BG);
    }
}

fn drawBlankRect(self: *Lockdown, buf: *TerminalBuffer, x0: usize, y0: usize, x1: usize, y1: usize) void {
    _ = self;
    var y: usize = y0;
    while (y < y1 and y < buf.height) : (y += 1) {
        const w = if (x1 > x0) x1 - x0 else 0;
        if (w > 0) TerminalBuffer.drawCharMultiple(' ', x0, y, w, BG, BG);
    }
}

fn drawScramble(self: *Lockdown, buf: *TerminalBuffer) void {
    const snap = self.snapshot orelse return;
    const scram = self.scramble_glyph orelse return;
    const t0s = self.scramble_t0 orelse return;
    const elapsed = self.last_now - self.phase_started;
    self.scramble_frame +%= 1;

    var y: usize = 0;
    while (y < self.buf_height) : (y += 1) {
        var x: usize = 0;
        while (x < self.buf_width) : (x += 1) {
            const idx = y * self.buf_width + x;
            const orig = snap[idx];
            if (orig.ch == 0 or orig.ch == ' ') continue;
            // Per-cell onset spread across [0, 0.7*SCRAMBLE_SEC].
            // Until elapsed crosses the cell's t0 we keep the
            // pristine snapshot glyph so the user perceives the
            // ORIGINAL characters at frame 0 and the scramble
            // building up cell-by-cell rather than appearing as
            // a flicker-everywhere block.
            const t0_sec = (@as(f64, @floatFromInt(t0s[idx])) / 255.0) * 0.7 * SCRAMBLE_SEC;
            if (elapsed < t0_sec) {
                Cell.init(orig.ch, orig.fg, orig.bg).put(x, y);
                continue;
            }
            // Cycle the glyph every ~4 frames after onset so the
            // scrambled cells feel alive rather than freezing on
            // their first random pick. XOR with idx-low-bits stags
            // the cycle phase across cells.
            const cycle_phase: u32 = @as(u32, @truncate(idx)) & 0x7;
            if (scram[idx] == 0 or (self.scramble_frame +% cycle_phase) % 4 == 0) {
                scram[idx] = SCRAMBLE_POOL[buf.random.uintLessThan(usize, SCRAMBLE_POOL.len)];
            }
            Cell.init(@intCast(scram[idx]), orig.fg, orig.bg).put(x, y);
        }
    }
}

fn drawShrinkFade(self: *Lockdown, buf: *TerminalBuffer, now: f64) void {
    const snap = self.snapshot orelse return;
    const t0s = self.shrink_t0 orelse return;
    const durs = self.shrink_dur orelse return;
    const elapsed = now - self.phase_started;
    var y: usize = 0;
    while (y < self.buf_height) : (y += 1) {
        var x: usize = 0;
        while (x < self.buf_width) : (x += 1) {
            const idx = y * self.buf_width + x;
            const orig = snap[idx];
            if (orig.ch == 0 or orig.ch == ' ') {
                Cell.init(' ', BG, BG).put(x, y);
                continue;
            }
            const si = shrinkIndex(elapsed, SHRINK_SEC, t0s[idx], durs[idx]);
            const glyph = shrinkGlyph(@intCast(orig.ch), si);
            const fg = colorForShrink(orig.fg, si);
            Cell.init(@intCast(glyph), fg, BG).put(x, y);
        }
        _ = buf;
    }
}

fn drawClock(self: *Lockdown, buf: *TerminalBuffer, now: f64, growing: bool) void {
    var buf6: [16]u8 = undefined;
    const secs = self.remainingSeconds(now);
    const text = formatClock(secs, &buf6);

    const band = self.clockBand(buf);
    const tw = text.len;
    if (buf.width < tw + 4 or buf.height < 4) return;
    const cx = band.cx;
    const cy = band.cy;

    if (growing) {
        const elapsed = now - self.phase_started;
        const frac = if (GROW_CLOCK_SEC <= 0) 1.0 else elapsed / GROW_CLOCK_SEC;
        const frame: u8 = @intFromFloat(@min(5.0, @max(0.0, frac * 5.0)));
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const target: u21 = @intCast(text[i]);
            const cp = growGlyph(target, frame, 5);
            const fg = colorForGrow(frame, 5);
            Cell.init(@intCast(cp), fg, BG).put(cx + i, cy);
        }
    } else {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const ch: u21 = @intCast(text[i]);
            Cell.init(@intCast(ch), CLOCK_BRIGHT, BG).put(cx + i, cy);
        }
        // Underline / overline accent so it reads as "this is the
        // time you're waiting for, not just stray text". 1-row
        // bracket above and below the digit row.
        const dash_fg: u32 = CLOCK_DIM;
        var j: usize = 0;
        while (j < tw) : (j += 1) {
            if (cy >= 1) Cell.init(0x2500, dash_fg, BG).put(cx + j, cy - 1);
            if (cy + 1 < buf.height) Cell.init(0x2500, dash_fg, BG).put(cx + j, cy + 1);
        }
    }
}

// ─── Tests (pure helpers only — rendering is visual-diffed) ───────

const testing = std.testing;

test "formatClock pads MM:SS" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("00:00", formatClock(0, &buf));
    try testing.expectEqualStrings("00:01", formatClock(1, &buf));
    try testing.expectEqualStrings("00:59", formatClock(59, &buf));
    try testing.expectEqualStrings("01:00", formatClock(60, &buf));
    try testing.expectEqualStrings("09:59", formatClock(599, &buf));
    try testing.expectEqualStrings("10:00", formatClock(600, &buf));
    try testing.expectEqualStrings("99:59", formatClock(5999, &buf));
}

test "formatClock clamps negatives to 00:00" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("00:00", formatClock(-1, &buf));
    try testing.expectEqualStrings("00:00", formatClock(-9999, &buf));
}

test "phaseAtTime walks every phase in order" {
    const t0: f64 = 1000.0;
    const tick_until: f64 = t0 + 100.0; // arbitrary far future
    try testing.expectEqual(Phase.idle, phaseAtTime(t0, 999.0, tick_until));
    try testing.expectEqual(Phase.scramble, phaseAtTime(t0, t0 + 0.1, tick_until));
    try testing.expectEqual(Phase.scramble, phaseAtTime(t0, t0 + SCRAMBLE_SEC - 0.01, tick_until));
    try testing.expectEqual(Phase.shrink_fade, phaseAtTime(t0, t0 + SCRAMBLE_SEC + 0.01, tick_until));
    try testing.expectEqual(Phase.blank, phaseAtTime(t0, t0 + SCRAMBLE_SEC + SHRINK_SEC + 0.01, tick_until));
    try testing.expectEqual(Phase.grow_clock, phaseAtTime(t0, t0 + SCRAMBLE_SEC + SHRINK_SEC + BLANK_SEC + 0.01, tick_until));
    try testing.expectEqual(Phase.tick, phaseAtTime(t0, t0 + SCRAMBLE_SEC + SHRINK_SEC + BLANK_SEC + GROW_CLOCK_SEC + 0.01, tick_until));
    try testing.expectEqual(Phase.end_unlock, phaseAtTime(t0, tick_until + 0.01, tick_until));
}

test "shrinkIndex with t0=0,dur=128 ramps 0..STEPS-1" {
    // dur=128 → dur_sec = (0.5 + 128/255) * 2.0 = ~2.0s
    // t0=0 → no delay
    try testing.expectEqual(@as(u8, 0), shrinkIndex(0.0, 2.0, 0, 128));
    try testing.expectEqual(@as(u8, 0), shrinkIndex(0.0001, 2.0, 0, 128));
    // At end of dur, should hit STEPS-1.
    try testing.expectEqual(SHRINK_STEPS - 1, shrinkIndex(3.0, 2.0, 0, 128));
    // Midpoint hits middle of palette.
    const mid = shrinkIndex(1.0, 2.0, 0, 128);
    try testing.expect(mid >= 2 and mid <= 4);
}

test "shrinkIndex t0 delays start" {
    // Cell with t0=255 waits longer to start shrinking than t0=0.
    const no_t0 = shrinkIndex(0.5, 2.0, 0, 128);
    const with_t0 = shrinkIndex(0.5, 2.0, 255, 128);
    try testing.expect(with_t0 <= no_t0);
    // t0=255 → t0_sec = 1.0s, so at elapsed=0.5 cell hasn't started.
    try testing.expectEqual(@as(u8, 0), with_t0);
}

test "shrinkIndex dur affects rate" {
    // Cell with dur=0 (fastest, 0.5*total) reaches blank earlier
    // than cell with dur=255 (slowest, 1.5*total).
    const fast = shrinkIndex(1.0, 2.0, 0, 0);
    const slow = shrinkIndex(1.0, 2.0, 0, 255);
    try testing.expect(fast >= slow);
}

test "shrinkGlyph maps idx to palette" {
    try testing.expectEqual(@as(u21, 'A'), shrinkGlyph('A', 0));
    try testing.expectEqual(@as(u21, 'A'), shrinkGlyph('A', 1));
    try testing.expectEqual(@as(u21, 0x25CC), shrinkGlyph('A', 2));
    try testing.expectEqual(@as(u21, 0x25E6), shrinkGlyph('A', 3));
    try testing.expectEqual(@as(u21, 0x00B7), shrinkGlyph('A', 4));
    try testing.expectEqual(@as(u21, 0x22C5), shrinkGlyph('A', 5));
    try testing.expectEqual(@as(u21, ' '), shrinkGlyph('A', 6));
    // Past end clamps to space.
    try testing.expectEqual(@as(u21, ' '), shrinkGlyph('A', 99));
}

test "growGlyph reverses to target by final stage" {
    try testing.expectEqual(@as(u21, 0x22C5), growGlyph('5', 0, 5));
    try testing.expectEqual(@as(u21, '5'), growGlyph('5', 5, 5));
    // Mid-frame goes through small-circle stages.
    const mid = growGlyph('5', 2, 5);
    try testing.expect(mid == 0x25E6 or mid == 0x00B7);
}

test "lerpColor endpoints + midpoint" {
    try testing.expectEqual(@as(u32, 0xFF000000), lerpColor(0xFF000000, 0xFFFFFFFF, 0.0));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), lerpColor(0xFF000000, 0xFFFFFFFF, 1.0));
    const mid = lerpColor(0xFF000000, 0xFF808080, 0.5);
    // ~0x40 each channel, alpha preserved.
    try testing.expectEqual(@as(u32, 0xFF000000), mid & 0xFF000000);
    const r = (mid >> 16) & 0xFF;
    try testing.expect(r >= 0x3F and r <= 0x41);
}

test "colorForShrink hits gray midway and BG at end" {
    const orig: u32 = 0x0000FF66; // ly's matrix green
    const c0 = colorForShrink(orig, 0);
    try testing.expectEqual(orig, c0);
    const c3 = colorForShrink(orig, 3);
    // ~mid_gray.
    const r3 = (c3 >> 16) & 0xFF;
    try testing.expect(r3 >= 0x40 and r3 <= 0x90);
    const c6 = colorForShrink(orig, 6);
    try testing.expectEqual(@as(u32, BG), c6);
}

test "LockdownAnim cycle round-trips" {
    try testing.expectEqual(LockdownAnim.scramble_shrink, LockdownAnim.legacy_sparse.cycle());
    try testing.expectEqual(LockdownAnim.legacy_sparse, LockdownAnim.scramble_shrink.cycle());
}

test "remainingSeconds clamps + rounds up" {
    var ld: Lockdown = .{ .allocator = testing.allocator, .buffer = undefined };
    ld.unlock_epoch = 100.0;
    try testing.expectEqual(@as(i64, 0), ld.remainingSeconds(100.0));
    try testing.expectEqual(@as(i64, 0), ld.remainingSeconds(150.0));
    try testing.expectEqual(@as(i64, 1), ld.remainingSeconds(99.5));
    try testing.expectEqual(@as(i64, 10), ld.remainingSeconds(90.0));
    try testing.expectEqual(@as(i64, 600), ld.remainingSeconds(-500.0));
}
