const std = @import("std");
const global = @import("../global.zig");
const Self = @This();

pub const Callback = *const fn (?*anyopaque) callconv(.c) void;
pub const State = enum(c_int) { unavailable, available, closed };

callback: Callback,
userdata: ?*anyopaque,
mutex: std.Io.Mutex = .init,
wanted: bool = false,
scheduled: bool = false,
state: State = .unavailable,

pub fn publish(self: *Self, wanted: bool) void {
    self.mutex.lockUncancelable(global.io());
    const notify = self.state != .closed and self.wanted != wanted and !self.scheduled;
    if (self.state != .closed and self.wanted != wanted) {
        self.wanted = wanted;
        self.scheduled = true;
    }
    self.mutex.unlock(global.io());
    if (notify) self.callback(self.userdata);
}

pub fn take(self: *Self) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const wanted = self.state != .closed and self.wanted;
    self.scheduled = false;
    return wanted;
}

pub fn setState(self: *Self, state: State) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.state == .closed or self.state == state) return false;
    self.state = state;
    if (state == .closed) {
        self.wanted = false;
        self.scheduled = false;
        return false;
    }
    return true;
}

pub fn active(self: *Self) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    return self.state == .available and self.wanted;
}

test "external vsync latest demand and terminal close" {
    const testing = std.testing;
    const Counter = struct {
        fn callback(raw: ?*anyopaque) callconv(.c) void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };
    var count: usize = 0;
    var state: Self = .{ .callback = Counter.callback, .userdata = &count };
    try testing.expect(!state.take());
    state.publish(false);
    try testing.expectEqual(@as(usize, 0), count);
    state.publish(true);
    state.publish(true);
    state.publish(false);
    state.publish(true);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(!state.active());
    try testing.expect(state.setState(.available));
    try testing.expect(state.active());
    try testing.expect(state.take());
    state.publish(false);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(!state.take());
    state.publish(true);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expect(state.setState(.unavailable));
    try testing.expect(!state.active());
    try testing.expect(state.take());
    try testing.expect(state.setState(.available));
    try testing.expect(state.active());
    _ = state.setState(.closed);
    try testing.expect(!state.take());
    state.publish(false);
    state.publish(true);
    try testing.expect(!state.setState(.available));
    try testing.expect(!state.active());
    try testing.expectEqual(@as(usize, 3), count);
}
