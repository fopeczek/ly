// Live-tunable Matrix debug menu, toggled with Ctrl+Shift+Alt+Esc.
// Renders a tabbed panel on top of the running rain. Tab/Shift+Tab
// cycle the active tab; j/k cycle items within a tab; h/l adjust the
// selected numeric item or fire it if it's an action.
//
// State + items live here; the keybind plumbing and conditional
// pass-through into ly's normal handlers live in main.zig (see the
// debug_visible check inside viMoveCursorUp/Down + new wrapCursor
// override + Ctrl+Shift+Alt+Esc handler).

const std = @import("std");
const ly_ui = @import("ly-ui");
const Cell = ly_ui.Cell;
const Widget = ly_ui.Widget;
const TerminalBuffer = ly_ui.TerminalBuffer;
const Matrix = @import("../animations/Matrix.zig");
const Lockdown = @import("../animations/Lockdown.zig");
const BootJingle = @import("../animations/BootJingle.zig");

const DebugMenu = @This();

// Color scheme for the panel. Bright green-on-dark with red action
// rows so the modal reads clearly against the rain.
const COL_BORDER: u32 = 0x0100FF00;
const COL_BG: u32 = 0x00000000;
const COL_LABEL: u32 = 0x0000FF66;
const COL_VALUE: u32 = 0x01FFFFFF;
const COL_SELECTED_BG: u32 = 0x00003300;
const COL_TAB_INACTIVE: u32 = 0x0000AA00;
const COL_TAB_ACTIVE: u32 = 0x01FFFF00;
const COL_ACTION: u32 = 0x01FFAA00;
const COL_HELP: u32 = 0x0000AAAA;

// All settable items in a flat enum so handler dispatch is a single
// switch. Tabs are just a grouping concept — see TABS below.
pub const Item = enum {
    // Rain tab
    speed_min,
    speed_max,
    rain_density,
    drop_v_margin,
    drop_h_margin,
    min_drop_len,
    max_drop_len,
    tail_churn_prob,
    dark_run_start_pct,
    dark_run_min,
    dark_run_max,
    // Glitches tab
    glitch_seed_permille,
    glitch_ttl_min,
    glitch_ttl_max,
    // Errors tab
    overlay_initial_ttl,
    overlay_lines_per_burst,
    overlay_decay_frames,
    overlay_drop_peak_prob,
    overlay_scramble_prob,
    overlay_fall_step,
    action_error_burst,
    action_clear_errors,
    // Lockout tab
    action_toggle_locked,
    action_reset_fails,
    readout_locked,
    readout_auth_fails,
    // Animations tab
    lockout_animation,
    action_preview_lockout,
    // Bootup tab
    boot_jingle_enabled,
    action_test_jingle_sound,
    action_test_full_intro,

    pub fn label(self: Item) []const u8 {
        // Labels are padded to 16 chars so the value column lines
        // up cleanly across all rows. All wording chosen for first-
        // read intuitiveness — no "permille", "TTL", "div", etc.
        return switch (self) {
            // Rain
            .speed_min => "min speed       ",
            .speed_max => "max speed       ",
            .rain_density => "density         ",
            .drop_v_margin => "vertical margin ",
            .drop_h_margin => "horiz margin    ",
            .min_drop_len => "min trail len   ",
            .max_drop_len => "max trail len   ",
            .tail_churn_prob => "trail flicker   ",
            .dark_run_start_pct => "gap chance      ",
            .dark_run_min => "min gap length  ",
            .dark_run_max => "max gap length  ",
            // Glitches
            .glitch_seed_permille => "spawn rate      ",
            .glitch_ttl_min => "min lifetime    ",
            .glitch_ttl_max => "max lifetime    ",
            // Errors
            .overlay_initial_ttl => "sticky passes   ",
            .overlay_lines_per_burst => "lines per fail  ",
            .overlay_decay_frames => "fade time       ",
            .overlay_drop_peak_prob => "fall chance     ",
            .overlay_scramble_prob => "char corrupt    ",
            .overlay_fall_step => "fall step       ",
            .action_error_burst => "[ trigger fail  ]",
            .action_clear_errors => "[ clear errors  ]",
            // Lockout
            .action_toggle_locked => "[ toggle lock   ]",
            .action_reset_fails => "[ reset attempts]",
            .readout_locked => "locked          ",
            .readout_auth_fails => "fail count      ",
            // Animations
            .lockout_animation => "lockout anim    ",
            .action_preview_lockout => "[ preview lock  ]",
            // Bootup
            .boot_jingle_enabled => "boot jingle     ",
            .action_test_jingle_sound => "[ test sound    ]",
            .action_test_full_intro => "[ replay intro  ]",
        };
    }

    pub fn isAction(self: Item) bool {
        return switch (self) {
            .action_error_burst, .action_clear_errors, .action_toggle_locked, .action_reset_fails, .action_preview_lockout, .action_test_jingle_sound, .action_test_full_intro => true,
            else => false,
        };
    }

    // Short description shown in a side popup when the user presses
    // Enter on an item (or whenever the item is selected in edit
    // mode). Kept terse to fit a ~28-char panel; one tip per item.
    pub fn description(self: Item) []const u8 {
        // All descriptions written in user voice — what changes
        // when you raise the value, with units when relevant.
        return switch (self) {
            .speed_min => "Slowest column's fall\nspeed (cells per frame).\nLower = lazier trails.",
            .speed_max => "Fastest column's fall\nspeed (cells per frame).\nHigher = quicker trails.",
            .rain_density => "Spawn rate. Each column\nrolls a fresh chance per\nadvance.\n0 = no spawns.\n1 = ~1 trail / 1000 ticks.\n1000 = constant.",
            .drop_v_margin => "Vertical clearance (in\ncells) that must be free\nat the top of a column\nbefore a new trail can\nspawn there. Larger =\nmore stagger between\nraindrops, less wave.",
            .drop_h_margin => "Horizontal clearance to\nadjacent columns. 0 = no\ncheck; columns may have\nheads at the same row.\nHigher = no two trails\nstart side-by-side.",
            .min_drop_len => "Shortest trail length\nallowed (cells).",
            .max_drop_len => "Longest trail length\nallowed (cells). Capped\nby screen height.",
            .tail_churn_prob => "Per-cell chance each\nframe that a trail glyph\nchanges. Higher =\nmore flicker.",
            .dark_run_start_pct => "Chance (%) a new trail\nstarts with a dark gap\nin it.",
            .dark_run_min => "Shortest dark-gap run\n(blank cells inside a\nfalling trail).",
            .dark_run_max => "Longest dark-gap run.",
            .glitch_seed_permille => "Chance per frame (out\nof 1000) that a red\nglitch dot appears.",
            .glitch_ttl_min => "Shortest glitch dot\nlifetime in frames\n(50 fps ≈ 1s per 50).",
            .glitch_ttl_max => "Longest glitch dot\nlifetime in frames.",
            .overlay_initial_ttl => "How many rain heads\nmust pass before an\nerror char is wiped.\nHigher = stickier.",
            .overlay_lines_per_burst => "Number of fake error\nlines added per\nfailed login.",
            .overlay_decay_frames => "Total time before all\nerror text has fallen\naway (1500f ≈ 30s).",
            .overlay_drop_peak_prob => "Peak per-frame chance\nan error char falls\nat the end of fade.",
            .overlay_scramble_prob => "Chance per frame each\nerror char garbles into\nanother glyph.",
            .overlay_fall_step => "Rows an error char\ndrops on each fall\nevent. Higher = faster.",
            .action_error_burst => "Simulate one failed\nlogin (paints a fresh\nerror burst).",
            .action_clear_errors => "Wipe all error text\nfrom the screen now.",
            .action_toggle_locked => "Switch between normal\nand locked rain (sparse\ngray glyphs).",
            .action_reset_fails => "Reset the failed-login\ncounter to zero and\nclear lockout.",
            .readout_locked => "Whether the screen is\nin lockout mode\n(YES / no).",
            .readout_auth_fails => "Current count of\nconsecutive failed\nlogins.",
            .lockout_animation => "Animation played when\nthe lockout fires.\nUse \xe2\x86\x90/\xe2\x86\x92 to cycle types.\nlegacy: sparse gray\nrain forever.\nscramble: full sequence\nwith clock countdown.",
            .action_preview_lockout => "Play the selected\nlockout animation now,\nwith a 5 second clock.\nReal auth state stays\nunchanged.",
            .boot_jingle_enabled => "Play the boot jingle\n+ silence prompt at\ngreeter init?\nUse \xe2\x86\x90/\xe2\x86\x92 to toggle.\nPersists across reboots.",
            .action_test_jingle_sound => "Play the jingle audio\nonce, right now. No\nvisual prompt.",
            .action_test_full_intro => "Replay the full boot\nintro (prompt + audio\n+ ack). Behaves exactly\nas if you'd just booted.",
        };
    }

    pub fn isReadout(self: Item) bool {
        return switch (self) {
            .readout_locked, .readout_auth_fails => true,
            else => false,
        };
    }
};

pub const Tab = enum {
    rain,
    glitches,
    errors,
    lockout,
    animations,
    bootup,

    pub fn name(self: Tab) []const u8 {
        return switch (self) {
            .rain => "Rain",
            .glitches => "Glitches",
            .errors => "Errors",
            .lockout => "Lockout",
            .animations => "Animations",
            .bootup => "Bootup",
        };
    }

    pub fn items(self: Tab) []const Item {
        return switch (self) {
            .rain => &[_]Item{
                .speed_min, .speed_max, .rain_density,
                .drop_v_margin, .drop_h_margin,
                .min_drop_len, .max_drop_len,
                .tail_churn_prob, .dark_run_start_pct,
                .dark_run_min, .dark_run_max,
            },
            .glitches => &[_]Item{
                .glitch_seed_permille, .glitch_ttl_min, .glitch_ttl_max,
            },
            .errors => &[_]Item{
                .overlay_initial_ttl, .overlay_lines_per_burst,
                .overlay_decay_frames,
                .overlay_drop_peak_prob, .overlay_scramble_prob,
                .overlay_fall_step,
                .action_error_burst, .action_clear_errors,
            },
            .lockout => &[_]Item{
                .action_toggle_locked, .action_reset_fails,
                .readout_locked, .readout_auth_fails,
            },
            .animations => &[_]Item{
                .lockout_animation, .action_preview_lockout,
            },
            .bootup => &[_]Item{
                .boot_jingle_enabled,
                .action_test_jingle_sound,
                .action_test_full_intro,
            },
        };
    }
};

const TABS = [_]Tab{ .rain, .glitches, .errors, .lockout, .animations, .bootup };

// Two-mode navigation. In .nav, arrow keys cycle items / tabs and
// Enter "opens" the selected item for editing. In .edit, up/down
// adjust the selected numeric value; Enter or Esc returns to .nav.
// Action items fire directly on Enter without entering edit mode.
pub const Mode = enum { nav, edit };

visible: bool = false,
tab_idx: u8 = 0,
item_idx: u8 = 0,
mode: Mode = .nav,
// Wired up by main after Matrix is constructed and the UiState
// pointers are stable. drawWidget reads through these to get current
// values to display.
matrix_ptr: ?*Matrix = null,
auth_fails_ptr: ?*u64 = null,
buffer_ptr: ?*TerminalBuffer = null,
lockdown_ptr: ?*Lockdown = null,
boot_jingle_ptr: ?*BootJingle = null,
instance: ?Widget = null,

pub fn init() DebugMenu {
    return .{};
}

pub fn attach(
    self: *DebugMenu,
    matrix_ptr: *Matrix,
    auth_fails_ptr: *u64,
    buffer_ptr: *TerminalBuffer,
    lockdown_ptr: *Lockdown,
    boot_jingle_ptr: *BootJingle,
) void {
    self.matrix_ptr = matrix_ptr;
    self.auth_fails_ptr = auth_fails_ptr;
    self.buffer_ptr = buffer_ptr;
    self.lockdown_ptr = lockdown_ptr;
    self.boot_jingle_ptr = boot_jingle_ptr;
}

pub fn widget(self: *DebugMenu) *Widget {
    if (self.instance) |*w| return w;
    self.instance = Widget.init(
        "DebugMenu",
        null,
        self,
        null,
        null,
        drawWidget,
        null,
        null,
        null,
    );
    return &self.instance.?;
}

pub fn toggle(self: *DebugMenu) void {
    self.visible = !self.visible;
    if (self.visible) {
        self.tab_idx = 0;
        self.item_idx = 0;
        self.mode = .nav;
    }
}

// Enter pressed on the current item.
//   - Action item: fire it (return the corresponding ActionResult).
//   - Numeric item: toggle into edit mode (no value change).
//   - Readout: no-op.
//   - While already in edit: commit and return to nav mode.
pub fn activate(self: *DebugMenu, _: *Matrix) ActionResult {
    var r: ActionResult = .{};
    if (self.mode == .edit) {
        self.mode = .nav;
        return r;
    }
    const item = self.currentItem();
    if (item.isAction()) {
        switch (item) {
            .action_error_burst => r.fire_error_burst = true,
            .action_clear_errors => r.clear_errors = true,
            .action_toggle_locked => r.toggle_locked = true,
            .action_reset_fails => r.reset_fails = true,
            .action_preview_lockout => r.preview_lockout = true,
            .action_test_jingle_sound => r.test_jingle_sound = true,
            .action_test_full_intro => r.test_full_intro = true,
            else => {},
        }
        return r;
    }
    if (item.isReadout()) return r;
    // Numeric — flip into edit mode.
    self.mode = .edit;
    return r;
}

// Exit edit mode without committing further changes. Wired to Esc
// when the menu is visible.
pub fn exitEdit(self: *DebugMenu) bool {
    if (self.mode == .edit) {
        self.mode = .nav;
        return true;
    }
    return false;
}

pub fn currentTab(self: *const DebugMenu) Tab {
    return TABS[self.tab_idx];
}

pub fn currentItem(self: *const DebugMenu) Item {
    return self.currentTab().items()[self.item_idx];
}

pub fn nextTab(self: *DebugMenu) void {
    self.tab_idx = (self.tab_idx + 1) % @as(u8, @intCast(TABS.len));
    self.item_idx = 0;
}

pub fn prevTab(self: *DebugMenu) void {
    self.tab_idx = if (self.tab_idx == 0) @as(u8, @intCast(TABS.len - 1)) else self.tab_idx - 1;
    self.item_idx = 0;
}

pub fn nextItem(self: *DebugMenu) void {
    const count: u8 = @intCast(self.currentTab().items().len);
    self.item_idx = (self.item_idx + 1) % count;
}

pub fn prevItem(self: *DebugMenu) void {
    const count: u8 = @intCast(self.currentTab().items().len);
    self.item_idx = if (self.item_idx == 0) count - 1 else self.item_idx - 1;
}

// Adjust the currently-selected item by `delta` (-1 or +1). For
// actions, +1 fires it (delta < 0 is no-op for actions). For
// readouts, no-op. Matrix is mutated in place; main.zig handles
// auth_fails reset and pushErrorBurst() via the action callbacks.
pub const ActionResult = struct {
    fire_error_burst: bool = false,
    toggle_locked: bool = false,
    reset_fails: bool = false,
    clear_errors: bool = false,
    preview_lockout: bool = false,
    test_jingle_sound: bool = false,
    test_full_intro: bool = false,
    boot_jingle_prefs_changed: bool = false,
};

pub fn adjust(self: *DebugMenu, m: *Matrix, delta: i8) ActionResult {
    return self.adjustScaled(m, delta, 1.0);
}

// Scaled adjust used by Shift/Ctrl modifier handlers. `step_scale`:
//   1.0 = normal (single arrow keypress)
//   5.0 = Shift held (coarse, 5×)
//   0.1 = Ctrl held (fine, 1/10 — only changes f32 fields; integer
//          fields stay at a 1-step minimum so they can't no-op)
pub fn adjustScaled(self: *DebugMenu, m: *Matrix, delta: i8, step_scale: f32) ActionResult {
    var r: ActionResult = .{};
    const item = self.currentItem();
    // Effective integer-field step, clamped to at least ±1 so Ctrl
    // doesn't make integer fields un-adjustable.
    const int_step: i8 = computeIntStep(delta, step_scale);
    switch (item) {
        .speed_min => m.speed_min = std.math.clamp(m.speed_min + @as(f32, @floatFromInt(delta)) * 0.01 * step_scale, 0.01, m.speed_max),
        .speed_max => m.speed_max = std.math.clamp(m.speed_max + @as(f32, @floatFromInt(delta)) * 0.01 * step_scale, m.speed_min, 2.0),
        .rain_density => m.rain_density = adjustRainDensity(m.rain_density, delta, step_scale),
        .drop_v_margin => m.drop_v_margin = u16_adjust(m.drop_v_margin, int_step, 0, 200),
        .drop_h_margin => m.drop_h_margin = u16_adjust(m.drop_h_margin, int_step, 0, 60),
        .min_drop_len => m.min_drop_len = u8_adjust(m.min_drop_len, int_step, 2, m.max_drop_len),
        .max_drop_len => m.max_drop_len = u8_adjust(m.max_drop_len, int_step, m.min_drop_len, 80),
        .tail_churn_prob => m.tail_churn_prob = std.math.clamp(m.tail_churn_prob + @as(f32, @floatFromInt(delta)) * 0.01 * step_scale, 0.0, 1.0),
        .dark_run_start_pct => m.dark_run_start_pct = u16_adjust(m.dark_run_start_pct, int_step, 0, 100),
        .dark_run_min => m.dark_run_min = u8_adjust(m.dark_run_min, int_step, 1, m.dark_run_max),
        .dark_run_max => m.dark_run_max = u8_adjust(m.dark_run_max, int_step, m.dark_run_min, 20),
        .glitch_seed_permille => m.glitch_seed_permille = u16_adjust(m.glitch_seed_permille, int_step, 0, 1000),
        .glitch_ttl_min => m.glitch_ttl_min = u8_adjust(m.glitch_ttl_min, int_step, 1, m.glitch_ttl_max),
        .glitch_ttl_max => m.glitch_ttl_max = u8_adjust(m.glitch_ttl_max, int_step, m.glitch_ttl_min, 250),
        .overlay_initial_ttl => m.overlay_initial_ttl = u8_adjust(m.overlay_initial_ttl, int_step, 1, 50),
        .overlay_lines_per_burst => m.overlay_lines_per_burst = u8_adjust(m.overlay_lines_per_burst, int_step, 1, 20),
        .overlay_decay_frames => m.overlay_decay_frames = adjustDecayFrames(m.overlay_decay_frames, int_step),
        .overlay_drop_peak_prob => m.overlay_drop_peak_prob = std.math.clamp(m.overlay_drop_peak_prob + @as(f32, @floatFromInt(delta)) * 0.005 * step_scale, 0.0, 1.0),
        .overlay_scramble_prob => m.overlay_scramble_prob = std.math.clamp(m.overlay_scramble_prob + @as(f32, @floatFromInt(delta)) * 0.002 * step_scale, 0.0, 1.0),
        .overlay_fall_step => m.overlay_fall_step = u8_adjust(m.overlay_fall_step, int_step, 1, 30),
        .action_error_burst => if (delta > 0) {
            r.fire_error_burst = true;
        },
        .action_clear_errors => if (delta > 0) {
            r.clear_errors = true;
        },
        .action_toggle_locked => if (delta > 0) {
            r.toggle_locked = true;
        },
        .action_reset_fails => if (delta > 0) {
            r.reset_fails = true;
        },
        .action_test_jingle_sound => if (delta > 0) {
            r.test_jingle_sound = true;
        },
        .action_test_full_intro => if (delta > 0) {
            r.test_full_intro = true;
        },
        .boot_jingle_enabled => {
            // Toggle on either arrow direction — single bool field.
            if (self.boot_jingle_ptr) |bj| {
                bj.enabled = !bj.enabled;
                r.boot_jingle_prefs_changed = true;
            }
        },
        .readout_locked, .readout_auth_fails => {},
        .lockout_animation => {
            // Cycle through animation types regardless of delta sign.
            // Two types currently (legacy_sparse, scramble_shrink) so
            // forward and back land on the same place anyway.
            if (self.lockdown_ptr) |ld| ld.selected_anim = ld.selected_anim.cycle();
        },
        .action_preview_lockout => if (delta > 0) {
            r.preview_lockout = true;
        },
    }
    return r;
}

// Round delta * step_scale to an integer step. Clamps to at least
// ±1 so Ctrl (small scale) doesn't make integer fields un-adjustable.
fn computeIntStep(delta: i8, step_scale: f32) i8 {
    const raw = @as(f32, @floatFromInt(delta)) * step_scale;
    if (raw > 0 and raw < 1) return 1;
    if (raw < 0 and raw > -1) return -1;
    const ri: i16 = @intFromFloat(raw);
    if (ri > 127) return 127;
    if (ri < -127) return -127;
    return @intCast(ri);
}

fn u8_adjust(cur: u8, delta: i8, lo: u8, hi: u8) u8 {
    const cur_i: i16 = @intCast(cur);
    const nxt = cur_i + @as(i16, delta);
    if (nxt < @as(i16, lo)) return lo;
    if (nxt > @as(i16, hi)) return hi;
    return @intCast(nxt);
}

fn u16_adjust(cur: u16, delta: i8, lo: u16, hi: u16) u16 {
    const cur_i: i32 = @intCast(cur);
    const nxt = cur_i + @as(i32, delta);
    if (nxt < @as(i32, lo)) return lo;
    if (nxt > @as(i32, hi)) return hi;
    return @intCast(nxt);
}

// Special step size for rain_density — range is 0..1000 so the
// usual ±1 step would feel glacial. Default 10 cells per arrow,
// 50 with Shift (coarse sweep), 1 with Ctrl (fine). 0 is the
// explicit "no spawn" floor; 1000 is constant flood.
fn adjustRainDensity(cur: u16, delta: i8, step_scale: f32) u16 {
    var base: i32 = @as(i32, delta) * 10;
    if (step_scale >= 4.0) base = @as(i32, delta) * 50;
    if (step_scale < 0.5) base = @as(i32, delta) * 1;
    const cur_i: i32 = @intCast(cur);
    const nxt: i32 = @max(0, @min(1000, cur_i + base));
    return @intCast(nxt);
}

// Special step size for overlay_decay_frames — 1 keypress = 50
// frames (~1s @ 50fps) so the user can sweep the full range
// quickly. Lower bound 50 keeps decay non-trivial; upper 30000
// frames ≈ 10 minutes.
fn adjustDecayFrames(cur: u16, delta: i8) u16 {
    const cur_i: i32 = @intCast(cur);
    const nxt = cur_i + @as(i32, delta) * 50;
    if (nxt < 50) return 50;
    if (nxt > 30000) return 30000;
    return @intCast(nxt);
}

// Format an item's current value into the given buffer. Returns the
// portion of buf actually written. The caller embeds this in a
// rendered line like "  speed_min      0.06".
pub fn formatValue(
    item: Item,
    m: *const Matrix,
    auth_fails: u64,
    lockdown_anim_name: []const u8,
    buf: []u8,
) ![]const u8 {
    return switch (item) {
        .speed_min => try std.fmt.bufPrint(buf, "{d:.2}", .{m.speed_min}),
        .speed_max => try std.fmt.bufPrint(buf, "{d:.2}", .{m.speed_max}),
        .rain_density => try std.fmt.bufPrint(buf, "{d}{s}", .{ m.rain_density, if (m.rain_density == 0) " (off)" else "" }),
        .drop_v_margin => try std.fmt.bufPrint(buf, "{d}", .{m.drop_v_margin}),
        .drop_h_margin => try std.fmt.bufPrint(buf, "{d}", .{m.drop_h_margin}),
        .min_drop_len => try std.fmt.bufPrint(buf, "{d}", .{m.min_drop_len}),
        .max_drop_len => try std.fmt.bufPrint(buf, "{d}", .{m.max_drop_len}),
        .tail_churn_prob => try std.fmt.bufPrint(buf, "{d:.2}", .{m.tail_churn_prob}),
        .dark_run_start_pct => try std.fmt.bufPrint(buf, "{d}%", .{m.dark_run_start_pct}),
        .dark_run_min => try std.fmt.bufPrint(buf, "{d}", .{m.dark_run_min}),
        .dark_run_max => try std.fmt.bufPrint(buf, "{d}", .{m.dark_run_max}),
        .glitch_seed_permille => try std.fmt.bufPrint(buf, "{d}", .{m.glitch_seed_permille}),
        .glitch_ttl_min => try std.fmt.bufPrint(buf, "{d}", .{m.glitch_ttl_min}),
        .glitch_ttl_max => try std.fmt.bufPrint(buf, "{d}", .{m.glitch_ttl_max}),
        .overlay_initial_ttl => try std.fmt.bufPrint(buf, "{d}", .{m.overlay_initial_ttl}),
        .overlay_lines_per_burst => try std.fmt.bufPrint(buf, "{d}", .{m.overlay_lines_per_burst}),
        .overlay_decay_frames => try std.fmt.bufPrint(buf, "{d}f (~{d}s)", .{ m.overlay_decay_frames, m.overlay_decay_frames / 50 }),
        .overlay_drop_peak_prob => try std.fmt.bufPrint(buf, "{d:.3}", .{m.overlay_drop_peak_prob}),
        .overlay_scramble_prob => try std.fmt.bufPrint(buf, "{d:.3}", .{m.overlay_scramble_prob}),
        .overlay_fall_step => try std.fmt.bufPrint(buf, "{d}", .{m.overlay_fall_step}),
        .action_error_burst, .action_clear_errors, .action_toggle_locked, .action_reset_fails, .action_preview_lockout, .action_test_jingle_sound, .action_test_full_intro => try std.fmt.bufPrint(buf, "<press Enter>", .{}),
        .readout_locked => try std.fmt.bufPrint(buf, "{s}", .{if (m.locked) "YES" else "no"}),
        .readout_auth_fails => try std.fmt.bufPrint(buf, "{d}", .{auth_fails}),
        .lockout_animation => try std.fmt.bufPrint(buf, "{s}", .{lockdown_anim_name}),
        .boot_jingle_enabled => try std.fmt.bufPrint(buf, "<unavail>", .{}),
    };
}

// Variant of formatValue that has access to BootJingle for the
// .boot_jingle_enabled field. Falls through to the regular
// formatValue for everything else.
pub fn formatValueWithJingle(
    item: Item,
    m: *const Matrix,
    auth_fails: u64,
    lockdown_anim_name: []const u8,
    bj: ?*const BootJingle,
    buf: []u8,
) ![]const u8 {
    if (item == .boot_jingle_enabled) {
        const enabled = if (bj) |b| b.enabled else true;
        return try std.fmt.bufPrint(buf, "{s}", .{if (enabled) "yes" else "no"});
    }
    return try formatValue(item, m, auth_fails, lockdown_anim_name, buf);
}

// ─── render ────────────────────────────────────────────────────────────
// Direct cell-buffer painting — placed on a layer ABOVE the matrix so
// the rain stays visible underneath while we draw on top. No-op when
// not visible.

fn putStr(x: usize, y: usize, s: []const u8, fg: u32, bg: u32) void {
    var cx = x;
    const view = std.unicode.Utf8View.init(s) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        Cell.init(@as(u32, cp), fg, bg).put(cx, y);
        cx += 1;
    }
}

fn fillRow(x: usize, y: usize, len: usize, fg: u32, bg: u32) void {
    TerminalBuffer.drawCharMultiple(' ', x, y, len, fg, bg);
}

fn drawWidget(self: *DebugMenu) void {
    if (!self.visible) return;
    const m = self.matrix_ptr orelse return;
    const auth_fails = if (self.auth_fails_ptr) |p| p.* else 0;
    const buf = self.buffer_ptr orelse return;

    // Panel geometry: centered, fixed size. Width tuned for label +
    // value layout (left ~24 chars label, right ~12 chars value) PLUS
    // enough tab-row room for all five tabs including "Animations"
    // (the longest at 10 chars). The five tabs render as
    // `[Rain][Glitches][Errors][Lockout][Animations]` which takes
    // 50 chars + the leading 2-char margin → 52 minimum.
    const panel_w: usize = 66;
    const panel_h: usize = 18;
    if (buf.width < panel_w + 2 or buf.height < panel_h + 2) return;
    const px = (buf.width - panel_w) / 2;
    const py = (buf.height - panel_h) / 2;

    // Solid bg fill so rain underneath doesn't show through inside
    // the panel (rain shows around it on all sides).
    var ry: usize = 0;
    while (ry < panel_h) : (ry += 1) {
        fillRow(px, py + ry, panel_w, COL_LABEL, COL_BG);
    }

    // Border. Single-line box-drawing chars: ┌─┐ └─┘ │
    Cell.init(0x250C, COL_BORDER, COL_BG).put(px, py);
    Cell.init(0x2510, COL_BORDER, COL_BG).put(px + panel_w - 1, py);
    Cell.init(0x2514, COL_BORDER, COL_BG).put(px, py + panel_h - 1);
    Cell.init(0x2518, COL_BORDER, COL_BG).put(px + panel_w - 1, py + panel_h - 1);
    var i: usize = 1;
    while (i < panel_w - 1) : (i += 1) {
        Cell.init(0x2500, COL_BORDER, COL_BG).put(px + i, py);
        Cell.init(0x2500, COL_BORDER, COL_BG).put(px + i, py + panel_h - 1);
    }
    var j: usize = 1;
    while (j < panel_h - 1) : (j += 1) {
        Cell.init(0x2502, COL_BORDER, COL_BG).put(px, py + j);
        Cell.init(0x2502, COL_BORDER, COL_BG).put(px + panel_w - 1, py + j);
    }

    // Title strip
    putStr(px + 2, py, " SETTINGS ", COL_TAB_ACTIVE, COL_BG);

    // Tabs row at y = py + 2
    var tx: usize = px + 2;
    inline for (TABS, 0..) |tab, idx| {
        const is_active = idx == self.tab_idx;
        const col_fg: u32 = if (is_active) COL_TAB_ACTIVE else COL_TAB_INACTIVE;
        const tab_label = tab.name();
        putStr(tx, py + 2, "[", col_fg, COL_BG);
        putStr(tx + 1, py + 2, tab_label, col_fg, COL_BG);
        putStr(tx + 1 + tab_label.len, py + 2, "]", col_fg, COL_BG);
        tx += 3 + tab_label.len;
    }

    // Horizontal separator under tabs
    var sep_x: usize = 1;
    while (sep_x < panel_w - 1) : (sep_x += 1) {
        Cell.init(0x2500, COL_BORDER, COL_BG).put(px + sep_x, py + 3);
    }

    // Items list starts y = py + 4
    const tab = self.currentTab();
    const items = tab.items();
    var val_buf: [32]u8 = undefined;
    for (items, 0..) |item, idx| {
        const row_y = py + 4 + idx;
        // -3 instead of -2: reserve TWO inner rows above the border —
        // one for the Shift/Ctrl modifier hint, one for the nav hint.
        if (row_y >= py + panel_h - 3) break;
        const selected = idx == self.item_idx;
        const row_bg: u32 = if (selected) COL_SELECTED_BG else COL_BG;
        // Fill the row background so selection highlight is visible.
        fillRow(px + 1, row_y, panel_w - 2, COL_LABEL, row_bg);
        // Selection marker — different glyph when editing so the
        // mode change is visually obvious.
        if (selected) {
            const marker: u32 = if (self.mode == .edit) '*' else '>';
            const marker_fg: u32 = if (self.mode == .edit) 0x01FFFF00 else COL_TAB_ACTIVE;
            Cell.init(marker, marker_fg, row_bg).put(px + 2, row_y);
        }
        // Label
        const label_fg: u32 = if (item.isAction()) COL_ACTION else COL_LABEL;
        putStr(px + 4, row_y, item.label(), label_fg, row_bg);
        // Value
        const anim_label: []const u8 = if (self.lockdown_ptr) |ld| ld.selected_anim.label() else "scramble→clock ";
        const val = formatValueWithJingle(item, m, auth_fails, anim_label, self.boot_jingle_ptr, &val_buf) catch "<err>";
        putStr(px + 4 + item.label().len + 1, row_y, val, COL_VALUE, row_bg);
    }

    // Two-line footer inside the panel:
    //   * panel_h - 3 (top): Shift/Ctrl step-modifier hint. Always
    //     shown — modifiers are useful in both nav (Shift+Tab) and
    //     edit (Shift = x5, Ctrl = fine) modes, so dedicating a
    //     stable row to them keeps the user's mental map intact.
    //   * panel_h - 2 (bottom): nav/edit help line, mode-aware.
    // The previous external bottom-left "Shift = x5 Ctrl = fine"
    // label was moved here at user request — everything debug-menu-
    // related now lives inside the panel.
    const mod_hint = "Sh = x5     Ctrl = fine";
    putStr(px + 2, py + panel_h - 3, mod_hint, COL_HELP, COL_BG);

    const help = if (self.mode == .edit)
        "EDIT: \xe2\x86\x91/\xe2\x86\x93 adjust  Enter done  Esc cancel"
    else
        "\xe2\x86\x91/\xe2\x86\x93 item  Tab tab  Enter edit  Esc close";
    if (help.len < panel_w - 2) {
        putStr(px + 2, py + panel_h - 2, help, COL_HELP, COL_BG);
    } else {
        putStr(px + 2, py + panel_h - 2, "arrows / Tab / Enter / Esc", COL_HELP, COL_BG);
    }

    // Description side panel — sits to the right of the main
    // panel, ~32 cols wide, shows the currently selected item's
    // multi-line description. Skip if there's no room.
    const info_w: usize = 34;
    const info_x = px + panel_w + 1;
    if (info_x + info_w + 1 < buf.width) {
        const item = self.currentItem();
        const desc = item.description();
        // Count lines so we can size the box height.
        var n_lines: usize = 1;
        for (desc) |c| {
            if (c == '\n') n_lines += 1;
        }
        const info_h: usize = n_lines + 4; // border + title + body + bottom border + spacer

        if (py + info_h <= buf.height) {
            // Background fill.
            var ry2: usize = 0;
            while (ry2 < info_h) : (ry2 += 1) {
                fillRow(info_x, py + ry2, info_w, COL_LABEL, COL_BG);
            }
            // Border.
            Cell.init(0x250C, COL_BORDER, COL_BG).put(info_x, py);
            Cell.init(0x2510, COL_BORDER, COL_BG).put(info_x + info_w - 1, py);
            Cell.init(0x2514, COL_BORDER, COL_BG).put(info_x, py + info_h - 1);
            Cell.init(0x2518, COL_BORDER, COL_BG).put(info_x + info_w - 1, py + info_h - 1);
            var ix: usize = 1;
            while (ix < info_w - 1) : (ix += 1) {
                Cell.init(0x2500, COL_BORDER, COL_BG).put(info_x + ix, py);
                Cell.init(0x2500, COL_BORDER, COL_BG).put(info_x + ix, py + info_h - 1);
            }
            var jy: usize = 1;
            while (jy < info_h - 1) : (jy += 1) {
                Cell.init(0x2502, COL_BORDER, COL_BG).put(info_x, py + jy);
                Cell.init(0x2502, COL_BORDER, COL_BG).put(info_x + info_w - 1, py + jy);
            }
            // Title.
            putStr(info_x + 2, py, " info ", COL_TAB_ACTIVE, COL_BG);
            // Body — split desc by '\n' and put each line.
            var line_y: usize = py + 2;
            var line_start: usize = 0;
            for (desc, 0..) |c, idx| {
                if (c == '\n') {
                    putStr(info_x + 2, line_y, desc[line_start..idx], COL_VALUE, COL_BG);
                    line_y += 1;
                    line_start = idx + 1;
                }
            }
            if (line_start < desc.len) {
                putStr(info_x + 2, line_y, desc[line_start..], COL_VALUE, COL_BG);
            }
        }
    }
}

// ─── Unit tests ───────────────────────────────────────────────────
const testing = std.testing;

test "computeIntStep handles scale and direction" {
    // Plain step: ±1 → ±1.
    try testing.expectEqual(@as(i8, 1), computeIntStep(1, 1.0));
    try testing.expectEqual(@as(i8, -1), computeIntStep(-1, 1.0));
    // Shift x5.
    try testing.expectEqual(@as(i8, 5), computeIntStep(1, 5.0));
    try testing.expectEqual(@as(i8, -5), computeIntStep(-1, 5.0));
    // Ctrl fine: 0.1 — would round to 0, but clamped to ±1 so int
    // sliders stay adjustable.
    try testing.expectEqual(@as(i8, 1), computeIntStep(1, 0.1));
    try testing.expectEqual(@as(i8, -1), computeIntStep(-1, 0.1));
}

test "Bootup tab exposes three items in expected order" {
    const items = Tab.items(.bootup);
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(Item.boot_jingle_enabled, items[0]);
    try testing.expectEqual(Item.action_test_jingle_sound, items[1]);
    try testing.expectEqual(Item.action_test_full_intro, items[2]);
}

test "Bootup tab actions classified correctly" {
    try testing.expect(!Item.boot_jingle_enabled.isAction());
    try testing.expect(Item.action_test_jingle_sound.isAction());
    try testing.expect(Item.action_test_full_intro.isAction());
}

test "TABS includes bootup as the last tab" {
    try testing.expectEqual(@as(usize, 6), TABS.len);
    try testing.expectEqual(Tab.bootup, TABS[5]);
}

test "u8_adjust clamps to bounds" {
    try testing.expectEqual(@as(u8, 5), u8_adjust(4, 1, 0, 10));
    try testing.expectEqual(@as(u8, 10), u8_adjust(10, 1, 0, 10)); // upper clamp
    try testing.expectEqual(@as(u8, 0), u8_adjust(0, -1, 0, 10)); // lower clamp
    try testing.expectEqual(@as(u8, 10), u8_adjust(7, 5, 0, 10)); // overshoot clamp
}

test "u16_adjust handles negative delta from any value" {
    try testing.expectEqual(@as(u16, 0), u16_adjust(0, -50, 0, 1000));
    try testing.expectEqual(@as(u16, 950), u16_adjust(1000, -50, 0, 1000));
    try testing.expectEqual(@as(u16, 1000), u16_adjust(990, 50, 0, 1000));
}

test "adjustRainDensity step scales" {
    // Plain ±10 step.
    try testing.expectEqual(@as(u16, 60), adjustRainDensity(50, 1, 1.0));
    try testing.expectEqual(@as(u16, 40), adjustRainDensity(50, -1, 1.0));
    // Shift ×5: ±50 step.
    try testing.expectEqual(@as(u16, 100), adjustRainDensity(50, 1, 5.0));
    try testing.expectEqual(@as(u16, 0), adjustRainDensity(50, -1, 5.0));
    // Ctrl fine: ±1 step.
    try testing.expectEqual(@as(u16, 51), adjustRainDensity(50, 1, 0.1));
    try testing.expectEqual(@as(u16, 49), adjustRainDensity(50, -1, 0.1));
}

test "adjustRainDensity clamps to 0..1000" {
    try testing.expectEqual(@as(u16, 0), adjustRainDensity(5, -1, 5.0));
    try testing.expectEqual(@as(u16, 1000), adjustRainDensity(995, 1, 5.0));
    try testing.expectEqual(@as(u16, 0), adjustRainDensity(0, -1, 1.0));
    try testing.expectEqual(@as(u16, 1000), adjustRainDensity(1000, 1, 1.0));
}

test "adjustDecayFrames step is 50 per keypress, clamped" {
    try testing.expectEqual(@as(u16, 100), adjustDecayFrames(50, 1));
    try testing.expectEqual(@as(u16, 50), adjustDecayFrames(50, -1)); // lower clamp 50
    try testing.expectEqual(@as(u16, 30000), adjustDecayFrames(30000, 1)); // upper clamp
}
