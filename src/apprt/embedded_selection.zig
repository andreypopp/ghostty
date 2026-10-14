const std = @import("std");
const terminal = @import("../terminal/main.zig");

// ghostty_point_s
pub const Point = extern struct {
    tag: Tag,
    coord_tag: CoordTag,
    x: u32,
    y: u32,

    const Tag = enum(c_int) {
        active = 0,
        viewport = 1,
        screen = 2,
        history = 3,
    };

    const CoordTag = enum(c_int) {
        exact = 0,
        top_left = 1,
        bottom_right = 2,
    };

    fn pinStrict(self: Point, screen: *const terminal.Screen) ?terminal.Pin {
        if (self.tag != .screen or self.coord_tag != .exact) return null;
        const x = std.math.cast(terminal.size.CellCountInt, self.x) orelse return null;
        return screen.pages.pin(.{ .screen = .{ .x = x, .y = self.y } });
    }

    fn pin(
        self: Point,
        screen: *const terminal.Screen,
    ) ?terminal.Pin {
        // The core point tag.
        const tag: terminal.point.Tag = switch (self.tag) {
            inline else => |tag| @field(
                terminal.point.Tag,
                @tagName(tag),
            ),
        };

        // Clamp our point to the screen bounds.
        const clamped_x = @min(self.x, screen.pages.cols -| 1);
        const clamped_y = @min(self.y, screen.pages.rows -| 1);

        return switch (self.coord_tag) {
            // Exact coordinates require a specific pin.
            .exact => exact: {
                const pt_x = std.math.cast(
                    terminal.size.CellCountInt,
                    clamped_x,
                ) orelse std.math.maxInt(terminal.size.CellCountInt);

                const pt: terminal.Point = switch (tag) {
                    inline else => |v| @unionInit(
                        terminal.Point,
                        @tagName(v),
                        .{ .x = pt_x, .y = clamped_y },
                    ),
                };

                break :exact screen.pages.pin(pt) orelse null;
            },

            .top_left => screen.pages.getTopLeft(tag),

            .bottom_right => screen.pages.getBottomRight(tag),
        };
    }
};

// ghostty_selection_s
pub const Selection = extern struct {
    tl: Point,
    br: Point,
    rectangle: bool,

    pub fn coreStrict(self: Selection, screen: *const terminal.Screen) ?terminal.Selection {
        return .init(
            self.tl.pinStrict(screen) orelse return null,
            self.br.pinStrict(screen) orelse return null,
            self.rectangle,
        );
    }

    pub fn fromCore(screen: *const terminal.Screen, sel: terminal.Selection) ?Selection {
        const start = (screen.pages.pointFromPin(.screen, sel.start()) orelse return null).screen;
        const end = (screen.pages.pointFromPin(.screen, sel.end()) orelse return null).screen;
        return .{
            .tl = .{ .tag = .screen, .coord_tag = .exact, .x = start.x, .y = start.y },
            .br = .{ .tag = .screen, .coord_tag = .exact, .x = end.x, .y = end.y },
            .rectangle = sel.rectangle,
        };
    }

    pub fn core(
        self: Selection,
        screen: *const terminal.Screen,
    ) ?terminal.Selection {
        return .{
            .bounds = .{ .untracked = .{
                .start = self.tl.pin(screen) orelse return null,
                .end = self.br.pin(screen) orelse return null,
            } },
            .rectangle = self.rectangle,
        };
    }
};

test "embedded selection strict round trip" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 2 });
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), try t.prependHistory(testing.allocator, "old\r\nmid\r\nlast"));
    try t.printString("界");
    const primary = t.screens.active;
    try testing.expectEqual(.spacer_tail, primary.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?.rowAndCell().cell.wide);
    try testing.expect(primary.selection == null);
    const sel: Selection = .{
        .tl = .{ .tag = .screen, .coord_tag = .exact, .x = 3, .y = 4 },
        .br = .{ .tag = .screen, .coord_tag = .exact, .x = 1, .y = 0 },
        .rectangle = true,
    };
    for ([_]u32{ 2, 3 }) |y| {
        var boundary = sel;
        boundary.br.y = y;
        try primary.select(boundary.coreStrict(primary).?);
        try testing.expectEqualDeep(boundary, Selection.fromCore(primary, primary.selection.?).?);
    }
    try primary.select(sel.coreStrict(primary).?);
    try testing.expect(primary.selection.?.tracked());
    try testing.expect(primary.dirty.selection);
    try testing.expectEqualDeep(sel, Selection.fromCore(primary, primary.selection.?).?);
    for ([_]Point{
        .{ .tag = .screen, .coord_tag = .exact, .x = 5, .y = 0 },
        .{ .tag = .screen, .coord_tag = .exact, .x = std.math.maxInt(u32), .y = 0 },
        .{ .tag = .screen, .coord_tag = .exact, .x = 0, .y = 5 },
        .{ .tag = .screen, .coord_tag = .exact, .x = 0, .y = std.math.maxInt(u32) },
        .{ .tag = .viewport, .coord_tag = .exact, .x = 0, .y = 0 },
        .{ .tag = .history, .coord_tag = .exact, .x = 0, .y = 0 },
        .{ .tag = .active, .coord_tag = .exact, .x = 0, .y = 0 },
        .{ .tag = .screen, .coord_tag = .top_left, .x = 0, .y = 0 },
        .{ .tag = .screen, .coord_tag = .bottom_right, .x = 0, .y = 0 },
    }) |pt| {
        var invalid = sel;
        invalid.br = pt;
        try testing.expect(invalid.coreStrict(primary) == null);
        if (invalid.coreStrict(primary)) |core| try primary.select(core);
        try testing.expectEqualDeep(sel, Selection.fromCore(primary, primary.selection.?).?);
        invalid = sel;
        invalid.tl = pt;
        try testing.expect(invalid.coreStrict(primary) == null);
    }
    _ = try t.switchScreen(.alternate);
    const alternate = t.screens.active;
    try testing.expect(alternate.selection == null);
    var alt = sel;
    alt.tl.y = 1;
    alt.rectangle = false;
    try alternate.select(alt.coreStrict(alternate).?);
    try testing.expectEqualDeep(alt, Selection.fromCore(alternate, alternate.selection.?).?);
    var invalid = alt;
    invalid.tl.y = 2;
    try testing.expect(invalid.coreStrict(alternate) == null);
    try testing.expectEqualDeep(alt, Selection.fromCore(alternate, alternate.selection.?).?);
    try alternate.select(null);
    try testing.expect(alternate.selection == null);
    _ = try t.switchScreen(.primary);
    try testing.expect(primary.selection == null);
    try primary.select(sel.coreStrict(primary).?);
    try primary.select(null);
    try testing.expect(primary.selection == null);
}

test "embedded selection read text clamping unchanged" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 2 });
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), try t.prependHistory(testing.allocator, "old\r\nabcde\r\nlast"));
    const screen = t.screens.active;
    const clamped: Selection = .{
        .tl = .{ .tag = .screen, .coord_tag = .exact, .x = 4, .y = 1 },
        .br = .{ .tag = .screen, .coord_tag = .exact, .x = 4, .y = 1 },
        .rectangle = false,
    };
    var outside = clamped;
    outside.tl.x = std.math.maxInt(u32);
    outside.tl.y = std.math.maxInt(u32);
    outside.br = outside.tl;
    const core = outside.core(screen).?;
    try testing.expect(core.eql(clamped.core(screen).?));
    const text = try screen.selectionString(testing.allocator, .{ .sel = core, .trim = false });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("e", text);
}
