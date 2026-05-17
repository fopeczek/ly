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
    density_div,
    min_drop_len,
    tail_churn_prob,
    dark_run_start_pct,
    dark_run_min,
    dark_run_max,
    // Errors tab
    glitch_seed_permille,
    overlay_initial_ttl,
    overlay_lines_per_burst,
    action_error_burst,
    // Lockout tab
    action_toggle_locked,
    action_reset_fails,
    readout_locked,
    readout_auth_fails,

    pub fn label(self: Item) []const u8 {
        return switch (self) {
            .speed_min => "speed min       ",
            .speed_max => "speed max       ",
            .density_div => "density divisor ",
            .min_drop_len => "min drop length ",
            .tail_churn_prob => "tail churn prob ",
            .dark_run_start_pct => "dark run start %",
            .dark_run_min => "dark run min    ",
            .dark_run_max => "dark run max    ",
            .glitch_seed_permille => "glitch /1000    ",
            .overlay_initial_ttl => "overlay TTL     ",
            .overlay_lines_per_burst => "overlay lines/  ",
            .action_error_burst => "[ trigger error ]",
            .action_toggle_locked => "[ toggle locked ]",
            .action_reset_fails => "[ reset fails   ]",
            .readout_locked => "locked          ",
            .readout_auth_fails => "auth_fails      ",
        };
    }

    pub fn isAction(self: Item) bool {
        return switch (self) {
            .action_error_burst, .action_toggle_locked, .action_reset_fails => true,
            else => false,
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
    errors,
    lockout,

    pub fn name(self: Tab) []const u8 {
        return switch (self) {
            .rain => "Rain",
            .errors => "Errors",
            .lockout => "Lockout",
        };
    }

    pub fn items(self: Tab) []const Item {
        return switch (self) {
            .rain => &[_]Item{
                .speed_min, .speed_max, .density_div, .min_drop_len,
                .tail_churn_prob, .dark_run_start_pct,
                .dark_run_min, .dark_run_max,
            },
            .errors => &[_]Item{
                .glitch_seed_permille, .overlay_initial_ttl,
                .overlay_lines_per_burst, .action_error_burst,
            },
            .lockout => &[_]Item{
                .action_toggle_locked, .action_reset_fails,
                .readout_locked, .readout_auth_fails,
            },
        };
    }
};

const TABS = [_]Tab{ .rain, .errors, .lockout };

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
instance: ?Widget = null,

pub fn init() DebugMenu {
    return .{};
}

pub fn attach(
    self: *DebugMenu,
    matrix_ptr: *Matrix,
    auth_fails_ptr: *u64,
    buffer_ptr: *TerminalBuffer,
) void {
    self.matrix_ptr = matrix_ptr;
    self.auth_fails_ptr = auth_fails_ptr;
    self.buffer_ptr = buffer_ptr;
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
            .action_toggle_locked => r.toggle_locked = true,
            .action_reset_fails => r.reset_fails = true,
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
};

pub fn adjust(self: *DebugMenu, m: *Matrix, delta: i8) ActionResult {
    var r: ActionResult = .{};
    const item = self.currentItem();
    switch (item) {
        .speed_min => m.speed_min = std.math.clamp(m.speed_min + @as(f32, @floatFromInt(delta)) * 0.01, 0.01, m.speed_max),
        .speed_max => m.speed_max = std.math.clamp(m.speed_max + @as(f32, @floatFromInt(delta)) * 0.01, m.speed_min, 2.0),
        .density_div => m.density_div = u8_adjust(m.density_div, delta, 1, 30),
        .min_drop_len => m.min_drop_len = u8_adjust(m.min_drop_len, delta, 2, 40),
        .tail_churn_prob => m.tail_churn_prob = std.math.clamp(m.tail_churn_prob + @as(f32, @floatFromInt(delta)) * 0.01, 0.0, 1.0),
        .dark_run_start_pct => m.dark_run_start_pct = u16_adjust(m.dark_run_start_pct, delta, 0, 100),
        .dark_run_min => m.dark_run_min = u8_adjust(m.dark_run_min, delta, 1, m.dark_run_max),
        .dark_run_max => m.dark_run_max = u8_adjust(m.dark_run_max, delta, m.dark_run_min, 20),
        .glitch_seed_permille => m.glitch_seed_permille = u16_adjust(m.glitch_seed_permille, delta, 0, 1000),
        .overlay_initial_ttl => m.overlay_initial_ttl = u8_adjust(m.overlay_initial_ttl, delta, 1, 50),
        .overlay_lines_per_burst => m.overlay_lines_per_burst = u8_adjust(m.overlay_lines_per_burst, delta, 1, 20),
        .action_error_burst => if (delta > 0) {
            r.fire_error_burst = true;
        },
        .action_toggle_locked => if (delta > 0) {
            r.toggle_locked = true;
        },
        .action_reset_fails => if (delta > 0) {
            r.reset_fails = true;
        },
        .readout_locked, .readout_auth_fails => {},
    }
    return r;
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

// Format an item's current value into the given buffer. Returns the
// portion of buf actually written. The caller embeds this in a
// rendered line like "  speed_min      0.06".
pub fn formatValue(item: Item, m: *const Matrix, auth_fails: u64, buf: []u8) ![]const u8 {
    return switch (item) {
        .speed_min => try std.fmt.bufPrint(buf, "{d:.2}", .{m.speed_min}),
        .speed_max => try std.fmt.bufPrint(buf, "{d:.2}", .{m.speed_max}),
        .density_div => try std.fmt.bufPrint(buf, "{d}", .{m.density_div}),
        .min_drop_len => try std.fmt.bufPrint(buf, "{d}", .{m.min_drop_len}),
        .tail_churn_prob => try std.fmt.bufPrint(buf, "{d:.2}", .{m.tail_churn_prob}),
        .dark_run_start_pct => try std.fmt.bufPrint(buf, "{d}%", .{m.dark_run_start_pct}),
        .dark_run_min => try std.fmt.bufPrint(buf, "{d}", .{m.dark_run_min}),
        .dark_run_max => try std.fmt.bufPrint(buf, "{d}", .{m.dark_run_max}),
        .glitch_seed_permille => try std.fmt.bufPrint(buf, "{d}", .{m.glitch_seed_permille}),
        .overlay_initial_ttl => try std.fmt.bufPrint(buf, "{d}", .{m.overlay_initial_ttl}),
        .overlay_lines_per_burst => try std.fmt.bufPrint(buf, "{d}", .{m.overlay_lines_per_burst}),
        .action_error_burst, .action_toggle_locked, .action_reset_fails => try std.fmt.bufPrint(buf, "<press l>", .{}),
        .readout_locked => try std.fmt.bufPrint(buf, "{s}", .{if (m.locked) "YES" else "no"}),
        .readout_auth_fails => try std.fmt.bufPrint(buf, "{d}", .{auth_fails}),
    };
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
    // value layout (left ~24 chars label, right ~12 chars value).
    const panel_w: usize = 44;
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
    putStr(px + 2, py, " DEBUG MENU ", COL_TAB_ACTIVE, COL_BG);

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
        if (row_y >= py + panel_h - 2) break;
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
        const val = formatValue(item, m, auth_fails, &val_buf) catch "<err>";
        putStr(px + 4 + item.label().len + 1, row_y, val, COL_VALUE, row_bg);
    }

    // Help line at bottom
    const help = if (self.mode == .edit)
        "EDITING: \xe2\x86\x91/\xe2\x86\x93 adjust  Enter/Esc done"
    else
        "\xe2\x86\x91/\xe2\x86\x93 item  Tab tab  Enter edit  Esc close";
    if (help.len < panel_w - 2) {
        putStr(px + 1, py + panel_h - 2, help, COL_HELP, COL_BG);
    } else {
        putStr(px + 1, py + panel_h - 2, "j/k h/l Tab nav", COL_HELP, COL_BG);
    }
}
