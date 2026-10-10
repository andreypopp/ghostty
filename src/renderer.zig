//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The renderer is closely tied to the windowing system which usually
//! has to prepare the window for the given renderer using system-specific
//! APIs. The renderers in this package assume that the renderer is already
//! setup (OpenGL has a context, Vulkan has a surface, etc.)

const build_config = @import("build_config.zig");

const cursor = @import("renderer/cursor.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const shadertoy = @import("renderer/shadertoy.zig");
pub const Backend = @import("renderer/backend.zig").Backend;
pub const GenericRenderer = @import("renderer/generic.zig").Renderer;
pub const Metal = @import("renderer/Metal.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const Options = @import("renderer/Options.zig");
pub const Overlay = @import("renderer/Overlay.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const CursorStyle = cursor.Style;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;
pub const lib = @import("lib/main.zig");

pub const FramePresentation = struct {
    pub const Status = enum(c_int) {
        presented = 0,
        discarded = 1,
        backend_failed = 2,
    };

    callback: *const fn (?*anyopaque, u64) callconv(.c) void,
    userdata: ?*anyopaque,
    token: u64,
    delivery_gate: ?*const fn (?*anyopaque) callconv(.c) void = null,
    delivery_gate_userdata: ?*anyopaque = null,
    failure_callback: ?*const fn (?*anyopaque, u64, Status) callconv(.c) void = null,
    failure_userdata: ?*anyopaque = null,

    pub fn deliver(self: FramePresentation) void {
        if (self.delivery_gate) |gate| gate(self.delivery_gate_userdata);
        self.callback(self.userdata, self.token);
    }

    pub fn fail(self: FramePresentation, status: Status) void {
        if (self.delivery_gate) |gate| gate(self.delivery_gate_userdata);
        if (self.failure_callback) |callback| {
            callback(self.failure_userdata, self.token, status);
        }
    }
};

pub const RenderPresentationStatus = FramePresentation.Status;

test "frame presentation waits for its delivery gate" {
    const testing = @import("std").testing;
    const TestState = struct {
        events: [2]u8 = @splat(0),
        len: usize = 0,

        fn append(self: *@This(), event: u8) void {
            self.events[self.len] = event;
            self.len += 1;
        }

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(1);
        }

        fn callback(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(2);
        }
    };

    var state: TestState = .{};
    const presentation: FramePresentation = .{
        .callback = &TestState.callback,
        .userdata = &state,
        .token = 42,
        .delivery_gate = &TestState.gate,
        .delivery_gate_userdata = &state,
    };
    presentation.deliver();
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, state.events[0..state.len]);
}

test "failed frame presentation reports after its delivery gate" {
    const testing = @import("std").testing;
    const TestState = struct {
        events: [2]u8 = @splat(0),
        len: usize = 0,

        fn append(self: *@This(), event: u8) void {
            self.events[self.len] = event;
            self.len += 1;
        }

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(1);
        }

        fn callback(
            userdata: ?*anyopaque,
            _: u64,
            status: FramePresentation.Status,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(if (status == .discarded) 2 else 3);
        }
    };

    var state: TestState = .{};
    const presentation: FramePresentation = .{
        .callback = undefined,
        .userdata = &state,
        .token = 42,
        .delivery_gate = &TestState.gate,
        .delivery_gate_userdata = &state,
        .failure_callback = &TestState.callback,
        .failure_userdata = &state,
    };
    presentation.fail(.discarded);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, state.events[0..state.len]);
}

test "failed frame presentation preserves null callback userdata" {
    const testing = @import("std").testing;
    const TestState = struct {
        var saw_null_userdata = false;

        fn callback(
            userdata: ?*anyopaque,
            _: u64,
            _: FramePresentation.Status,
        ) callconv(.c) void {
            saw_null_userdata = userdata == null;
        }
    };

    TestState.saw_null_userdata = false;
    var unrelated_userdata: u8 = 0;
    const presentation: FramePresentation = .{
        .callback = undefined,
        .userdata = &unrelated_userdata,
        .token = 42,
        .failure_callback = &TestState.callback,
        .failure_userdata = null,
    };
    presentation.fail(.backend_failed);
    try testing.expect(TestState.saw_null_userdata);
}

/// The implementation to use for the renderer. This is comptime chosen
/// so that every build has exactly one renderer implementation.
pub const Renderer = GenericRenderer(GraphicsAPI);

const GraphicsAPI = switch (build_config.renderer) {
    .metal => Metal,
    .opengl => OpenGL,
};

/// The app-scoped render device from which surface renderers are created.
pub const Device = GraphicsAPI.Device;

/// The health status of a renderer. These must be shared across all
/// renderers even if some states aren't reachable so that our API users
/// can use the same enum for all renderers.
pub const Health = enum(c_int) {
    healthy,
    unhealthy,

    test "ghostty.h Health" {
        try lib.checkGhosttyHEnum(Health, "GHOSTTY_RENDERER_HEALTH_");
    }
};

test "ghostty.h vsync state" {
    const ExternalVsync = @import("renderer/ExternalVsync.zig");
    try lib.checkGhosttyHEnum(ExternalVsync.State, "GHOSTTY_VSYNC_");
}

test {
    _ = @import("renderer/ExternalVsync.zig");

    // Our comptime-chosen renderer
    _ = Renderer;

    _ = cursor;
    _ = message;
    _ = shadertoy;
    _ = size;
    _ = Thread;
    _ = State;
}
