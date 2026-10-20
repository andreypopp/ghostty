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
        const clamped_y = switch (tag) {
            .screen, .history => self.y,
            .active, .viewport => @min(self.y, screen.pages.rows -| 1),
        };

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
        return .init(
            self.tl.pin(screen) orelse return null,
            self.br.pin(screen) orelse return null,
            self.rectangle,
        );
    }
};

pub fn rowWrapped(screen: *const terminal.Screen, y: u32) bool {
    const pin = screen.pages.pin(.{ .screen = .{ .y = y } }) orelse return false;
    return pin.rowAndCell().row.wrap;
}

// ghostty_point_motion_e
pub const Motion = enum(c_int) {
    left = 0,
    right = 1,
    word_next = 2,
    word_previous = 3,
    word_end = 4,
    first_nonblank = 5,
};

const Class = enum { blank, delim, word, empty };

const Walk = struct {
    pin: terminal.Pin,
    forward: bool,
    boundaries: []const u21,
    joined: bool = true,
    glyph: ?terminal.Pin = null,
    last: ?usize = null,
    empty: bool = false,

    fn enter(self: *Walk, p: terminal.Pin) void {
        self.last = null;
        for (p.cells(.all), 0..) |cell, x| {
            if (cell.hasText()) self.last = x;
        }
        const row = p.rowAndCell().row;
        self.empty = self.last == null and !row.wrap and !row.wrap_continuation;
    }

    fn class(self: *const Walk, p: terminal.Pin) ?Class {
        if (self.empty) return if (p.x == 0) .empty else null;
        const rac = p.rowAndCell();
        if (rac.cell.wide == .spacer_tail or rac.cell.wide == .spacer_head) return null;
        if (!rac.cell.hasText()) return if (rac.row.wrap and (self.last == null or self.last.? < p.x)) null else .blank;
        const cp = rac.cell.codepoint();
        if (cp == ' ' or cp == '\t') return .blank;
        return if (std.mem.indexOfScalar(u21, self.boundaries, cp) != null) .delim else .word;
    }

    fn next(self: *Walk) ?Class {
        var p = self.pin;
        var joined = true;
        while (true) {
            const edge = if (self.forward) p.x + 1 == p.node.cols() else p.x == 0;
            const q = (if (self.forward) p.rightWrap(1) else p.leftWrap(1)) orelse return null;
            if (edge) {
                joined = joined and (if (self.forward) p else q).rowAndCell().row.wrap;
                self.enter(q);
            }
            p = q;
            const c = self.class(p) orelse continue;
            self.pin = p;
            self.joined = joined;
            if (c == .delim or c == .word) self.glyph = p;
            return c;
        }
    }

    fn more(self: Walk) bool {
        var w = self;
        w.forward = true;
        w.glyph = null;
        while (w.glyph == null) _ = w.next() orelse return false;
        return true;
    }
};

pub fn movePoint(screen: *const terminal.Screen, point: Point, motion: Motion, boundaries: []const u21) ?Point {
    var pin = point.pinStrict(screen) orelse return null;
    const wide = pin.rowAndCell().cell.wide;
    if (pin.x > 0 and (motion == .left and wide != .spacer_tail or motion == .right and wide == .spacer_head)) pin.x -= 1;
    if (pin.rowAndCell().cell.wide == .spacer_tail) pin.x -= 1;
    const result: terminal.Pin = switch (motion) {
        .left => pin,
        .right => right: {
            var q = pin;
            while (q.x + 1 < q.node.cols()) {
                q.x += 1;
                switch (q.rowAndCell().cell.wide) {
                    .spacer_tail => {},
                    .spacer_head => break,
                    else => break :right q,
                }
            }
            break :right pin;
        },
        else => walk: {
            var w: Walk = .{ .pin = pin, .forward = motion != .word_previous, .boundaries = boundaries };
            w.enter(pin);
            if (w.empty) w.pin.x = 0;
            const start = w.class(w.pin) orelse .blank;
            if (start == .delim or start == .word) w.glyph = w.pin;
            break :walk switch (motion) {
                .left, .right => unreachable,
                .first_nonblank => first: {
                    var q = pin;
                    for (0..q.node.cols()) |x| {
                        q.x = @intCast(x);
                        const c = w.class(q);
                        if (c == .delim or c == .word) break :first q;
                    }
                    q.x = 0;
                    break :first q;
                },
                .word_next, .word_end => forward: {
                    var c = w.next();
                    if (motion == .word_next and (start == .delim or start == .word)) {
                        while (c == start and w.joined) c = w.next();
                    }
                    var tail = motion == .word_end;
                    while (c) |k| switch (k) {
                        .blank => c = w.next(),
                        .empty => {
                            if (!tail and w.more()) break :forward w.pin;
                            tail = true;
                            c = w.next();
                        },
                        .delim, .word => {
                            if (motion == .word_next) break :forward w.pin;
                            while (true) {
                                const at = w.pin;
                                if (w.next() != k or !w.joined) break :forward at;
                            }
                        },
                    };
                    break :forward w.glyph orelse w.pin;
                },
                .word_previous => backward: {
                    const origin = w;
                    var later: ?bool = null;
                    var c = w.next();
                    while (c) |k| switch (k) {
                        .blank => c = w.next(),
                        .empty => {
                            later = later orelse (origin.glyph != null or origin.more());
                            if (later.?) break :backward w.pin;
                            c = w.next();
                        },
                        .delim, .word => while (true) {
                            const at = w.pin;
                            if (w.next() != k or !w.joined) break :backward at;
                        },
                    };
                    break :backward w.pin;
                },
            };
        },
    };
    const pt = (screen.pages.pointFromPin(.screen, result) orelse return null).screen;
    return .{ .tag = .screen, .coord_tag = .exact, .x = pt.x, .y = pt.y };
}

test "embedded selection row wrapped" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 3 });
    defer t.deinit(testing.allocator);
    try t.printString("abcdefgh\r\nend\r\n123456\r\nx");
    const primary = t.screens.active;
    try testing.expectEqual(@as(u32, 3), primary.pages.pointFromPin(.screen, primary.pages.getTopLeft(.active)).?.screen.y);
    for ([_]bool{ true, false, false, true, false, false }, 0..) |wrapped, y| {
        try testing.expectEqual(wrapped, rowWrapped(primary, @intCast(y)));
    }
    try testing.expect(!rowWrapped(primary, std.math.maxInt(u32)));
    _ = try t.switchScreen(.alternate);
    try t.printString("abcdefg");
    const alternate = t.screens.active;
    try testing.expect(rowWrapped(alternate, 0));
    try testing.expect(!rowWrapped(alternate, 1));
    try testing.expect(!rowWrapped(alternate, 3));
    try testing.expect(!rowWrapped(alternate, 5));
}

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

const default = &@import("../terminal/selection_codepoints.zig").default_word_boundaries;

fn expectMoves(screen: *const terminal.Screen, boundaries: []const u21, cases: []const struct { Motion, u32, u32, u32, u32 }) !void {
    for (cases) |c| {
        const to = movePoint(screen, .{ .tag = .screen, .coord_tag = .exact, .x = c[1], .y = c[2] }, c[0], boundaries) orelse return error.TestUnexpectedResult;
        std.testing.expectEqual([2]u32{ c[3], c[4] }, [2]u32{ to.x, to.y }) catch |err| {
            std.debug.print("{t} from ({d},{d})\n", .{ c[0], c[1], c[2] });
            return err;
        };
    }
}

test "embedded selection motion word classes" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 4 });
    defer t.deinit(testing.allocator);
    try t.printString("one,two  ;; three\nfoo/bar baz");
    try expectMoves(t.screens.active, default, &.{
        .{ .word_next, 0, 0, 3, 0 },       .{ .word_next, 3, 0, 4, 0 },      .{ .word_next, 4, 0, 9, 0 },
        .{ .word_next, 9, 0, 12, 0 },      .{ .word_next, 7, 0, 9, 0 },      .{ .word_next, 12, 0, 0, 1 },
        .{ .word_previous, 16, 0, 12, 0 }, .{ .word_previous, 12, 0, 9, 0 }, .{ .word_previous, 10, 0, 9, 0 },
        .{ .word_previous, 9, 0, 4, 0 },   .{ .word_previous, 5, 0, 4, 0 },  .{ .word_previous, 4, 0, 3, 0 },
        .{ .word_previous, 3, 0, 0, 0 },   .{ .word_previous, 7, 0, 4, 0 },  .{ .word_previous, 0, 0, 0, 0 },
        .{ .word_previous, 0, 1, 12, 0 },  .{ .word_end, 0, 0, 2, 0 },       .{ .word_end, 2, 0, 3, 0 },
        .{ .word_end, 3, 0, 6, 0 },        .{ .word_end, 6, 0, 10, 0 },      .{ .word_end, 9, 0, 10, 0 },
        .{ .word_end, 7, 0, 10, 0 },       .{ .word_end, 10, 0, 16, 0 },     .{ .word_end, 16, 0, 6, 1 },
        .{ .word_next, 0, 1, 8, 1 },       .{ .word_next, 8, 1, 10, 1 },     .{ .word_next, 10, 1, 10, 1 },
        .{ .word_end, 10, 1, 10, 1 },      .{ .word_end, 11, 1, 0, 3 },      .{ .word_next, 15, 1, 0, 3 },
    });
    try expectMoves(t.screens.active, &.{ 0, ' ', '/' }, &.{
        .{ .word_next, 0, 1, 3, 1 },     .{ .word_next, 3, 1, 4, 1 }, .{ .word_end, 0, 1, 2, 1 },
        .{ .word_previous, 4, 1, 3, 1 }, .{ .word_next, 0, 0, 9, 0 },
    });
}

test "embedded selection motion soft wraps and hard breaks" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 4 });
    defer t.deinit(testing.allocator);
    try t.printString("abcdefgh\nabcde\nfgh");
    try expectMoves(t.screens.active, default, &.{
        .{ .word_next, 0, 0, 0, 2 },     .{ .word_end, 0, 0, 2, 1 },      .{ .word_previous, 2, 1, 0, 0 },
        .{ .word_previous, 0, 2, 0, 0 }, .{ .word_next, 0, 2, 0, 3 },     .{ .word_end, 0, 2, 4, 2 },
        .{ .word_end, 4, 2, 2, 3 },      .{ .word_previous, 0, 3, 0, 2 }, .{ .word_end, 2, 3, 2, 3 },
    });
}

test "embedded selection motion page and history seams" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 200, .rows = 2, .max_scrollback_bytes = null });
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), try t.prependHistory(testing.allocator, "old\r\nmid"));
    try t.printString("new\n");
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first != screen.pages.pages.last);
    try expectMoves(screen, default, &.{
        .{ .word_previous, 0, 2, 0, 1 }, .{ .word_next, 0, 1, 0, 2 }, .{ .word_end, 2, 1, 2, 2 },
    });
    for (0..300 * 50) |_| try t.printString("abcd");
    var boundary = screen.pages.pages.first.?;
    while (boundary.next != null and !(terminal.Pin{ .node = boundary, .y = boundary.rows() - 1 }).rowAndCell().row.wrap) boundary = boundary.next.?;
    try testing.expect(boundary.next != null);
    const last = (screen.pages.pointFromPin(.screen, .{ .node = boundary, .y = boundary.rows() - 1 }) orelse return error.TestUnexpectedResult).screen.y;
    const bottom = (screen.pages.pointFromPin(.screen, screen.pages.getBottomRight(.screen).?) orelse return error.TestUnexpectedResult).screen.y;
    try expectMoves(screen, default, &.{
        .{ .word_previous, 0, last + 1, 0, 3 }, .{ .word_end, 0, last, 199, bottom }, .{ .word_next, 0, last, 199, bottom },
    });
}

test "embedded selection motion empty lines and loaded bounds" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 5, .rows = 8 });
    defer t.deinit(testing.allocator);
    try t.printString("ab\n\n\n  \ncd");
    try expectMoves(t.screens.active, default, &.{
        .{ .word_next, 0, 0, 0, 1 },      .{ .word_next, 0, 1, 0, 2 },      .{ .word_next, 3, 2, 0, 4 },
        .{ .word_next, 0, 4, 1, 4 },      .{ .word_next, 1, 4, 1, 4 },      .{ .word_next, 0, 5, 0, 7 },
        .{ .word_next, 0, 7, 0, 7 },      .{ .word_previous, 0, 4, 0, 2 },  .{ .word_previous, 2, 2, 0, 1 },
        .{ .word_previous, 0, 1, 0, 0 },  .{ .word_previous, 4, 7, 0, 4 },  .{ .word_end, 0, 0, 1, 0 },
        .{ .word_end, 1, 0, 1, 4 },       .{ .word_end, 1, 4, 1, 4 },       .{ .word_end, 0, 6, 0, 7 },
        .{ .first_nonblank, 4, 3, 0, 3 }, .{ .first_nonblank, 3, 1, 0, 1 },
    });

    var empty = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 3, .rows = 2 });
    defer empty.deinit(testing.allocator);
    try expectMoves(empty.screens.active, default, &.{
        .{ .word_next, 0, 0, 0, 1 },     .{ .word_next, 0, 1, 0, 1 },     .{ .word_end, 2, 0, 0, 1 },
        .{ .word_previous, 1, 1, 0, 0 }, .{ .word_previous, 0, 0, 0, 0 }, .{ .first_nonblank, 2, 1, 0, 1 },
        .{ .left, 0, 0, 0, 0 },          .{ .right, 2, 1, 2, 1 },
    });
    try empty.printString("\nab");
    empty.screens.active.pages.pin(.{ .screen = .{ .y = 1 } }).?.rowAndCell().row.wrap = true;
    try expectMoves(empty.screens.active, default, &.{
        .{ .word_end, 0, 1, 1, 1 }, .{ .word_next, 0, 1, 1, 1 }, .{ .word_next, 2, 1, 2, 1 }, .{ .right, 1, 1, 2, 1 },
    });
}

test "embedded selection motion wide characters" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 6, .rows = 8 });
    defer t.deinit(testing.allocator);
    try t.printString("a界b c\n日本 x\nabcd日\nabcde日\ne\u{301}x y\n👍 z");
    const screen = t.screens.active;
    try testing.expectEqual(.spacer_head, screen.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?.rowAndCell().cell.wide);
    try expectMoves(screen, default, &.{
        .{ .right, 0, 0, 1, 0 },          .{ .right, 1, 0, 3, 0 },         .{ .right, 2, 0, 3, 0 },
        .{ .left, 3, 0, 1, 0 },           .{ .left, 2, 0, 1, 0 },          .{ .left, 1, 0, 0, 0 },
        .{ .word_next, 2, 0, 5, 0 },      .{ .word_end, 2, 0, 3, 0 },      .{ .word_previous, 2, 0, 0, 0 },
        .{ .word_previous, 5, 0, 0, 0 },  .{ .right, 0, 1, 2, 1 },         .{ .right, 2, 1, 4, 1 },
        .{ .word_end, 0, 1, 2, 1 },       .{ .word_end, 1, 1, 2, 1 },      .{ .word_next, 0, 1, 5, 1 },
        .{ .word_previous, 5, 1, 0, 1 },  .{ .word_previous, 3, 1, 0, 1 }, .{ .right, 4, 2, 4, 2 },
        .{ .right, 5, 2, 4, 2 },          .{ .left, 5, 2, 4, 2 },          .{ .word_end, 0, 2, 4, 2 },
        .{ .right, 4, 3, 4, 3 },          .{ .right, 5, 3, 4, 3 },         .{ .word_end, 0, 3, 0, 4 },
        .{ .word_next, 5, 3, 0, 4 },      .{ .word_previous, 0, 4, 0, 3 }, .{ .word_previous, 1, 4, 0, 3 },
        .{ .first_nonblank, 1, 5, 0, 5 }, .{ .word_end, 0, 5, 1, 5 },      .{ .word_next, 0, 5, 3, 5 },
        .{ .word_next, 0, 6, 3, 6 },      .{ .word_end, 0, 6, 3, 6 },      .{ .right, 0, 6, 2, 6 },
    });
    var head = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 6, .rows = 3 });
    defer head.deinit(testing.allocator);
    try head.printString("abc日日");
    try testing.expectEqual(.spacer_head, head.screens.active.pages.pin(.{ .screen = .{ .x = 5, .y = 0 } }).?.rowAndCell().cell.wide);
    try expectMoves(head.screens.active, default, &.{ .{ .right, 5, 0, 3, 0 }, .{ .left, 5, 0, 3, 0 }, .{ .right, 3, 0, 3, 0 } });
}

test "embedded selection motion first nonblank, classes and invalid input" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 6, .rows = 6 });
    defer t.deinit(testing.allocator);
    try t.printString("  ab\na\u{a0}b c\n\u{a0}x│y\n  abcdefgh");
    const primary = t.screens.active;
    try expectMoves(primary, default, &.{
        .{ .first_nonblank, 3, 0, 2, 0 }, .{ .first_nonblank, 0, 0, 2, 0 }, .{ .first_nonblank, 5, 2, 0, 2 },
        .{ .first_nonblank, 5, 3, 2, 3 }, .{ .first_nonblank, 3, 4, 0, 4 }, .{ .word_next, 0, 1, 4, 1 },
        .{ .word_next, 0, 2, 2, 2 },      .{ .word_next, 2, 2, 3, 2 },      .{ .word_previous, 3, 4, 2, 3 },
    });
    try expectMoves(primary, &.{ 0, ' ', 0xa0 }, &.{ .{ .word_next, 0, 1, 1, 1 }, .{ .word_next, 1, 1, 2, 1 } });
    for ([_]Point{
        .{ .tag = .screen, .coord_tag = .exact, .x = 6, .y = 0 },
        .{ .tag = .screen, .coord_tag = .exact, .x = 0, .y = 6 },
        .{ .tag = .screen, .coord_tag = .exact, .x = 0, .y = std.math.maxInt(u32) },
        .{ .tag = .viewport, .coord_tag = .exact, .x = 0, .y = 0 },
        .{ .tag = .screen, .coord_tag = .top_left, .x = 0, .y = 0 },
    }) |pt| try testing.expect(movePoint(primary, pt, .word_next, default) == null);
    try testing.expect(std.enums.fromInt(Motion, 6) == null);
    _ = try t.switchScreen(.alternate);
    try t.printString("xy z");
    try expectMoves(t.screens.active, default, &.{
        .{ .word_next, 0, 0, 3, 0 }, .{ .word_previous, 1, 0, 0, 0 }, .{ .word_previous, 0, 0, 0, 0 },
    });
}
