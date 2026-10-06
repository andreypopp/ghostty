const std = @import("std");
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const terminal = @import("../terminal/main.zig");

pub const Metrics = extern struct {
    columns: u16,
    rows: u16,
    cursor_column: u16,
    cursor_row: u16,
    cursor_width_cells: u16,
    cursor_in_viewport: bool,
    cell_width: f64,
    cell_height: f64,
    padding_left: f64,
    padding_top: f64,
};
pub fn snapshot(
    size: renderer.Size,
    scale: apprt.ContentScale,
    screen: *terminal.Screen,
) ?Metrics {
    const size_grid = size.grid();
    if (screen.pages.cols == 0 or
        screen.pages.rows == 0 or
        size_grid.columns != screen.pages.cols or
        size_grid.rows != screen.pages.rows or
        size.cell.width == 0 or
        size.cell.height == 0 or
        !std.math.isFinite(scale.x) or
        !std.math.isFinite(scale.y) or
        scale.x <= 0 or
        scale.y <= 0) return null;

    var pin = screen.cursor.page_pin.*;
    const wide = pin.rowAndCell().cell.wide;
    const width: u16 = switch (wide) {
        .wide => 2,
        .spacer_tail => tail: {
            pin = pin.left(1);
            break :tail 2;
        },
        .narrow => 1,
        .spacer_head => head: {
            var it = pin.cellIterator(.right_down, null);
            _ = it.next();
            pin = it.next() orelse return null;
            if (pin.rowAndCell().cell.wide != .wide) return null;
            break :head 2;
        },
    };
    const cursor = screen.pages.pointFromPin(.viewport, pin);
    return .{
        .columns = @intCast(screen.pages.cols),
        .rows = @intCast(screen.pages.rows),
        .cursor_column = if (cursor) |point|
            @intCast(point.viewport.x)
        else
            0,
        .cursor_row = if (cursor) |point|
            @intCast(point.viewport.y)
        else
            0,
        .cursor_width_cells = if (cursor != null)
            width
        else
            0,
        .cursor_in_viewport = cursor != null,
        .cell_width = @as(f64, @floatFromInt(size.cell.width)) / scale.x,
        .cell_height = @as(f64, @floatFromInt(size.cell.height)) / scale.y,
        .padding_left = @as(f64, @floatFromInt(size.padding.left)) / scale.x,
        .padding_top = @as(f64, @floatFromInt(size.padding.top)) / scale.y,
    };
}
test "manual grid metrics validates actual grid and wide cursor geometry" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit(testing.allocator);
    const size: renderer.Size = .{
        .screen = .{ .width = 80, .height = 48 },
        .cell = .{ .width = 8, .height = 16 },
        .padding = .{},
    };
    const metrics = snapshot(size, .{ .x = 2, .y = 2 }, t.screens.active).?;
    try testing.expectEqual(@as(u16, 10), metrics.columns);
    try testing.expectEqual(@as(f64, 4), metrics.cell_width);
    try testing.expectEqual(@as(f64, 8), metrics.cell_height);
    try testing.expect(metrics.cursor_in_viewport);
    try testing.expectEqual(@as(u16, 1), metrics.cursor_width_cells);
    try t.print(0x1f600);
    t.setCursorPos(1, 2);
    const wide = snapshot(size, .{ .x = 1, .y = 1 }, t.screens.active).?;
    try testing.expectEqual(@as(u16, 2), wide.cursor_width_cells);
    try testing.expectEqual(@as(u16, 0), wide.cursor_column);
    var mismatched = size;
    mismatched.screen.width = 160;
    try testing.expect(snapshot(mismatched, .{ .x = 1, .y = 1 }, t.screens.active) == null);
    try testing.expect(snapshot(size, .{ .x = 0, .y = 1 }, t.screens.active) == null);
}
