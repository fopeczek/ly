const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;

const ly_core = @import("ly-core");
const interop = ly_core.interop;
const LogFile = ly_core.LogFile;
const SharedError = ly_core.SharedError;
pub const termbox = @import("termbox2");

const Cell = @import("Cell.zig");
const keyboard = @import("keyboard.zig");
const Position = @import("Position.zig");
const Widget = @import("Widget.zig");

const TerminalBuffer = @This();

pub const KeybindCallbackFn = *const fn (*anyopaque) anyerror!bool;
pub const KeybindMap = std.AutoHashMap(keyboard.Key, struct {
    callback: KeybindCallbackFn,
    context: *anyopaque,
});

pub const InitOptions = struct {
    fg: u32,
    bg: u32,
    border_fg: u32,
    full_color: bool,
    is_tty: bool,
    // When set, termbox2 initializes on this fd instead of opening
    // /dev/tty itself. Used when ly has swapped controlling TTY (e.g.
    // running inside kmscon with --take-tty=N) — termbox must keep
    // rendering through the original pty fd while ctty points
    // elsewhere for PAM/logind. See interop.swapControllingTty.
    tty_fd: ?c_int = null,
};

pub const Styling = struct {
    pub const BOLD = termbox.TB_BOLD;
    pub const UNDERLINE = termbox.TB_UNDERLINE;
    pub const REVERSE = termbox.TB_REVERSE;
    pub const ITALIC = termbox.TB_ITALIC;
    pub const BLINK = termbox.TB_BLINK;
    pub const HI_BLACK = termbox.TB_HI_BLACK;
    pub const BRIGHT = termbox.TB_BRIGHT;
    pub const DIM = termbox.TB_DIM;
};

pub const Color = struct {
    pub const DEFAULT = 0x00000000;
    pub const TRUE_BLACK = Styling.HI_BLACK;
    pub const TRUE_RED = 0x00FF0000;
    pub const TRUE_GREEN = 0x0000FF00;
    pub const TRUE_YELLOW = 0x00FFFF00;
    pub const TRUE_BLUE = 0x000000FF;
    pub const TRUE_MAGENTA = 0x00FF00FF;
    pub const TRUE_CYAN = 0x0000FFFF;
    pub const TRUE_WHITE = 0x00FFFFFF;
    pub const TRUE_DIM_RED = 0x00800000;
    pub const TRUE_DIM_GREEN = 0x00008000;
    pub const TRUE_DIM_YELLOW = 0x00808000;
    pub const TRUE_DIM_BLUE = 0x00000080;
    pub const TRUE_DIM_MAGENTA = 0x00800080;
    pub const TRUE_DIM_CYAN = 0x00008080;
    pub const TRUE_DIM_WHITE = 0x00C0C0C0;
    pub const ECOL_BLACK = 1;
    pub const ECOL_RED = 2;
    pub const ECOL_GREEN = 3;
    pub const ECOL_YELLOW = 4;
    pub const ECOL_BLUE = 5;
    pub const ECOL_MAGENTA = 6;
    pub const ECOL_CYAN = 7;
    pub const ECOL_WHITE = 8;
};

pub const START_POSITION = Position.init(0, 0);

log_file: *LogFile,
random: Random,
width: usize,
height: usize,
fg: u32,
bg: u32,
border_fg: u32,
box_chars: struct {
    left_up: u32,
    left_down: u32,
    right_up: u32,
    right_down: u32,
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,
},
blank_cell: Cell,
full_color: bool,
termios: ?std.posix.termios,
keybinds: KeybindMap,
handlable_widgets: std.ArrayList(*Widget),
run: bool,
update: bool,
active_widget_index: usize,
// Layers and context captured by runEventLoop so other code paths
// (notably the auth wait-pump in main.zig::authenticate) can call
// renderOneFrame() without re-threading them through every fn that
// might need to drive a frame. null until runEventLoop sets them.
current_layers: ?[][]*Widget,
current_context: ?*anyopaque,

pub fn init(
    allocator: Allocator,
    io: std.Io,
    options: InitOptions,
    log_file: *LogFile,
    random: Random,
) !TerminalBuffer {
    // Initialize termbox. If the caller provided a tty_fd (the kmscon
    // pty fd saved before ctty swap), use it directly so rendering
    // stays routed through kmscon; otherwise let termbox open /dev/tty.
    if (options.tty_fd) |fd| {
        _ = termbox.tb_init_fd(fd);
    } else {
        _ = termbox.tb_init();
    }

    if (options.full_color) {
        _ = termbox.tb_set_output_mode(termbox.TB_OUTPUT_TRUECOLOR);
        try log_file.info(io, "tui", "termbox2 set to 24-bit color output mode", .{});
    } else {
        try log_file.info(io, "tui", "termbox2 set to eight-color output mode", .{});
    }

    _ = termbox.tb_clear();

    // Let's take some precautions here and clear the back buffer as well
    try clearBackBuffer();

    const width: usize = @intCast(termbox.tb_width());
    const height: usize = @intCast(termbox.tb_height());

    try log_file.info(io, "tui", "screen resolution is {d}x{d}", .{ width, height });

    return .{
        .log_file = log_file,
        .random = random,
        .width = width,
        .height = height,
        .fg = options.fg,
        .bg = options.bg,
        .border_fg = options.border_fg,
        .box_chars = if (interop.supportsUnicode()) .{
            .left_up = 0x250C,
            .left_down = 0x2514,
            .right_up = 0x2510,
            .right_down = 0x2518,
            .top = 0x2500,
            .bottom = 0x2500,
            .left = 0x2502,
            .right = 0x2502,
        } else .{
            .left_up = '+',
            .left_down = '+',
            .right_up = '+',
            .right_down = '+',
            .top = '-',
            .bottom = '-',
            .left = '|',
            .right = '|',
        },
        .blank_cell = Cell.init(' ', options.fg, options.bg),
        .full_color = options.full_color,
        // Needed to reclaim the TTY after giving up its control
        .termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO),
        .keybinds = KeybindMap.init(allocator),
        .handlable_widgets = .empty,
        .run = true,
        .update = true,
        .active_widget_index = 0,
        .current_layers = null,
        .current_context = null,
    };
}

pub fn deinit(self: *TerminalBuffer) void {
    self.keybinds.deinit();
    TerminalBuffer.shutdown();
}

pub fn runEventLoop(
    self: *TerminalBuffer,
    allocator: Allocator,
    io: std.Io,
    shared_error: SharedError,
    layers: [][]*Widget,
    active_widget: *Widget,
    inactivity_delay: u16,
    position_widgets_fn: *const fn (*anyopaque) anyerror!void,
    inactivity_event_fn: ?*const fn (*anyopaque) anyerror!void,
    context: *anyopaque,
) !void {
    // Default cursor-wrap bindings. Skip re-registering if the caller
    // (e.g. main.zig's debug-menu overrides) already bound them —
    // runEventLoop is called AFTER main.zig finishes its keybind
    // setup, and without this check the defaults would silently
    // clobber whatever main registered for these keys.
    try self.maybeRegisterGlobalKeybind(io, "Ctrl+K", &moveCursorUp, self);
    try self.maybeRegisterGlobalKeybind(io, "Up", &moveCursorUp, self);
    try self.maybeRegisterGlobalKeybind(io, "Ctrl+J", &moveCursorDown, self);
    try self.maybeRegisterGlobalKeybind(io, "Down", &moveCursorDown, self);
    try self.maybeRegisterGlobalKeybind(io, "Tab", &wrapCursor, self);
    try self.maybeRegisterGlobalKeybind(io, "Shift+Tab", &wrapCursorReverse, self);

    defer self.handlable_widgets.deinit(allocator);

    var i: usize = 0;
    for (layers) |layer| {
        for (layer) |widget| {
            try widget.update(context);

            if (widget.vtable.handle_fn != null) {
                try self.handlable_widgets.append(allocator, widget);

                if (widget.id == active_widget.id) self.active_widget_index = i;
                i += 1;
            }
        }
    }

    try @call(.auto, position_widgets_fn, .{context});

    // Stash layers + context so external callers (auth wait-pump)
    // can drive a frame via renderOneFrame.
    self.current_layers = layers;
    self.current_context = context;

    var event: termbox.tb_event = undefined;
    var inactivity_cmd_ran = false;
    var inactivity_time_start = try interop.getTimeOfDay();

    while (self.run) {
        var maybe_timeout: ?usize = null;

        if (self.update) {
            maybe_timeout = try self.renderOneFrame(io, shared_error);
        }

        if (inactivity_event_fn) |inactivity_fn| {
            const time = try interop.getTimeOfDay();

            if (!inactivity_cmd_ran and time.seconds - inactivity_time_start.seconds > inactivity_delay) {
                try @call(.auto, inactivity_fn, .{context});
                inactivity_cmd_ran = true;
            }
        }

        const event_error = if (maybe_timeout) |timeout| termbox.tb_peek_event(&event, @intCast(timeout)) else termbox.tb_poll_event(&event);

        self.update = maybe_timeout != null or event_error >= 0;

        if (event_error < 0) continue;

        // Input of some kind was detected, so reset the inactivity timer
        inactivity_time_start = try interop.getTimeOfDay();

        if (event.type == termbox.TB_EVENT_RESIZE) {
            self.width = TerminalBuffer.getWidth();
            self.height = TerminalBuffer.getHeight();

            try self.log_file.info(
                io,
                "tui",
                "screen resolution updated to {d}x{d}",
                .{ self.width, self.height },
            );

            for (layers) |layer| {
                for (layer) |widget| {
                    widget.realloc() catch |err| {
                        shared_error.writeError(error.WidgetReallocationFailed);
                        try self.log_file.err(
                            io,
                            "tui",
                            "failed to reallocate widget '{s}': {s}",
                            .{ widget.display_name, @errorName(err) },
                        );
                    };
                }
            }

            try @call(.auto, position_widgets_fn, .{context});

            self.update = true;
            continue;
        }

        var maybe_keys = try self.handleKeybind(allocator, event);
        if (maybe_keys) |*keys| {
            defer keys.deinit(allocator);

            const current_widget = self.getActiveWidget();
            for (keys.items) |key| {
                current_widget.handle(key) catch |err| {
                    shared_error.writeError(error.CurrentWidgetHandlingFailed);
                    try self.log_file.err(
                        io,
                        "tui",
                        "failed to handle active widget '{s}': {s}",
                        .{ current_widget.display_name, @errorName(err) },
                    );
                };
            }

            self.update = true;
        }
    }
}

// Render one frame of the UI: clear, run handle on active widget,
// update + draw every widget in every layer, hide cursor, present.
// Returns the smallest widget timeout (used by runEventLoop to set
// tb_peek_event's deadline). Layers come from `current_layers` set
// by runEventLoop on start. Called both from runEventLoop's main
// loop AND from the auth wait-pump (so the matrix animation keeps
// ticking while PAM is checking the password).
pub fn renderOneFrame(
    self: *TerminalBuffer,
    io: std.Io,
    shared_error: SharedError,
) !?usize {
    const layers = self.current_layers orelse return null;
    const context = self.current_context orelse return null;

    try TerminalBuffer.clearScreen(false);

    // Reset cursor via active widget's handle().
    const current_widget = self.getActiveWidget();
    current_widget.handle(null) catch |err| {
        shared_error.writeError(error.SetCursorFailed);
        try self.log_file.err(
            io,
            "tui",
            "failed to set cursor in active widget '{s}': {s}",
            .{ current_widget.display_name, @errorName(err) },
        );
    };

    var maybe_timeout: ?usize = null;
    for (layers) |layer| {
        for (layer) |widget| {
            try widget.update(context);
            widget.draw();
            if (try widget.calculateTimeout(context)) |t| {
                if (maybe_timeout == null or t < maybe_timeout.?) maybe_timeout = t;
            }
        }
    }

    // Hide the cursor before flushing — termbox2's tb_set_cursor
    // clamps negative coords to (0,0) rather than hiding; must use
    // tb_hide_cursor() proper. Otherwise kmscon renders the pty
    // cursor as a visible block over the matrix.
    _ = termbox.tb_hide_cursor();
    TerminalBuffer.presentBuffer();

    // Consume any pending SIGUSR1 snapshot request.
    if (snapshot_request.swap(false, .seq_cst)) {
        writeSnapshot(io, "/tmp/ly-snapshot.txt") catch |err| {
            self.log_file.err(io, "tui", "snapshot failed: {s}", .{@errorName(err)}) catch {};
        };
    }

    return maybe_timeout;
}

pub fn stopEventLoop(self: *TerminalBuffer) void {
    self.run = false;
}

pub fn drawNextFrame(self: *TerminalBuffer, value: bool) void {
    self.update = value;
}

pub fn getActiveWidget(self: *TerminalBuffer) *Widget {
    return self.handlable_widgets.items[self.active_widget_index];
}

pub fn setActiveWidget(self: *TerminalBuffer, widget: *Widget) void {
    for (self.handlable_widgets.items, 0..) |widg, i| {
        if (widg.id == widget.id) self.active_widget_index = i;
    }
}

pub fn getWidth() usize {
    return @intCast(termbox.tb_width());
}

pub fn getHeight() usize {
    return @intCast(termbox.tb_height());
}

pub fn setCursor(x: usize, y: usize) void {
    _ = termbox.tb_set_cursor(@intCast(x), @intCast(y));
}

pub fn hideCursor() void {
    // termbox2 hides the cursor when given negative coordinates.
    _ = termbox.tb_set_cursor(-1, -1);
}

pub fn clearScreen(clear_back_buffer: bool) !void {
    _ = termbox.tb_clear();
    if (clear_back_buffer) try clearBackBuffer();
}

pub fn shutdown() void {
    _ = termbox.tb_shutdown();
}

pub fn presentBuffer() void {
    _ = termbox.tb_present();
}

// ─── Snapshot facility ────────────────────────────────────────────
// Async-signal-safe flag flipped by main()'s SIGUSR1 handler.
// runEventLoop consumes the flag after each present() and writes
// the current back buffer to /tmp/ly-snapshot.txt as ANSI-truecolor
// text — lets an out-of-band observer `cat` the file and see what
// the greeter is rendering on its own VT, without VT-switching.
pub var snapshot_request = std.atomic.Value(bool).init(false);

pub fn requestSnapshot() void {
    snapshot_request.store(true, .seq_cst);
}

// Dump the back buffer to `path` as a UTF-8 ANSI-coloured text file.
// One terminal row per text line; each cell encoded as truecolor
// CSI escapes + glyph; SGR 0 reset at end of each row. Caller-side
// `cat` of the file in any truecolor-capable terminal reproduces
// the on-screen image (within the limits of font availability).
pub fn writeSnapshot(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{
        .permissions = .fromMode(0o644),
    });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    var w = &fw.interface;

    const w_int = termbox.tb_width();
    const h_int = termbox.tb_height();

    var y: c_int = 0;
    while (y < h_int) : (y += 1) {
        // Reset SGR at the start of each row so per-row fg/bg state
        // can't leak between lines if the dump is truncated.
        try w.writeAll("\x1b[0m");
        var prev_fg: u32 = 0xFFFFFFFF;
        var prev_bg: u32 = 0xFFFFFFFF;
        var x: c_int = 0;
        while (x < w_int) : (x += 1) {
            var maybe_cell: ?*termbox.tb_cell = undefined;
            if (termbox.tb_get_cell(x, y, 1, &maybe_cell) != 0) continue;
            const cell = maybe_cell orelse continue;
            const fg: u32 = @as(u32, @intCast(cell.fg)) & 0x00FFFFFF;
            const bg: u32 = @as(u32, @intCast(cell.bg)) & 0x00FFFFFF;
            if (fg != prev_fg) {
                try w.print("\x1b[38;2;{d};{d};{d}m", .{ (fg >> 16) & 0xFF, (fg >> 8) & 0xFF, fg & 0xFF });
                prev_fg = fg;
            }
            if (bg != prev_bg) {
                try w.print("\x1b[48;2;{d};{d};{d}m", .{ (bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF });
                prev_bg = bg;
            }
            const ch = cell.ch;
            if (ch == 0 or ch == ' ') {
                try w.writeByte(' ');
            } else {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(ch), &utf8) catch {
                    try w.writeByte('?');
                    continue;
                };
                try w.writeAll(utf8[0..n]);
            }
        }
        try w.writeAll("\x1b[0m\n");
    }
    try w.flush();
}

pub fn getCell(x: usize, y: usize) ?Cell {
    var maybe_cell: ?*termbox.tb_cell = undefined;
    _ = termbox.tb_get_cell(
        @intCast(x),
        @intCast(y),
        1,
        &maybe_cell,
    );

    if (maybe_cell) |cell| {
        return Cell.init(cell.ch, cell.fg, cell.bg);
    }

    return null;
}

pub fn setCell(x: usize, y: usize, cell: Cell) void {
    _ = termbox.tb_set_cell(
        @intCast(x),
        @intCast(y),
        cell.ch,
        cell.fg,
        cell.bg,
    );
}

pub fn setCellBoundsChecked(self: *TerminalBuffer, x: isize, y: isize, cell: Cell) void {
    if (0 <= x and x < self.width and 0 <= y and y < self.height) {
        cell.put(@intCast(x), @intCast(y));
    }
}

pub fn reclaim(self: TerminalBuffer) !void {
    if (self.termios) |termios| {
        // Take back control of the TTY
        _ = termbox.tb_init();

        if (self.full_color) {
            _ = termbox.tb_set_output_mode(termbox.TB_OUTPUT_TRUECOLOR);
        }

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, termios);
    }
}

pub fn registerKeybind(
    self: *TerminalBuffer,
    io: std.Io,
    keybinds: *KeybindMap,
    keybind: []const u8,
    callback: KeybindCallbackFn,
    context: *anyopaque,
) !void {
    const key = try self.parseKeybind(io, keybind);

    keybinds.put(key, .{
        .callback = callback,
        .context = context,
    }) catch |err| {
        try self.log_file.err(
            io,
            "tui",
            "failed to register keybind {s}: {s}",
            .{ keybind, @errorName(err) },
        );
    };
}

pub fn registerGlobalKeybind(
    self: *TerminalBuffer,
    io: std.Io,
    keybind: []const u8,
    callback: KeybindCallbackFn,
    context: *anyopaque,
) !void {
    try self.registerKeybind(io, &self.keybinds, keybind, callback, context);
}

// Like registerGlobalKeybind but a no-op if the key is already bound.
// Used by runEventLoop's default bindings so caller-side overrides
// (e.g. main.zig's debug-menu Tab handler) survive — runEventLoop's
// setup happens AFTER main's keybind registrations, and without this
// the defaults would clobber whatever main bound.
pub fn maybeRegisterGlobalKeybind(
    self: *TerminalBuffer,
    io: std.Io,
    keybind: []const u8,
    callback: KeybindCallbackFn,
    context: *anyopaque,
) !void {
    const key = try self.parseKeybind(io, keybind);
    if (self.keybinds.get(key) != null) return;
    try self.registerKeybind(io, &self.keybinds, keybind, callback, context);
}

pub fn simulateKeybind(self: *TerminalBuffer, io: std.Io, keybind: []const u8) !bool {
    const key = try self.parseKeybind(io, keybind);

    if (self.keybinds.get(key)) |binding| {
        return try @call(
            .auto,
            binding.callback,
            .{binding.context},
        );
    }

    const current_widget = self.getActiveWidget();
    if (current_widget.keybinds) |keybinds| {
        if (keybinds.get(key)) |binding| {
            return try @call(
                .auto,
                binding.callback,
                .{binding.context},
            );
        }
    }

    return true;
}

pub fn drawText(
    text: []const u8,
    x: usize,
    y: usize,
    fg: u32,
    bg: u32,
) void {
    const yc: c_int = @intCast(y);
    const utf8view = std.unicode.Utf8View.init(text) catch return;
    var utf8 = utf8view.iterator();

    var i: c_int = @intCast(x);
    while (utf8.nextCodepoint()) |codepoint| : (i += termbox.tb_wcwidth(codepoint)) {
        _ = termbox.tb_set_cell(i, yc, codepoint, fg, bg);
    }
}

pub fn drawConfinedText(
    text: []const u8,
    x: usize,
    y: usize,
    max_length: usize,
    fg: u32,
    bg: u32,
) void {
    const yc: c_int = @intCast(y);
    const utf8view = std.unicode.Utf8View.init(text) catch return;
    var utf8 = utf8view.iterator();

    var i: c_int = @intCast(x);
    while (utf8.nextCodepoint()) |codepoint| : (i += termbox.tb_wcwidth(codepoint)) {
        if (i - @as(c_int, @intCast(x)) >= max_length) break;
        _ = termbox.tb_set_cell(i, yc, codepoint, fg, bg);
    }
}

pub fn drawCharMultiple(
    char: u32,
    x: usize,
    y: usize,
    length: usize,
    fg: u32,
    bg: u32,
) void {
    const cell = Cell.init(char, fg, bg);
    for (0..length) |xx| cell.put(x + xx, y);
}

// Every codepoint is assumed to have a width of 1.
// Since Ly is normally running in a TTY, this should be fine.
pub fn strWidth(str: []const u8) usize {
    const utf8view = std.unicode.Utf8View.init(str) catch return str.len;
    var utf8 = utf8view.iterator();
    var length: c_int = 0;

    while (utf8.nextCodepoint()) |codepoint| {
        length += termbox.tb_wcwidth(codepoint);
    }

    return @intCast(length);
}

fn clearBackBuffer() !void {
    // Clear the TTY because termbox2 doesn't seem to do it properly
    const capability = termbox.global.caps[termbox.TB_CAP_CLEAR_SCREEN];
    const capability_slice = std.mem.span(capability);
    const result = std.posix.system.write(termbox.global.ttyfd, capability_slice.ptr, capability_slice.len);

    if (result != capability_slice.len) return error.PartialClearBackBuffer;
    if (result < 0) return error.ClearBackBufferFailed;
}

fn parseKeybind(self: *TerminalBuffer, io: std.Io, keybind: []const u8) !keyboard.Key {
    var key = std.mem.zeroes(keyboard.Key);
    var iterator = std.mem.splitScalar(u8, keybind, '+');

    while (iterator.next()) |item| {
        var found = false;

        inline for (std.meta.fields(keyboard.Key)) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, item)) {
                @field(key, field.name) = true;
                found = true;
                break;
            }
        }

        if (!found) {
            try self.log_file.err(
                io,
                "tui",
                "failed to parse key {s} of keybind {s}",
                .{ item, keybind },
            );
        }
    }

    return key;
}

fn handleKeybind(
    self: *TerminalBuffer,
    allocator: Allocator,
    tb_event: termbox.tb_event,
) !?std.ArrayList(keyboard.Key) {
    var keys = try keyboard.getKeyList(allocator, tb_event);

    for (keys.items) |key| {
        if (self.keybinds.get(key)) |binding| {
            const passthrough_event = try @call(
                .auto,
                binding.callback,
                .{binding.context},
            );

            if (!passthrough_event) {
                keys.deinit(allocator);
                return null;
            }

            return keys;
        }

        const current_widget = self.getActiveWidget();
        if (current_widget.keybinds) |keybinds| {
            if (keybinds.get(key)) |binding| {
                const passthrough_event = try @call(
                    .auto,
                    binding.callback,
                    .{binding.context},
                );

                if (!passthrough_event) {
                    keys.deinit(allocator);
                    return null;
                }

                return keys;
            }
        }
    }

    return keys;
}

fn moveCursorUp(ptr: *anyopaque) !bool {
    var state: *TerminalBuffer = @ptrCast(@alignCast(ptr));
    if (state.active_widget_index == 0) return false;

    state.active_widget_index -= 1;
    state.update = true;
    return false;
}

fn moveCursorDown(ptr: *anyopaque) !bool {
    var state: *TerminalBuffer = @ptrCast(@alignCast(ptr));
    if (state.active_widget_index == state.handlable_widgets.items.len - 1) return false;

    state.active_widget_index += 1;
    state.update = true;
    return false;
}

fn wrapCursor(ptr: *anyopaque) !bool {
    var state: *TerminalBuffer = @ptrCast(@alignCast(ptr));

    state.active_widget_index = (state.active_widget_index + 1) % state.handlable_widgets.items.len;
    state.update = true;
    return false;
}

fn wrapCursorReverse(ptr: *anyopaque) !bool {
    var state: *TerminalBuffer = @ptrCast(@alignCast(ptr));

    state.active_widget_index = if (state.active_widget_index == 0) state.handlable_widgets.items.len - 1 else state.active_widget_index - 1;
    state.update = true;
    return false;
}
