const std = @import("std");

const Cell = @import("../Cell.zig");
const Position = @import("../Position.zig");
const TerminalBuffer = @import("../TerminalBuffer.zig");
const Widget = @import("../Widget.zig");

const Box = @This();

instance: ?Widget = null,
buffer: *TerminalBuffer,
horizontal_margin: usize,
vertical_margin: usize,
width: usize,
height: usize,
show_borders: bool,
blank_box: bool,
top_title: ?[]const u8,
bottom_title: ?[]const u8,
border_fg: u32,
title_fg: u32,
bg: u32,
update_fn: ?*const fn (*Box, *anyopaque) anyerror!void,
left_pos: Position,
right_pos: Position,
children_pos: Position,

pub fn init(
    buffer: *TerminalBuffer,
    horizontal_margin: usize,
    vertical_margin: usize,
    width: usize,
    height: usize,
    show_borders: bool,
    blank_box: bool,
    top_title: ?[]const u8,
    bottom_title: ?[]const u8,
    border_fg: u32,
    title_fg: u32,
    bg: u32,
    update_fn: ?*const fn (*Box, *anyopaque) anyerror!void,
) Box {
    return .{
        .instance = null,
        .buffer = buffer,
        .horizontal_margin = horizontal_margin,
        .vertical_margin = vertical_margin,
        .width = width,
        .height = height,
        .show_borders = show_borders,
        .blank_box = blank_box,
        .top_title = top_title,
        .bottom_title = bottom_title,
        .border_fg = border_fg,
        .title_fg = title_fg,
        .bg = bg,
        .update_fn = update_fn,
        .left_pos = TerminalBuffer.START_POSITION,
        .right_pos = TerminalBuffer.START_POSITION,
        .children_pos = TerminalBuffer.START_POSITION,
    };
}

pub fn widget(self: *Box) *Widget {
    if (self.instance) |*instance| return instance;
    self.instance = Widget.init(
        "Box",
        null,
        self,
        null,
        null,
        draw,
        update,
        null,
        null,
    );
    return &self.instance.?;
}

pub fn positionXY(self: *Box, original_pos: Position) void {
    if (self.buffer.width < 2 or self.buffer.height < 2) return;

    self.left_pos = original_pos;
    self.right_pos = Position.init(
        @min(self.buffer.width, self.width),
        @min(self.buffer.height, self.height),
    ).add(self.left_pos);

    self.children_pos = Position.init(
        self.horizontal_margin,
        self.vertical_margin,
    ).add(self.left_pos);
}

pub fn childrenPosition(self: Box) Position {
    return self.children_pos;
}

fn draw(self: *Box) void {
    if (self.show_borders) {
        var left_up = Cell.init(
            self.buffer.box_chars.left_up,
            self.border_fg,
            self.bg,
        );
        var right_up = Cell.init(
            self.buffer.box_chars.right_up,
            self.border_fg,
            self.bg,
        );
        var left_down = Cell.init(
            self.buffer.box_chars.left_down,
            self.border_fg,
            self.bg,
        );
        var right_down = Cell.init(
            self.buffer.box_chars.right_down,
            self.border_fg,
            self.bg,
        );
        var top = Cell.init(
            self.buffer.box_chars.top,
            self.border_fg,
            self.bg,
        );
        var bottom = Cell.init(
            self.buffer.box_chars.bottom,
            self.border_fg,
            self.bg,
        );

        left_up.put(self.left_pos.x - 1, self.left_pos.y - 1);
        right_up.put(self.right_pos.x, self.left_pos.y - 1);
        left_down.put(self.left_pos.x - 1, self.right_pos.y);
        right_down.put(self.right_pos.x, self.right_pos.y);

        for (0..self.width) |i| {
            top.put(self.left_pos.x + i, self.left_pos.y - 1);
            bottom.put(self.left_pos.x + i, self.right_pos.y);
        }

        top.ch = self.buffer.box_chars.left;
        bottom.ch = self.buffer.box_chars.right;

        for (0..self.height) |i| {
            top.put(self.left_pos.x - 1, self.left_pos.y + i);
            bottom.put(self.right_pos.x, self.left_pos.y + i);
        }
    }

    if (self.blank_box) {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.buffer.blank_cell.put(self.left_pos.x + x, self.left_pos.y + y);
            }
        }
    }

    // Titles render centered in the top/bottom border with a single
    // space of padding on each side, so they read as `── title ──`
    // rather than the legacy left-flush `┌title────` which collided
    // visually with the corner glyph. Fallback to left-flush when
    // the border is too narrow to center cleanly (title + 4 padding
    // chars must fit inside `width`).
    if (self.top_title) |title| {
        drawCenteredTitle(self, title, self.left_pos.y - 1);
    }
    if (self.bottom_title) |title| {
        drawCenteredTitle(self, title, self.left_pos.y + self.height);
    }
}

fn drawCenteredTitle(self: *Box, title: []const u8, y: usize) void {
    const title_w = TerminalBuffer.strWidth(title);
    const has_room = self.width >= title_w + 4;
    const x_off: usize = if (has_room) (self.width - title_w) / 2 else 0;
    if (has_room) {
        // 1-cell space pad on each side — overwrites the dashes that
        // would otherwise touch the title's first/last char.
        TerminalBuffer.drawCharMultiple(' ', self.left_pos.x + x_off - 1, y, 1, self.title_fg, self.bg);
        TerminalBuffer.drawCharMultiple(' ', self.left_pos.x + x_off + title_w, y, 1, self.title_fg, self.bg);
    }
    TerminalBuffer.drawConfinedText(
        title,
        self.left_pos.x + x_off,
        y,
        self.width,
        self.title_fg,
        self.bg,
    );
}

fn update(self: *Box, ctx: *anyopaque) !void {
    if (self.update_fn) |update_fn| {
        return @call(
            .auto,
            update_fn,
            .{ self, ctx },
        );
    }
}
