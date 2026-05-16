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

pub const FRAME_DELAY: usize = 4;

// Characters change mid-scroll
pub const MID_SCROLL_CHANGE = true;

const Matrix = @This();

pub const Dot = struct {
    value: ?usize,
    is_head: bool,
};

pub const Line = struct {
    space: usize,
    length: usize,
    update: usize,
    // Once the actual head scrolls past the bottom of the screen, this
    // tracks the conceptual head position advancing further down. Cells
    // in the trail body fade based on distance to this virtual head,
    // so the trail continues "falling" off the bottom instead of
    // vanishing instantly. 0 means no off-screen head (trail is either
    // alive on-screen or column is idle).
    virtual_head_y: usize = 0,
};

instance: ?Widget = null,
start_time: TimeOfDay,
allocator: Allocator,
terminal_buffer: *TerminalBuffer,
dots: []Dot,
lines: []Line,
frame: usize,
count: usize,
fg: u32,
head_col: u32,
min_codepoint: u16,
max_codepoint: u16,
animate: *bool,
timeout_sec: u12,
frame_delay: u16,
default_cell: Cell,
tail_fade: bool,

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
        .frame = 3,
        .count = 0,
        .fg = fg,
        .head_col = head_col,
        .min_codepoint = min_codepoint,
        .max_codepoint = max_codepoint - min_codepoint,
        .animate = animate,
        .timeout_sec = timeout_sec,
        .frame_delay = frame_delay,
        .default_cell = .{ .ch = ' ', .fg = fg, .bg = terminal_buffer.bg },
        .tail_fade = tail_fade,
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

fn draw(self: *Matrix) void {
    if (!self.animate.*) return;

    const buf_height = self.terminal_buffer.height;
    const buf_width = self.terminal_buffer.width;
    self.count += 1;
    if (self.count > FRAME_DELAY) {
        self.frame += 1;
        if (self.frame > 4) self.frame = 1;
        self.count = 0;

        var x: usize = 0;
        while (x < buf_width) : (x += 2) {
            var tail: usize = 0;
            var line = &self.lines[x];
            if (self.frame <= line.update) continue;

            // Single-pass scan of this column: gather whether it has any
            // value cells (so we can both decide on spawn AND clear
            // virtual_head_y once the trail is fully gone).
            var column_has_content = false;
            {
                var scan_y: usize = 1;
                while (scan_y <= buf_height) : (scan_y += 1) {
                    const v = self.dots[buf_width * scan_y + x].value;
                    if (v != null and v != ' ') {
                        column_has_content = true;
                        break;
                    }
                }
            }
            if (!column_has_content) line.virtual_head_y = 0;

            if (self.dots[x].value == null and self.dots[buf_width + x].value == ' ') {
                // Only spawn a new raindrop in a truly empty column.
                // Prevents the cmatrix-classic "two heads per column"
                // problem that the user read as stray whites.
                if (!column_has_content) {
                    if (line.space > 0) {
                        line.space -= 1;
                    } else {
                        const randint = self.terminal_buffer.random.int(u16);
                        const h = buf_height;
                        line.length = @mod(randint, h - 3) + 3;
                        self.dots[x].value = @mod(randint, self.max_codepoint) + self.min_codepoint;
                        line.space = @mod(randint, h + 1);
                    }
                }
            }

            var y: usize = 0;
            var first_col = true;
            var seg_len: u64 = 0;
            height_it: while (y <= buf_height) : (y += 1) {
                var dot = &self.dots[buf_width * y + x];
                // Skip over spaces
                while (y <= buf_height and (dot.value == ' ' or dot.value == null)) {
                    y += 1;
                    if (y > buf_height) break :height_it;
                    dot = &self.dots[buf_width * y + x];
                }

                // Find the head of this column
                tail = y;
                seg_len = 0;
                while (y <= buf_height and dot.value != ' ' and dot.value != null) {
                    dot.is_head = false;
                    if (MID_SCROLL_CHANGE) {
                        const randint = self.terminal_buffer.random.int(u16);
                        if (@mod(randint, 8) == 0) {
                            dot.value = @mod(randint, self.max_codepoint) + self.min_codepoint;
                        }
                    }

                    y += 1;
                    seg_len += 1;
                    // Head's down offscreen
                    if (y > buf_height) {
                        self.dots[buf_width * tail + x].value = ' ';
                        // Continue the "head" conceptually past the
                        // bottom of the screen so the trail body fades
                        // out naturally as it falls off, instead of
                        // disappearing the instant the head leaves.
                        if (line.virtual_head_y <= buf_height) {
                            line.virtual_head_y = buf_height + 1;
                        } else {
                            line.virtual_head_y += 1;
                        }
                        break :height_it;
                    }
                    dot = &self.dots[buf_width * y + x];
                }

                const randint = self.terminal_buffer.random.int(u16);
                dot.value = @mod(randint, self.max_codepoint) + self.min_codepoint;
                dot.is_head = true;
                line.virtual_head_y = y;

                if (seg_len > line.length or !first_col) {
                    self.dots[buf_width * tail + x].value = ' ';
                    self.dots[x].value = null;
                }
                first_col = false;
            }
        }
    }

    // Stack-allocated buffer for per-column head positions. A column can
    // host multiple concurrent trails; without per-cell head lookup the
    // fade gets the wrong reference point and cells in lower trails
    // render as full fg (the "bright bottom row" complaint).
    var heads_buf: [512]usize = undefined;

    var x: usize = 0;
    while (x < buf_width) : (x += 2) {
        // Pre-scan all heads in this column (top-to-bottom == ascending y).
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
            // Advance to the first head >= current y. That's THIS cell's trail head.
            while (head_idx < heads.len and heads[head_idx] < y) head_idx += 1;

            const dot = self.dots[buf_width * y + x];
            const cell = if (dot.value == null or dot.value == ' ') self.default_cell else cell_blk: {
                // Pick a head_y to fade against:
                //   - If there's an on-screen is_head for this cell, use that.
                //   - If not, use line.virtual_head_y (head has scrolled past
                //     the bottom; trail keeps falling as virtual_head_y
                //     advances each tick).
                //   - If neither, trail is fully off — render as default_cell.
                const head_y_for_fade: usize = blk: {
                    if (head_idx < heads.len) break :blk heads[head_idx];
                    const vhy = self.lines[x].virtual_head_y;
                    if (vhy == 0 or vhy <= y) break :cell_blk self.default_cell;
                    break :blk vhy;
                };

                const fg_color: u32 = inner: {
                    // DIAGNOSTIC: head_col disabled. Every cell renders
                    // strictly via the fade math. If "white ends" still
                    // appear with this binary, the cause is not the
                    // legitimate head_col but a real rendering bug.
                    // Re-enable by restoring the head check below.
                    // if (dot.is_head and heads.len > 0 and heads[heads.len - 1] == y) {
                    //     break :inner self.head_col;
                    // }
                    if (!self.tail_fade) break :inner self.fg;
                    const distance = head_y_for_fade - y;
                    const tail_len = self.lines[x].length;
                    const denom: f32 = if (tail_len == 0) 1 else @floatFromInt(tail_len);
                    const t_linear = @as(f32, @floatFromInt(distance)) / denom;
                    if (t_linear >= 1.0) break :cell_blk self.default_cell;
                    const t = perceptualT(t_linear);
                    break :inner lerpColor(self.fg, self.terminal_buffer.bg, t);
                };
                break :cell_blk Cell{
                    .ch = @intCast(dot.value.?),
                    .fg = fg_color,
                    .bg = self.terminal_buffer.bg,
                };
            };

            cell.put(x, y - 1);
            // Fill background in between columns
            self.default_cell.put(x + 1, y - 1);
        }
    }
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
    var y: usize = 0;
    while (y <= height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 2) {
            dots[y * width + x].value = null;
        }
    }

    var x: usize = 0;
    while (x < width) : (x += 2) {
        var line = lines[x];
        line.space = @mod(random.int(u16), height) + 1;
        line.length = @mod(random.int(u16), height - 3) + 3;
        line.update = @mod(random.int(u16), 3) + 1;
        lines[x] = line;

        dots[width + x].value = ' ';
    }
}
