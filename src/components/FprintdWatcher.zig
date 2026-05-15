// Always-on fingerprint listener.
//
// Spawns `fprintd-verify <user>` in the background while the greeter is
// idle. When the child exits with status 0 (a finger matched), trips the
// host code's autologin path so /etc/pam.d/ly-autologin (pam_permit)
// runs and no PAM-side fingerprint re-swipe is required.
//
// The widget itself is invisible — it returns from `draw()` immediately
// and registers no keybinds — but its `update()` is called every
// 250 ms by the event loop, which gives us a steady poll cadence
// without a dedicated thread.
//
// Coupling with the host:
//   * The host owns selection of the username and the autologin trigger,
//     so it passes three plain-function callbacks via `init()` plus a
//     `*anyopaque` context they all receive.
//   * The host must call `stop()` before running its own PAM auth path
//     (so the BG verify subprocess doesn't fight the in-PAM
//     pam_fprintd module for the sensor).

const std = @import("std");
const Allocator = std.mem.Allocator;

const ly_ui = @import("ly-ui");
const Widget = ly_ui.Widget;
const keyboard = ly_ui.keyboard;

const ly_core = ly_ui.ly_core;
const interop = ly_core.interop;

const FprintdWatcher = @This();

pub const Callbacks = struct {
    /// Returns the currently selected username — when this changes the
    /// watcher restarts the subprocess so we're listening for the right
    /// user's enrolled fingers.
    get_user: *const fn (ctx: *anyopaque) []const u8,
    /// Triggered when fprintd-verify exits with status 0. The host is
    /// expected to run its autologin path (which calls
    /// `auth.authenticate` with the ly-autologin PAM service).
    trigger_autologin: *const fn (ctx: *anyopaque) anyerror!void,
    /// True while a host-side PAM auth is in progress. When true the
    /// watcher tears down its subprocess so it doesn't race the in-PAM
    /// fprintd module.
    is_auth_busy: *const fn (ctx: *anyopaque) bool,
    /// Returns Ly's owning VT number. The watcher pauses its subprocess
    /// when the kernel's active VT (/sys/class/tty/tty0/active) doesn't
    /// match — otherwise an accidental finger touch from another TTY
    /// would trigger autologin against an inactive VT, which logind
    /// rejects with "VirtualTerminalAlreadyTaken" and which also wastes
    /// the user's swipe.
    get_my_vt: *const fn (ctx: *anyopaque) u8,
    /// Called when the kernel's active VT transitions to ours (the user
    /// just Ctrl+Alt+Fn'd back to us). The host should mark its
    /// TerminalBuffer dirty so it fully redraws — Linux's framebuffer
    /// console doesn't preserve 24-bit color attributes across VT
    /// switches, so cells that we wrote in green can come back gray
    /// until we paint them again.
    on_vt_acquired: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

const FPRINTD_VERIFY_PATH = "/usr/bin/fprintd-verify";
const POLL_INTERVAL_MS: usize = 250;
const FAILURE_BACKOFF_THRESHOLD: u8 = 8;
const FAILURE_BACKOFF_MS: usize = 5000;

instance: ?Widget = null,
allocator: Allocator,
callbacks: Callbacks,
pid: ?std.posix.pid_t = null,
current_user_owned: ?[:0]u8 = null,
consecutive_failures: u8 = 0,
backoff_until_us: ?i64 = null,
vt_was_mine: bool = true,

pub fn init(allocator: Allocator, callbacks: Callbacks) FprintdWatcher {
    return .{
        .allocator = allocator,
        .callbacks = callbacks,
    };
}

pub fn widget(self: *FprintdWatcher) *Widget {
    if (self.instance) |*i| return i;
    self.instance = Widget.init(
        "FprintdWatcher",
        null,
        self,
        deinit,
        null,
        draw,
        update,
        null,
        calculateTimeout,
    );
    return &self.instance.?;
}

/// Sync teardown — kill the child and wait for it. Safe to call multiple times.
pub fn stop(self: *FprintdWatcher) void {
    if (self.pid) |p| {
        _ = std.posix.kill(p, std.posix.SIG.TERM) catch {};
        var status: u32 = undefined;
        _ = std.os.linux.waitpid(p, &status, 0);
        self.pid = null;
    }
}

pub fn deinit(self: *FprintdWatcher) void {
    self.stop();
    if (self.current_user_owned) |u| self.allocator.free(u);
}

fn draw(_: *FprintdWatcher) void {}

fn calculateTimeout(_: *FprintdWatcher, _: *anyopaque) !?usize {
    return POLL_INTERVAL_MS;
}

/// Compare the kernel's current active VT (`/sys/class/tty/tty0/active`,
/// e.g. "tty1\n") against the VT this Ly instance was bound to.
fn activeVtMatchesMine(self: *FprintdWatcher) bool {
    const my_vt = self.callbacks.get_my_vt(self.callbacks.ctx);

    var buf: [16]u8 = undefined;
    const fd_raw = std.posix.system.open("/sys/class/tty/tty0/active", .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (fd_raw < 0) return true; // can't tell — assume ours
    const fd: i32 = @intCast(fd_raw);
    defer _ = std.posix.system.close(fd);

    const n_raw = std.posix.system.read(fd, &buf, buf.len);
    if (n_raw <= 0) return true;
    const n: usize = @intCast(n_raw);
    const raw = buf[0..n];
    // strip trailing newline / whitespace
    var end: usize = raw.len;
    while (end > 0 and (raw[end - 1] == '\n' or raw[end - 1] == ' ')) end -= 1;
    const active = raw[0..end];
    // active looks like "tty1" — pull digits.
    if (active.len < 4 or !std.mem.eql(u8, active[0..3], "tty")) return true;
    const active_num = std.fmt.parseInt(u8, active[3..], 10) catch return true;
    return active_num == my_vt;
}

fn nowUs() i64 {
    const t = interop.getTimeOfDay() catch return 0;
    return @as(i64, @intCast(t.seconds)) * std.time.us_per_s + @as(i64, @intCast(t.microseconds));
}

fn update(self: *FprintdWatcher, _: *anyopaque) !void {
    // Host-side auth in progress — stand down so we don't fight for the sensor.
    if (self.callbacks.is_auth_busy(self.callbacks.ctx)) {
        self.stop();
        return;
    }

    // Only listen for swipes while we're the visible VT. Otherwise a
    // finger brush would consume the swipe (fprintd-verify pulls one
    // event per invocation) and on success trigger an autologin path
    // against a non-active VT, which logind rejects with
    // "VirtualTerminalAlreadyTaken".
    const vt_mine_now = self.activeVtMatchesMine();
    if (!self.vt_was_mine and vt_mine_now) {
        // VT-focus transition false→true: the user just switched back
        // to us. Force a full redraw so post-switch gray cells get
        // overwritten with the proper green.
        self.callbacks.on_vt_acquired(self.callbacks.ctx);
    }
    self.vt_was_mine = vt_mine_now;
    if (!vt_mine_now) {
        self.stop();
        return;
    }

    // If a verify failed repeatedly (no fprintd, dead daemon, etc.) back off.
    if (self.backoff_until_us) |until| {
        if (nowUs() < until) return;
        self.backoff_until_us = null;
    }

    const selected_user = self.callbacks.get_user(self.callbacks.ctx);

    // Restart subprocess if user selection changed.
    if (self.pid != null) {
        if (self.current_user_owned) |prev| {
            if (!std.mem.eql(u8, prev, selected_user)) {
                self.stop();
            }
        }
    }

    if (self.pid) |p| {
        // Poll the child without blocking.
        var status: u32 = undefined;
        const wait_result = std.os.linux.waitpid(p, &status, std.os.linux.W.NOHANG);
        if (wait_result == 0) return; // still running
        self.pid = null;

        const exit_code: u32 = (status >> 8) & 0xff;
        if (exit_code == 0) {
            self.consecutive_failures = 0;
            try self.callbacks.trigger_autologin(self.callbacks.ctx);
            return;
        }
        // Treat fprintd-verify exit code 1 (timeout / no match) as a normal
        // re-poll. Higher exit codes (exec failure, daemon missing) start
        // counting toward backoff.
        if (exit_code >= 2) {
            self.consecutive_failures +|= 1;
            if (self.consecutive_failures >= FAILURE_BACKOFF_THRESHOLD) {
                self.backoff_until_us = nowUs() + (@as(i64, FAILURE_BACKOFF_MS) * std.time.us_per_ms);
                self.consecutive_failures = 0;
            }
        }
        return; // respawn on next tick
    }

    // Spawn — replace the stored copy of the current user.
    const user_copy = try self.allocator.dupeZ(u8, selected_user);
    if (self.current_user_owned) |old| self.allocator.free(old);
    self.current_user_owned = user_copy;

    const fork_pid = std.posix.system.fork();
    if (fork_pid == 0) {
        // Child: silence stdio so fprintd-verify's prompts don't bleed onto
        // the greeter TTY, then exec.
        _ = std.posix.system.close(0);
        _ = std.posix.system.close(1);
        _ = std.posix.system.close(2);

        const argv = [_:null]?[*:0]const u8{
            FPRINTD_VERIFY_PATH,
            user_copy.ptr,
            null,
        };
        _ = std.posix.system.execve(FPRINTD_VERIFY_PATH, &argv, std.c.environ);
        std.process.exit(127);
    }
    if (fork_pid > 0) self.pid = fork_pid;
}
