// Threaded reader of /dev/input/event* keyboard devices. Maintains
// per-physical-key state (specifically LSHIFT and RSHIFT) so we can
// gate dangerous keybinds behind a both-shifts-held check that
// termbox cannot provide on its own — termbox collapses LSHIFT and
// RSHIFT into a single TB_MOD_SHIFT modifier with no L-vs-R
// distinction.
//
// Used by main.zig's shutdownCmd / restartCmd handlers as an
// anti-misclick gate: the configured key binding (e.g. Ctrl+Shift+
// F10) is still required at the termbox layer, and on top of that
// the callback only fires if both shifts are held simultaneously
// according to the raw kernel event stream. Two-handed muscle memory
// is what makes the gate hard to misclick — a stray Shift+F10 or
// even Ctrl+Shift+F10 from one hand alone can't fire the action.
//
// Failure modes:
//   * /dev/input/* not readable → init returns error; caller should
//     fall back to the configured key alone (Ctrl+Shift+F10 still
//     gives basic anti-misclick).
//   * Hot-plugged keyboards: not tracked. Acceptable for a display
//     manager that runs at boot with the integrated keyboard present.
//   * Other processes reading the same evdev nodes: not a conflict —
//     evdev events are broadcast to all readers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

// Linux input event struct — 24 bytes on 64-bit (timeval{i64, i64} +
// u16 type + u16 code + i32 value). The wire layout is stable across
// kernel versions for these fields.
const InputEvent = extern struct {
    sec: i64,
    usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

const EV_KEY: u16 = 1;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_SPACE: u16 = 57;

// Linux KEY_MAX = 0x2FF (767), so the held-keys bitmap from
// EVIOCGKEY fits in 96 bytes ((767 >> 3) + 1).
const KEY_BIT_BYTES: usize = 96;

// EVIOCGKEY(len) = _IOR('E', 0x18, char[len])
//   _IOC(dir=2 read, type='E', nr=0x18, size=len)
//   = (dir<<30) | (size<<16) | (type<<8) | nr
const EVIOCGKEY_96: u32 =
    (@as(u32, 2) << 30) | (@as(u32, KEY_BIT_BYTES) << 16) | (@as(u32, 'E') << 8) | 0x18;


allocator: Allocator,
fds: std.ArrayList(i32),
// Counters track press/release nesting in case a key generates
// multiple downs before a single up (autorepeat sends value=2 which
// we ignore, so the counter stays balanced).
lshift: std.atomic.Value(i32),
rshift: std.atomic.Value(i32),
thread: ?std.Thread,
should_stop: std.atomic.Value(bool),

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .fds = .empty,
        .lshift = std.atomic.Value(i32).init(0),
        .rshift = std.atomic.Value(i32).init(0),
        .thread = null,
        .should_stop = std.atomic.Value(bool).init(false),
    };
}

// Open every /dev/input/event* node O_RDONLY|O_NONBLOCK. Devices
// that aren't keyboards still get opened — their KEY_LEFTSHIFT /
// KEY_RIGHTSHIFT events simply never fire, so we don't bother with
// EVIOCGBIT capability filtering. Returns error if no devices could
// be opened at all (so caller can decide to fall back).
pub fn start(self: *Self) !void {
    try self.scanDevices();
    if (self.fds.items.len == 0) return error.NoInputDevices;
    self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
}

pub fn stop(self: *Self) void {
    self.should_stop.store(true, .seq_cst);
    if (self.thread) |t| t.join();
    self.thread = null;
}

pub fn deinit(self: *Self) void {
    for (self.fds.items) |fd| _ = std.posix.system.close(@intCast(fd));
    self.fds.deinit(self.allocator);
}

pub fn bothShiftsHeld(self: *const Self) bool {
    return self.lshift.load(.seq_cst) > 0 and self.rshift.load(.seq_cst) > 0;
}

// One-shot probe: is SPACE held on any open evdev device RIGHT NOW?
// Uses EVIOCGKEY ioctl — kernel returns the current held-state of
// every key on the device. Does NOT depend on the event-stream
// thread having started or having seen the press. Safe to call
// even if start() hasn't been called yet (just opens zero devices
// → returns false).
//
// Why ioctl instead of tracking SPACE through the event loop: the
// boot-jingle probe fires within the first ~2s of greeter init,
// before the user has any reason to expect typing to register. The
// event thread might not have processed early presses yet. EVIOCGKEY
// returns the instantaneous kernel state with no latency.
pub fn spaceHeldNow(self: *const Self) bool {
    var key_bits: [KEY_BIT_BYTES]u8 = undefined;
    for (self.fds.items) |fd| {
        // memset BEFORE the ioctl so an EBADF/EINVAL/etc leaves the
        // buffer all-zero — the bit check then returns false, the
        // safe default (jingle plays, no surprise silencing).
        @memset(&key_bits, 0);
        _ = std.os.linux.ioctl(@intCast(fd), EVIOCGKEY_96, @intFromPtr(&key_bits));
        const byte_idx: usize = KEY_SPACE >> 3;
        const bit_idx: u3 = @intCast(KEY_SPACE & 7);
        if ((key_bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) return true;
    }
    return false;
}

fn scanDevices(self: *Self) !void {
    // Zig 0.16 dropped std.fs.cwd().openDir for non-io-based reads,
    // so just try /dev/input/event0..event63 by name. event nodes
    // are dense small integers on Linux (allocated by udev/devtmpfs)
    // and 64 covers any plausible system. Missing nodes silently
    // skipped.
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{i}) catch continue;
        const fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            path,
            .{ .ACCMODE = .RDONLY, .NONBLOCK = true },
            0,
        ) catch continue;
        try self.fds.append(self.allocator, @intCast(fd));
    }
}

fn threadLoop(self: *Self) void {
    // Allocate pollfd array on the stack. 64 device cap matches the
    // scanDevices loop's upper bound.
    var pollfds: [64]std.posix.pollfd = undefined;
    const n_fds = self.fds.items.len;
    for (self.fds.items, 0..) |fd, i| {
        pollfds[i] = .{ .fd = @intCast(fd), .events = std.posix.POLL.IN, .revents = 0 };
    }
    var ev: InputEvent = undefined;
    while (!self.should_stop.load(.seq_cst)) {
        // poll() with a short timeout — 100ms — so the should_stop
        // check has bounded latency on shutdown.
        const ready = std.posix.poll(pollfds[0..n_fds], 100) catch continue;
        if (ready == 0) continue;
        for (pollfds[0..n_fds]) |pfd| {
            if (pfd.revents & std.posix.POLL.IN == 0) continue;
            // Drain pending events from this fd.
            while (true) {
                const n = std.posix.read(pfd.fd, std.mem.asBytes(&ev)) catch break;
                if (n != @sizeOf(InputEvent)) break;
                if (ev.type != EV_KEY) continue;
                // value: 1 = press, 0 = release, 2 = autorepeat (ignore).
                if (ev.value != 0 and ev.value != 1) continue;
                const delta: i32 = if (ev.value == 1) 1 else -1;
                switch (ev.code) {
                    KEY_LEFTSHIFT => _ = self.lshift.fetchAdd(delta, .seq_cst),
                    KEY_RIGHTSHIFT => _ = self.rshift.fetchAdd(delta, .seq_cst),
                    else => {},
                }
            }
        }
    }
}

// ─── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "init/deinit balanced without start" {
    var st = init(testing.allocator);
    defer st.deinit();
    try testing.expect(!st.bothShiftsHeld());
}

test "bothShiftsHeld reflects counter state" {
    var st = init(testing.allocator);
    defer st.deinit();
    try testing.expect(!st.bothShiftsHeld());
    _ = st.lshift.fetchAdd(1, .seq_cst);
    try testing.expect(!st.bothShiftsHeld());
    _ = st.rshift.fetchAdd(1, .seq_cst);
    try testing.expect(st.bothShiftsHeld());
    _ = st.lshift.fetchSub(1, .seq_cst);
    try testing.expect(!st.bothShiftsHeld());
}

test "InputEvent is 24 bytes on 64-bit" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
}

test "EVIOCGKEY_96 encodes to the expected ioctl number" {
    // Hand-computed: _IOC(READ=2, 'E'=0x45, 0x18, 96)
    //   = (2<<30) | (96<<16) | (0x45<<8) | 0x18
    //   = 0x80000000 | 0x00600000 | 0x00004500 | 0x00000018
    //   = 0x80604518
    try testing.expectEqual(@as(u32, 0x80604518), EVIOCGKEY_96);
}

test "spaceHeldNow returns false with no devices open" {
    var st = init(testing.allocator);
    defer st.deinit();
    try testing.expect(!st.spaceHeldNow());
}
