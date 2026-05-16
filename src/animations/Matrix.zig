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

pub const FRAME_DELAY: usize = 8;

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

// Linear interpolation between two RGBA-ish u32 colors. Preserves alpha/styling byte from `a`.
fn lerpColor(a: u32, b: u32, t: f32) u32 {
    const t_clamped: f32 = if (t < 0) 0 else if (t > 1) 1 else t;
    const a_r: f32 = @floatFromInt((a >> 16) & 0xFF);
    const a_g: f32 = @floatFromInt((a >> 8) & 0xFF);
    const a_b: f32 = @floatFromInt(a & 0xFF);
    const b_r: f32 = @floatFromInt((b >> 16) & 0xFF);
    const b_g: f32 = @floatFromInt((b >> 8) & 0xFF);
    const b_b: f32 = @floatFromInt(b & 0xFF);
    const r_raw: f32 = a_r + t_clamped * (b_r - a_r);
    const g_raw: f32 = a_g + t_clamped * (b_g - a_g);
    const b_raw: f32 = a_b + t_clamped * (b_b - a_b);
    // Snap each channel onto the 256-color cube ladder (0, 95, 135, 175,
    // 215, 255). Doing this in-house gives a guaranteed-distinct ramp on
    // the Linux VT framebuffer, whose console driver collapses many
    // 24-bit values to the same palette index. With raw lerp we'd often
    // see only two visible shades (full and "the other one"); snapping
    // forces six discrete stops that the framebuffer reliably renders.
    const r: u32 = snapToCube(r_raw);
    const g: u32 = snapToCube(g_raw);
    const bl: u32 = snapToCube(b_raw);
    return (a & 0xFF000000) | (r << 16) | (g << 8) | bl;
}

fn snapToCube(v: f32) u32 {
    // Linux kernel framebuffer console snaps 24-bit values to the legacy
    // VGA 16-color palette via nearest-distance matching. Verified
    // empirically on this hardware (kernel 6.18 + amdgpudrmfb): only
    // ~3 distinguishable green stops are visible — bright, medium, and
    // black — even though the framebuffer is 32 bpp.
    //
    // So instead of pretending we have a 6-step cube and watching the
    // kernel collapse it back to 2 visible shades, snap to the 3 stops
    // that actually render distinctly. Trail looks like:
    //     [bright][bright]...[medium]...[black][black]
    // which matches what the user perceives as a "fade".
    const clamped: f32 = if (v < 0) 0 else if (v > 255) 255 else v;
    if (clamped < 35) return 0;
    if (clamped < 170) return 100;
    return 255;
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

            if (self.dots[x].value == null and self.dots[buf_width + x].value == ' ') {
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
                        break :height_it;
                    }
                    dot = &self.dots[buf_width * y + x];
                }

                const randint = self.terminal_buffer.random.int(u16);
                dot.value = @mod(randint, self.max_codepoint) + self.min_codepoint;
                dot.is_head = true;

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
                const fg_color: u32 = blk: {
                    if (!self.tail_fade) {
                        // Classic cmatrix: bright head, uniform trail.
                        if (dot.is_head) break :blk self.head_col;
                        break :blk self.fg;
                    }
                    // tail_fade: smooth gradient from fg at head down to bg at
                    // tail end. head_col ignored — a discrete white pop on
                    // the head breaks the smoothness.
                    // Orphan cell (its trail's head has scrolled off-screen).
                    // Render as fully faded — these are the oldest cells of
                    // a dying trail, so they should already be invisible.
                    if (head_idx >= heads.len) break :blk self.terminal_buffer.bg;
                    const hy = heads[head_idx];
                    const distance = hy - y;
                    const tail_len = self.lines[x].length;
                    const denom: f32 = if (tail_len == 0) 1 else @floatFromInt(tail_len);
                    // Linear interpolation along the trail. With 24-bit
                    // truecolor enabled (full_color=true, default) the kernel
                    // TTY does render intermediate shades — quadratic
                    // easing made the fade too concentrated at the very
                    // top of the trail; linear gives a more visible ramp.
                    const t = @as(f32, @floatFromInt(distance)) / denom;
                    break :blk lerpColor(self.fg, self.terminal_buffer.bg, t);
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
