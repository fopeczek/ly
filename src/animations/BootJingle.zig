// Boot-jingle silence-prompt overlay. Runs once at greeter init:
//
//   react_window  ~1.8s.  Centred prompt + shrinking countdown bar.
//                 User can hold EITHER LEFT or RIGHT shift during
//                 this window to silence the jingle. Shifts are pure
//                 modifier keys so holding doesn't spam the password
//                 field (unlike SPACE, which used to). L and R are
//                 detected independently — the prompt shows
//                 distinctly which one(s) you're holding.
//
//   <decision>    At REACT_SEC, ioctl(EVIOCGKEY) on each non-keyd-
//                 virtual evdev device returns the kernel's live
//                 KEY_LEFTSHIFT / KEY_RIGHTSHIFT bitmap. Either one
//                 set → ack_mute; both unset → spawn jingle launcher
//                 and enter ack_play.
//
//   ack_mute /    ~0.6s. ack_mute shows a brief "MUTED" confirmation
//   ack_play      so the user knows their input registered. ack_play
//                 is silent (audio is its own feedback).
//
//   done          Deactivate the widget and unsuppress matrix rain
//                 so the normal greeter takes over.
//
// Live feedback: drawReactPrompt re-polls L and R state every frame
// and switches the prompt's text + colour the moment a shift is
// held — the user sees the gate close at their fingertip without
// waiting for the probe at REACT_SEC.
//
// The launcher script (alterra-jingle-play) is invoked via Child
// .spawnAndWait. That sounds blocking — it isn't, because the script
// daemonises mpv (nohup … & disown ; exit 0) and bash exits in <1ms.
// We get a clean reap with no zombie and no UI stall.

const std = @import("std");
const ly_ui = @import("ly-ui");
const Cell = ly_ui.Cell;
const TerminalBuffer = ly_ui.TerminalBuffer;
const Widget = ly_ui.Widget;
const ly_core = ly_ui.ly_core;
const interop = ly_core.interop;
const TimeOfDay = interop.TimeOfDay;

const InputState = @import("../InputState.zig");

const BootJingle = @This();

// ─── Public types ─────────────────────────────────────────────────

pub const Phase = enum {
    idle,
    react_window,
    ack_mute,
    ack_play,
    done,
};

// ─── Tunables ─────────────────────────────────────────────────────

pub const REACT_SEC: f64 = 1.8;
pub const ACK_SEC: f64 = 0.6;

pub const JINGLE_LAUNCHER: []const u8 = "/usr/local/bin/alterra-jingle-play";

const FG_BRIGHT: u32 = 0x01FFFFFF;
const FG_DIM: u32 = 0x01808080;
const FG_ACCENT: u32 = 0x0140C0FF;     // cyan — neutral / not-held bar
const FG_HOLD_HI: u32 = 0x01FF5050;    // bright red — armed to play
const FG_HOLD_LO: u32 = 0x01D08080;    // dim red — "keep holding"
const BG: u32 = 0x00000000;

// ─── State ────────────────────────────────────────────────────────

allocator: std.mem.Allocator,
buffer: *TerminalBuffer,
io: ?std.Io,
input_state: ?*const InputState,
phase: Phase,
phase_started: f64,
last_now: f64,
active: bool,
spawned: bool,
// User-toggleable kill-switch. When false, the boot-time start()
// is skipped entirely (no prompt, no audio). Persisted via the
// Lockdown-style /var/lib/ly/boot-jingle-prefs file.
enabled: bool,
hook_matrix_suppressed: ?*bool,
instance: ?Widget,

pub fn init(allocator: std.mem.Allocator, buffer: *TerminalBuffer) BootJingle {
    return .{
        .allocator = allocator,
        .buffer = buffer,
        .io = null,
        .input_state = null,
        .phase = .idle,
        .phase_started = 0,
        .last_now = 0,
        .active = false,
        .spawned = false,
        .enabled = true,
        .hook_matrix_suppressed = null,
        .instance = null,
    };
}

pub fn attachHooks(
    self: *BootJingle,
    io: std.Io,
    input_state: *const InputState,
    matrix_suppressed: *bool,
) void {
    self.io = io;
    self.input_state = input_state;
    self.hook_matrix_suppressed = matrix_suppressed;
}

pub fn start(self: *BootJingle, now: f64) void {
    self.active = true;
    self.phase = .react_window;
    self.phase_started = now;
    self.last_now = now;
    self.spawned = false;
    if (self.hook_matrix_suppressed) |s| s.* = true;
}

// Pure-function phase-transition rule. Returned phase is the one
// to enter; null = no transition. For .react_window the rule
// returns .ack_mute as a sentinel meaning "decision time" —
// transitionTo() flips it to .ack_play if SPACE wasn't held.
pub fn dueTransition(current: Phase, elapsed: f64) ?Phase {
    return switch (current) {
        .idle, .done => null,
        .react_window => if (elapsed >= REACT_SEC) .ack_mute else null,
        .ack_mute, .ack_play => if (elapsed >= ACK_SEC) .done else null,
    };
}

pub fn update(self: *BootJingle, now: f64) bool {
    if (!self.active or self.phase == .idle or self.phase == .done) return false;
    self.last_now = now;
    const elapsed = now - self.phase_started;
    if (dueTransition(self.phase, elapsed)) |target| {
        return self.transitionTo(target, now);
    }
    return false;
}

fn transitionTo(self: *BootJingle, target: Phase, now: f64) bool {
    var next = target;
    if (self.phase == .react_window) {
        // Default-plays semantics: holding a shift MUTES the jingle.
        // No shift held = audio plays. The held state is visualised
        // in red (drawReactPrompt) so it reads as a warning/stop
        // indicator — "you're preventing the default action".
        const muted = self.anyShiftHeld();
        next = if (muted) .ack_mute else .ack_play;
        if (!muted) self.spawnJingle();
    }
    self.phase = next;
    self.phase_started = now;
    if (next == .done) {
        self.active = false;
        if (self.hook_matrix_suppressed) |s| s.* = false;
        return true;
    }
    return false;
}

fn anyShiftHeld(self: *const BootJingle) bool {
    const is = self.input_state orelse return false;
    return is.lshiftHeldNow() or is.rshiftHeldNow();
}

fn spawnJingle(self: *BootJingle) void {
    if (self.spawned) return;
    self.spawned = true;
    self.execLauncher();
}

// Public sound-only trigger for the Settings → Bootup test action.
// Not gated by spawned flag — user can fire repeatedly to audition.
pub fn playSoundOnly(self: *BootJingle) void {
    self.execLauncher();
}

fn execLauncher(self: *BootJingle) void {
    const io = self.io orelse return;
    // spawn() + wait() is non-blocking in practice because the
    // launcher script daemonises mpv via nohup+disown and bash
    // exits immediately. wait() reaps the bash exit so there's no
    // zombie; mpv is reparented to init and lives on.
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{JINGLE_LAUNCHER},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch return;
}

// ─── Persistence ──────────────────────────────────────────────────

const PREFS_PATH: []const u8 = "/var/lib/ly/boot-jingle-prefs";

pub fn savePrefs(self: *const BootJingle, io: std.Io) void {
    saveImpl(self, io) catch {};
}

fn saveImpl(self: *const BootJingle, io: std.Io) !void {
    std.Io.Dir.cwd().createDirPath(io, "/var/lib/ly") catch {};
    var file = try std.Io.Dir.cwd().createFile(
        io,
        PREFS_PATH,
        .{ .permissions = .fromMode(0o600) },
    );
    defer file.close(io);
    var buf: [32]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print("enabled={d}\n", .{@as(u8, if (self.enabled) 1 else 0)});
    try w.interface.flush();
}

pub fn loadPrefs(self: *BootJingle, io: std.Io) void {
    loadImpl(self, io) catch {};
}

fn loadImpl(self: *BootJingle, io: std.Io) !void {
    var file = try std.Io.Dir.cwd().openFile(io, PREFS_PATH, .{ .mode = .read_only });
    defer file.close(io);
    var read_buf: [128]u8 = undefined;
    var fr = file.reader(io, &read_buf);
    var r = &fr.interface;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch break;
        const trimmed = std.mem.trimEnd(u8, line, "\n\r ");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq];
        const val = trimmed[eq + 1 ..];
        if (std.mem.eql(u8, key, "enabled")) {
            const v = std.fmt.parseInt(u8, val, 10) catch continue;
            self.enabled = (v != 0);
        }
    }
}

// ─── Widget interface ─────────────────────────────────────────────

pub fn widget(self: *BootJingle) *Widget {
    if (self.instance) |*w| return w;
    self.instance = Widget.init(
        "BootJingle",
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

fn reallocImpl(_: *BootJingle) !void {}

fn updateWidget(self: *BootJingle, _: *anyopaque) !void {
    if (!self.active or self.phase == .idle) return;
    const t = interop.getTimeOfDay() catch return;
    _ = self.update(todToF64(t));
}

fn drawWidget(self: *BootJingle) void {
    if (!self.active or self.phase == .idle or self.phase == .done) return;
    self.draw();
}

pub fn isActive(self: *const BootJingle) bool {
    return self.active and self.phase != .idle and self.phase != .done;
}

// Other widgets (login box, info_line, version, etc.) should be
// hidden while the boot intro is on so the prompt is the only
// visible element. main.zig polls this gate before adding the
// regular widget layers to the frame.
pub fn shouldSuppressGreeter(self: *const BootJingle) bool {
    return self.isActive();
}

fn todToF64(t: TimeOfDay) f64 {
    return @as(f64, @floatFromInt(t.seconds)) +
        @as(f64, @floatFromInt(t.microseconds)) / 1_000_000.0;
}

// ─── Drawing ──────────────────────────────────────────────────────

fn draw(self: *BootJingle) void {
    const buf = self.buffer;

    // Black-out the screen — the prompt should be the only thing
    // showing during the intro.
    var y: usize = 0;
    while (y < buf.height) : (y += 1) {
        TerminalBuffer.drawCharMultiple(' ', 0, y, buf.width, BG, BG);
    }

    switch (self.phase) {
        .react_window => self.drawReactPrompt(),
        .ack_mute => self.drawAckMute(),
        .ack_play, .done, .idle => {},
    }
}

fn drawReactPrompt(self: *BootJingle) void {
    const buf = self.buffer;
    const cx = buf.width / 2;
    const cy = buf.height / 2;

    // Live held-state poll. Re-queried every frame so the user sees
    // the gate close the instant they touch a shift.
    const l_held: bool = if (self.input_state) |is| is.lshiftHeldNow() else false;
    const r_held: bool = if (self.input_state) |is| is.rshiftHeldNow() else false;
    const any_held = l_held or r_held;

    // Two visual modes:
    //   not held → cyan bar drains, dim "HOLD … for silence" framing
    //   held     → red bar pinned full, "HOLDING" + which shift(s)
    if (any_held) {
        drawCentred("✓ HOLDING ✓", cx, cy - 3, FG_HOLD_HI);
        const key_label: []const u8 = if (l_held and r_held)
            "BOTH SHIFTS"
        else if (l_held)
            "LEFT SHIFT"
        else
            "RIGHT SHIFT";
        drawCentred(key_label, cx, cy - 1, FG_HOLD_HI);
        drawCentred("keep holding...", cx, cy + 1, FG_HOLD_LO);
    } else {
        drawCentred("── HOLD ──", cx, cy - 3, FG_DIM);
        drawCentred("LEFT or RIGHT SHIFT", cx, cy - 1, FG_BRIGHT);
        drawCentred("for silence", cx, cy + 1, FG_DIM);
    }

    // Countdown bar. Cyan-draining when not held; pinned solid red
    // when held (gate is closed — keep holding until the bar empties
    // since the probe checks state at REACT_SEC).
    const elapsed = self.last_now - self.phase_started;
    const bar_w: usize = 24;
    const remain = @max(@as(f64, 0.0), @min(@as(f64, 1.0), 1.0 - elapsed / REACT_SEC));
    const filled: usize = if (any_held) bar_w else @intFromFloat(remain * @as(f64, @floatFromInt(bar_w)));
    const bar_x: usize = if (cx >= bar_w / 2) cx - bar_w / 2 else 0;
    const bar_y = cy + 3;
    var k: usize = 0;
    while (k < bar_w) : (k += 1) {
        const ch: u32 = if (k < filled) '█' else '░';
        const fg: u32 = if (any_held)
            FG_HOLD_HI
        else if (k < filled)
            FG_ACCENT
        else
            FG_DIM;
        TerminalBuffer.drawCharMultiple(ch, bar_x + k, bar_y, 1, fg, BG);
    }
}

fn drawAckMute(self: *BootJingle) void {
    const buf = self.buffer;
    drawCentred("── MUTED ──", buf.width / 2, buf.height / 2, FG_HOLD_HI);
}

fn drawCentred(text: []const u8, cx: usize, y: usize, fg: u32) void {
    const w = TerminalBuffer.strWidth(text);
    const x: usize = if (cx >= w / 2) cx - w / 2 else 0;
    TerminalBuffer.drawText(text, x, y, fg, BG);
}

// ─── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "dueTransition: react_window completes at REACT_SEC" {
    try testing.expectEqual(@as(?Phase, null), dueTransition(.react_window, 0.0));
    try testing.expectEqual(@as(?Phase, null), dueTransition(.react_window, REACT_SEC - 0.001));
    try testing.expectEqual(@as(?Phase, .ack_mute), dueTransition(.react_window, REACT_SEC));
    try testing.expectEqual(@as(?Phase, .ack_mute), dueTransition(.react_window, REACT_SEC + 0.5));
}

test "dueTransition: ack phases end at ACK_SEC" {
    try testing.expectEqual(@as(?Phase, null), dueTransition(.ack_mute, ACK_SEC - 0.001));
    try testing.expectEqual(@as(?Phase, .done), dueTransition(.ack_mute, ACK_SEC));
    try testing.expectEqual(@as(?Phase, .done), dueTransition(.ack_play, ACK_SEC + 1.0));
}

test "dueTransition: idle and done are terminal" {
    try testing.expectEqual(@as(?Phase, null), dueTransition(.idle, 999.0));
    try testing.expectEqual(@as(?Phase, null), dueTransition(.done, 999.0));
}

test "start resets state correctly" {
    var bj = init(testing.allocator, undefined);
    bj.start(42.5);
    try testing.expect(bj.active);
    try testing.expectEqual(@as(Phase, .react_window), bj.phase);
    try testing.expectEqual(@as(f64, 42.5), bj.phase_started);
    try testing.expect(!bj.spawned);
}

test "isActive reflects active+phase combination" {
    var bj = init(testing.allocator, undefined);
    try testing.expect(!bj.isActive());
    bj.start(0.0);
    try testing.expect(bj.isActive());
    bj.phase = .done;
    try testing.expect(!bj.isActive());
    bj.phase = .ack_mute;
    try testing.expect(bj.isActive());
    bj.active = false;
    try testing.expect(!bj.isActive());
}

test "update before REACT_SEC does not transition" {
    var bj = init(testing.allocator, undefined);
    bj.start(100.0);
    const transitioned = bj.update(100.5);
    try testing.expect(!transitioned);
    try testing.expectEqual(@as(Phase, .react_window), bj.phase);
}

test "update past REACT_SEC transitions to ack_play when no shift held (default)" {
    var bj = init(testing.allocator, undefined);
    bj.start(100.0);
    // No input_state attached → anyShiftHeld returns false →
    // default-plays semantics → ack_play. Pre-set spawned so the
    // launcher isn't actually exec'd during `zig build test`.
    bj.spawned = true;
    _ = bj.update(100.0 + REACT_SEC + 0.001);
    try testing.expectEqual(@as(Phase, .ack_play), bj.phase);
}

test "transitionTo .done clears active and unsuppresses matrix" {
    var bj = init(testing.allocator, undefined);
    var suppressed: bool = false;
    bj.hook_matrix_suppressed = &suppressed;
    bj.start(0.0);
    try testing.expect(suppressed); // start() set it
    bj.phase = .ack_play;
    bj.spawned = true; // skip real spawn (already past react_window anyway)
    _ = bj.update(ACK_SEC + 0.1);
    try testing.expectEqual(@as(Phase, .done), bj.phase);
    try testing.expect(!bj.active);
    try testing.expect(!suppressed);
}
