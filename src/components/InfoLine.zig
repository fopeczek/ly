const std = @import("std");
const Allocator = std.mem.Allocator;

const ly_ui = @import("ly-ui");
const keyboard = ly_ui.keyboard;
const TerminalBuffer = ly_ui.TerminalBuffer;
const Widget = ly_ui.Widget;
const CyclableLabel = ly_ui.CyclableLabel;

const MessageLabel = CyclableLabel(Message, Message);

const InfoLine = @This();

const Message = struct {
    width: usize,
    text: []const u8,
    bg: u32,
    fg: u32,
};

instance: ?Widget = null,
label: *MessageLabel,

pub fn init(
    allocator: Allocator,
    io: std.Io,
    buffer: *TerminalBuffer,
    width: usize,
    arrow_fg: u32,
    arrow_bg: u32,
) !InfoLine {
    return .{
        .instance = null,
        .label = try MessageLabel.init(
            allocator,
            io,
            buffer,
            drawItem,
            null,
            null,
            width,
            true,
            arrow_fg,
            arrow_bg,
        ),
    };
}

pub fn deinit(self: *InfoLine) void {
    self.label.deinit();
}

pub fn widget(self: *InfoLine) *Widget {
    if (self.instance) |*instance| return instance;
    self.instance = Widget.init(
        "InfoLine",
        self.label.keybinds,
        self,
        deinit,
        null,
        draw,
        null,
        handle,
        null,
    );
    return &self.instance.?;
}

pub fn addMessage(self: *InfoLine, text: []const u8, bg: u32, fg: u32) !void {
    if (text.len == 0) return;

    // Replace any prior message rather than appending. The InfoLine
    // widget is supposed to be a status display, not a navigable history
    // — keeping a list lets the user cycle into stale messages like
    // "authenticating..." which is confusing.
    self.label.list.clearRetainingCapacity();
    self.label.current = 0;

    try self.label.addItem(.{
        .width = TerminalBuffer.strWidth(text),
        .text = text,
        .bg = bg,
        .fg = fg,
    });
}

pub fn clearRendered(self: InfoLine, allocator: Allocator) !void {
    // Draw over the area
    const spaces = try allocator.alloc(u8, self.label.width - 2);
    defer allocator.free(spaces);

    @memset(spaces, ' ');

    TerminalBuffer.drawText(
        spaces,
        self.label.component_pos.x + 2,
        self.label.component_pos.y,
        TerminalBuffer.Color.DEFAULT,
        TerminalBuffer.Color.DEFAULT,
    );
}

fn draw(self: *InfoLine) void {
    // Custom draw — bypasses CyclableLabel.draw() so the `<` and `>` arrows
    // don't render. Info line shows a single current message; not navigable.
    const label = self.label;
    if (label.list.items.len == 0) return;
    if (label.width < 2) return;

    const current_item = label.list.items[label.current];
    if (current_item.width == 0) return;

    const inner_width = label.width - 2;
    const x = label.component_pos.x + 2;
    const y = label.component_pos.y;

    const x_offset = if (label.text_in_center and inner_width >= current_item.width)
        (inner_width - current_item.width) / 2
    else
        0;

    label.cursor = current_item.width + x_offset;
    TerminalBuffer.drawConfinedText(
        current_item.text,
        x + x_offset,
        y,
        inner_width,
        current_item.fg,
        current_item.bg,
    );
}

fn handle(self: *InfoLine, maybe_key: ?keyboard.Key) !void {
    self.label.handle(maybe_key);
}

fn drawItem(label: *MessageLabel, message: Message, x: usize, y: usize, width: usize) void {
    if (message.width == 0) return;

    const x_offset = if (label.text_in_center and width >= message.width) (width - message.width) / 2 else 0;

    label.cursor = message.width + x_offset;
    TerminalBuffer.drawConfinedText(
        message.text,
        x + x_offset,
        y,
        width,
        message.fg,
        message.bg,
    );
}
