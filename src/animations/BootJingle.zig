// Boot-jingle silence-prompt overlay. Runs once at greeter init:
//
//   react_window  ~1.8s.  Centred prompt + shrinking countdown bar.
//                 User can hold SPACE during this window to silence
//                 the jingle.
//
//   <decision>    At REACT_SEC, ioctl(EVIOCGKEY) on every open evdev
//                 device asks the kernel "is SPACE currently down?".
//                 If yes → ack_mute; if no → spawn jingle launcher
//                 and enter ack_play.
//
//   ack_mute /    ~0.6s. ack_mute shows a brief "MUTED" confirmation
//   ack_play      so the user knows their input registered. ack_play
//                 is silent (audio is its own feedback).
//
//   done          Deactivate the widget and unsuppress matrix rain
//                 so the normal greeter takes over.
//
// EVIOCGKEY (not press-event tracking) is chosen because the probe
// fires within the first 2s of greeter init — the event-stream
// thread in InputState.zig may not have processed early presses yet.
// EVIOCGKEY asks the kernel for the instantaneous held-state with no
// latency.
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
const FG_ACCENT: u32 = 0x0140C0FF;
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
        const muted = if (self.input_state) |is| is.spaceHeldNow() else false;
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

fn spawnJingle(self: *BootJingle) void {
    if (self.spawned) return;
    self.spawned = true;
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

    // Three-line stacked prompt: the action verb in the middle is
    // brightest, the framing words above and below dimmer so the
    // eye lands on SPACE first.
    drawCentred("── HOLD ──", cx, cy - 3, FG_DIM);
    drawCentred("S P A C E", cx, cy - 1, FG_BRIGHT);
    drawCentred("for silence", cx, cy + 1, FG_DIM);

    // Countdown bar drains left-to-right over REACT_SEC.
    const elapsed = self.last_now - self.phase_started;
    const bar_w: usize = 24;
    const remain = @max(@as(f64, 0.0), @min(@as(f64, 1.0), 1.0 - elapsed / REACT_SEC));
    const filled: usize = @intFromFloat(remain * @as(f64, @floatFromInt(bar_w)));
    const bar_x: usize = if (cx >= bar_w / 2) cx - bar_w / 2 else 0;
    const bar_y = cy + 3;
    var k: usize = 0;
    while (k < bar_w) : (k += 1) {
        const ch: u32 = if (k < filled) '█' else '░';
        const fg: u32 = if (k < filled) FG_ACCENT else FG_DIM;
        TerminalBuffer.drawCharMultiple(ch, bar_x + k, bar_y, 1, fg, BG);
    }
}

fn drawAckMute(self: *BootJingle) void {
    const buf = self.buffer;
    drawCentred("── MUTED ──", buf.width / 2, buf.height / 2, FG_DIM);
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

test "update past REACT_SEC transitions to ack_play when not muted (without spawn)" {
    var bj = init(testing.allocator, undefined);
    bj.start(100.0);
    // Pre-set the spawned flag so spawnJingle short-circuits — we
    // don't want `zig build test` to actually play the jingle once
    // the launcher is installed on the dev machine.
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
