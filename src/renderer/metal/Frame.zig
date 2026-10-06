//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");

const mtl = @import("api.zig");
const Renderer = @import("../generic.zig").Renderer(Metal);
const Metal = @import("../Metal.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;
const FramePresentation = @import("../../renderer.zig").FramePresentation;

const log = std.log.scoped(.metal);

/// Options for beginning a frame.
pub const Options = struct {
    /// MTLCommandQueue
    queue: objc.Object,
};

/// MTLCommandBuffer
buffer: objc.Object,

block: CompletionBlock.Context,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
    presentation: ?FramePresentation,
) !Self {
    const buffer = opts.queue.msgSend(
        objc.Object,
        objc.sel("commandBuffer"),
        .{},
    );

    // Create our block to register for completion updates.
    // The block is deallocated by the objC runtime on success.
    const block = CompletionBlock.init(
        .{
            .renderer = renderer,
            .target = target,
            .sync = false,
            .presentation_callback = if (presentation) |value| value.callback else null,
            .presentation_userdata = if (presentation) |value| value.userdata else null,
            .presentation_token = if (presentation) |value| value.token else 0,
            .presentation_failure_callback = if (presentation) |value| value.failure_callback else null,
            .presentation_failure_userdata = if (presentation) |value| value.failure_userdata else null,
            .presentation_delivery_gate = if (presentation) |value| value.delivery_gate else null,
            .presentation_delivery_gate_userdata = if (presentation) |value| value.delivery_gate_userdata else null,
        },
        &bufferCompleted,
    );

    return .{ .buffer = buffer, .block = block };
}

/// This is the block type used for the addCompletedHandler callback.
const CompletionBlock = objc.Block(struct {
    renderer: *Renderer,
    target: *Target,
    sync: bool,
    presentation_callback: ?*const fn (?*anyopaque, u64) callconv(.c) void,
    presentation_userdata: ?*anyopaque,
    presentation_token: u64,
    presentation_failure_callback: ?*const fn (?*anyopaque, u64, FramePresentation.Status) callconv(.c) void,
    presentation_failure_userdata: ?*anyopaque,
    presentation_delivery_gate: ?*const fn (?*anyopaque) callconv(.c) void,
    presentation_delivery_gate_userdata: ?*anyopaque,
}, .{
    objc.c.id, // MTLCommandBuffer
}, void);

fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const buffer = objc.Object.fromId(buffer_id);

    // Get our command buffer status to pass back to the generic renderer.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    const presentation: ?FramePresentation = if (block.presentation_callback) |callback| .{
        .callback = callback,
        .userdata = block.presentation_userdata,
        .token = block.presentation_token,
        .failure_callback = block.presentation_failure_callback,
        .failure_userdata = block.presentation_failure_userdata,
        .delivery_gate = block.presentation_delivery_gate,
        .delivery_gate_userdata = block.presentation_delivery_gate_userdata,
    } else null;
    if (health == .healthy) {
        completeHealthyFrame(block.renderer, block.target, block.sync, presentation);
    } else if (presentation) |value| {
        const prepared = block.renderer.api.preparePresentationFailure(value, .backend_failed);
        block.renderer.frameCompleted(health);
        prepared.dispatch();
    } else {
        block.renderer.frameCompleted(health);
    }
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .command_buffer = self.buffer,
    });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
pub inline fn complete(self: *Self, sync: bool) void {
    // If we don't need to complete synchronously,
    // we add our block as a completion handler.
    //
    // It will be copied when we add the handler, and then the
    // copy will be deallocated by the objc runtime on success.
    if (!sync) {
        self.buffer.msgSend(
            void,
            objc.sel("addCompletedHandler:"),
            .{&self.block},
        );
    }

    self.buffer.msgSend(void, objc.sel("commit"), .{});

    // If we need to complete synchronously, we wait until
    // the buffer is completed and invoke the block directly.
    if (sync) {
        self.buffer.msgSend(void, "waitUntilCompleted", .{});
        self.block.sync = true;
        CompletionBlock.invoke(&self.block, .{self.buffer.value});
    }
}

fn completeHealthyFrame(renderer: anytype, target: anytype, sync: bool, presentation: ?FramePresentation) void {
    if (presentation) |value| {
        var frozen = renderer.api.detachPresentationTarget(target) catch |err| {
            log.warn("Failed to detach tokened render target: err={}", .{err});
            const prepared = renderer.api.preparePresentationFailure(value, .backend_failed);
            renderer.frameCompleted(.healthy);
            prepared.dispatch();
            return;
        };
        defer frozen.deinit();
        const prepared = renderer.api.preparePresentation(frozen, value);
        renderer.frameCompleted(.healthy);
        prepared.dispatch();
        return;
    }
    renderer.api.present(target.*, sync) catch |err| {
        log.err("Failed to present render target: err={}", .{err});
    };
    renderer.frameCompleted(.healthy);
}

test "tokened completion freezes target before recycling and dispatch" {
    const testing = std.testing;
    const State = struct {
        events: [8]u8 = undefined,
        len: usize = 0,
        fail: bool = false,
        fn append(self: *@This(), value: u8) void {
            self.events[self.len] = value;
            self.len += 1;
        }
    };
    const FakeTarget = struct {
        id: u8,
        state: *State,
        fn deinit(self: *@This()) void {
            self.state.append(5);
        }
    };
    const Prepared = struct {
        id: u8,
        state: *State,
        fn dispatch(self: @This()) void {
            std.debug.assert(self.id == 1 or self.id == 0);
            self.state.append(4);
        }
    };
    const API = struct {
        state: *State,
        fn detachPresentationTarget(self: *@This(), target: *FakeTarget) !FakeTarget {
            if (self.state.fail) return error.OutOfMemory;
            self.state.append(1);
            const frozen = target.*;
            target.id = 2;
            return frozen;
        }
        fn preparePresentation(self: *@This(), target: FakeTarget, _: FramePresentation) Prepared {
            self.state.append(2);
            return .{ .id = target.id, .state = self.state };
        }
        fn preparePresentationFailure(self: *@This(), _: FramePresentation, status: FramePresentation.Status) Prepared {
            std.debug.assert(status == .backend_failed);
            self.state.append(6);
            return .{ .id = 0, .state = self.state };
        }
        fn present(self: *@This(), _: FakeTarget, _: bool) !void {
            self.state.append(7);
        }
    };
    const FakeRenderer = struct {
        api: API,
        target: *FakeTarget,
        fn frameCompleted(self: *@This(), health: Health) void {
            std.debug.assert(health == .healthy);
            self.api.state.append(3);
            self.target.id = 9;
        }
    };
    var state: State = .{};
    var target: FakeTarget = .{ .id = 1, .state = &state };
    var renderer: FakeRenderer = .{ .api = .{ .state = &state }, .target = &target };
    const presentation: FramePresentation = .{ .callback = undefined, .userdata = null, .token = 42 };
    completeHealthyFrame(&renderer, &target, false, presentation);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, state.events[0..state.len]);
    state = .{ .fail = true };
    completeHealthyFrame(&renderer, &target, false, presentation);
    try testing.expectEqualSlices(u8, &.{ 6, 3, 4 }, state.events[0..state.len]);
    state = .{};
    completeHealthyFrame(&renderer, &target, false, null);
    try testing.expectEqualSlices(u8, &.{ 7, 3 }, state.events[0..state.len]);
}
