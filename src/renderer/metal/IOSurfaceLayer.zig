const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;
const FramePresentation = @import("../../renderer.zig").FramePresentation;

const log = std.log.scoped(.IOSurfaceLayer);

var Subclass: ?objc.Class = null;
var surface_updates_active_sentinel: usize = 0;

const SurfaceGeneration = struct {
    const Self = @This();

    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    scheduled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    committed: u64 = 0,
    retired: std.atomic.Value(u64) = .init(0),

    fn create() !*Self {
        const self = try std.heap.c_allocator.create(Self);
        self.* = .{};
        return self;
    }

    fn retain(self: *Self) void {
        const previous = self.refs.fetchAdd(1, .seq_cst);
        std.debug.assert(previous > 0);
    }

    fn release(self: *Self) void {
        const previous = self.refs.fetchSub(1, .seq_cst);
        std.debug.assert(previous > 0);
        if (previous == 1) std.heap.c_allocator.destroy(self);
    }

    fn schedule(self: *Self) u64 {
        const previous = self.scheduled.fetchAdd(1, .monotonic);
        std.debug.assert(previous != std.math.maxInt(u64));
        return previous +% 1;
    }

    fn latest(self: *const Self) u64 {
        return self.scheduled.load(.acquire);
    }

    fn shouldCommit(self: *const Self, generation: u64) bool {
        return generation > self.retired.load(.acquire) and generation >= self.committed;
    }

    fn commit(self: *Self, generation: u64) void {
        self.committed = @max(self.committed, generation);
    }

    fn shouldClear(self: *const Self, cutoff: u64) bool {
        return self.committed <= cutoff;
    }
};

layer: objc.Object,

surface_generation: *SurfaceGeneration,

pub fn init() !IOSurfaceLayer {
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();
    const surface_generation = try SurfaceGeneration.create();
    errdefer surface_generation.release();

    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setInstanceVariable("surface_updates_active", .{
        .value = @ptrCast(&surface_updates_active_sentinel),
    });

    return .{
        .layer = layer,
        .surface_generation = surface_generation,
    };
}

pub fn release(self: *IOSurfaceLayer) void {
    self.surface_generation.release();
    self.layer.release();
}

pub fn detachFromHost(self: *IOSurfaceLayer) void {
    var block = DetachFromHostBlock.init(.{
        .layer = self.layer.value,
    }, &detachFromHostCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        detachFromHostCallback(&block);
    } else {
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

pub const PreparedSurfaceUpdate = struct {
    layer: objc.Object,
    surface: ?*IOSurface,
    surface_generation: *SurfaceGeneration,
    generation: u64,
    presentation: FramePresentation,
    failure_status: FramePresentation.Status = .backend_failed,

    pub fn dispatch(self: PreparedSurfaceUpdate) void {
        defer self.layer.release();

        var block = SetSurfaceBlock.init(.{
            .layer = self.layer.value,
            .surface = self.surface,
            .surface_generation = self.surface_generation,
            .generation = self.generation,
            .failure_status = self.failure_status,
            .presentation_callback = self.presentation.callback,
            .presentation_userdata = self.presentation.userdata,
            .presentation_token = self.presentation.token,
            .presentation_failure_callback = self.presentation.failure_callback,
            .presentation_failure_userdata = self.presentation.failure_userdata,
            .presentation_delivery_gate = self.presentation.delivery_gate,
            .presentation_delivery_gate_userdata = self.presentation.delivery_gate_userdata,
        }, &setSurfaceCallback);
        dispatchSurfaceBlock(&block, true);
    }
};

pub fn prepareFailure(self: *IOSurfaceLayer, presentation: FramePresentation, status: FramePresentation.Status) PreparedSurfaceUpdate {
    self.surface_generation.retain();
    return .{
        .layer = self.layer.retain(),
        .surface = null,
        .surface_generation = self.surface_generation,
        .generation = 0,
        .presentation = presentation,
        .failure_status = status,
    };
}

pub fn prepareSurfaceWithPresentation(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    presentation: FramePresentation,
) PreparedSurfaceUpdate {
    const generation = self.surface_generation.schedule();
    self.surface_generation.retain();
    surface.retain();
    return .{
        .layer = self.layer.retain(),
        .surface = surface,
        .surface_generation = self.surface_generation,
        .generation = generation,
        .presentation = presentation,
    };
}

pub fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface) !void {
    const generation = self.surface_generation.schedule();
    self.surface_generation.retain();
    surface.retain();

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .surface_generation = self.surface_generation,
        .generation = generation,
        .presentation_callback = null,
        .presentation_userdata = null,
        .presentation_token = 0,
        .presentation_failure_callback = null,
        .presentation_failure_userdata = null,
        .presentation_delivery_gate = null,
        .presentation_delivery_gate_userdata = null,
    }, &setSurfaceCallback);

    dispatchSurfaceBlock(&block, false);
}

fn dispatchSurfaceBlock(block: *const SetSurfaceBlock.Context, tokened: bool) void {
    const NSThread = objc.getClass("NSThread").?;
    if (surfaceUpdateRunsInline(NSThread.msgSend(bool, "isMainThread", .{}), tokened)) {
        setSurfaceCallback(block);
    } else {
        macos.dispatch.dispatch_async(@ptrCast(macos.dispatch.queue.getMain()), @ptrCast(@constCast(block)));
    }
}

fn surfaceUpdateRunsInline(is_main_thread: bool, tokened: bool) bool {
    return is_main_thread and !tokened;
}

fn surfaceUpdatesActive(self: *const IOSurfaceLayer) bool {
    return self.layer.getInstanceVariable("surface_updates_active").value != null;
}

pub fn invalidateSurfaceUpdates(self: *IOSurfaceLayer) void {
    var block = InvalidateSurfaceUpdatesBlock.init(.{
        .layer = self.layer.value,
    }, &invalidateSurfaceUpdatesCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        invalidateSurfaceUpdatesCallback(&block);
    } else {
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

pub fn clearSurface(self: *IOSurfaceLayer) void {
    const cutoff = self.surface_generation.latest();
    if (cutoff == 0) return;
    _ = self.surface_generation.retired.fetchMax(cutoff, .acq_rel);
    self.surface_generation.retain();

    var block = ClearSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface_generation = self.surface_generation,
        .cutoff = cutoff,
    }, &clearSurfaceCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        clearSurfaceCallback(&block);
    } else {
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface) void {
    std.debug.assert(objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{}));
    const generation = self.surface_generation.schedule();
    self.layer.setProperty("contents", surface);
    self.surface_generation.commit(generation);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: ?*IOSurface,
    surface_generation: *SurfaceGeneration,
    generation: u64,
    failure_status: FramePresentation.Status = .backend_failed,
    presentation_callback: ?*const fn (?*anyopaque, u64) callconv(.c) void,
    presentation_userdata: ?*anyopaque,
    presentation_token: u64,
    presentation_failure_callback: ?*const fn (
        ?*anyopaque,
        u64,
        FramePresentation.Status,
    ) callconv(.c) void,
    presentation_failure_userdata: ?*anyopaque,
    presentation_delivery_gate: ?*const fn (?*anyopaque) callconv(.c) void,
    presentation_delivery_gate_userdata: ?*anyopaque,
}, .{}, void);

const DetachFromHostBlock = objc.Block(struct {
    layer: objc.c.id,
}, .{}, void);

const InvalidateSurfaceUpdatesBlock = objc.Block(struct {
    layer: objc.c.id,
}, .{}, void);

const ClearSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface_generation: *SurfaceGeneration,
    cutoff: u64,
}, .{}, void);

fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    defer if (block.surface) |surface| surface.release();
    defer block.surface_generation.release();

    if (layer.getInstanceVariable("surface_updates_active").value == null) return;
    const surface = block.surface orelse {
        notifyPresentationFailure(block, block.failure_status);
        return;
    };

    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    const width: usize = @intFromFloat(bounds.size.width * scale);
    const height: usize = @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        notifyPresentationFailure(block, .discarded);
        return;
    }
    if (!block.surface_generation.shouldCommit(block.generation)) {
        notifyPresentationFailure(block, .discarded);
        return;
    }

    layer.setProperty("contents", surface);
    block.surface_generation.commit(block.generation);
    if (block.presentation_callback) |callback| {
        if (block.presentation_delivery_gate) |gate| {
            gate(block.presentation_delivery_gate_userdata);
        }
        callback(block.presentation_userdata, block.presentation_token);
    }
}

fn notifyPresentationFailure(
    block: *const SetSurfaceBlock.Context,
    status: FramePresentation.Status,
) void {
    if (block.presentation_delivery_gate) |gate| {
        gate(block.presentation_delivery_gate_userdata);
    }
    if (block.presentation_failure_callback) |callback| {
        callback(
            block.presentation_failure_userdata,
            block.presentation_token,
            status,
        );
    }
}

fn detachFromHostCallback(
    block: *const DetachFromHostBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);

    layer.setInstanceVariable("surface_updates_active", .{ .value = null });

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setProperty("contents", @as(?*anyopaque, null));
    layer.msgSend(void, objc.sel("removeFromSuperlayer"), .{});
}

fn invalidateSurfaceUpdatesCallback(
    block: *const InvalidateSurfaceUpdatesBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    layer.setInstanceVariable("surface_updates_active", .{ .value = null });
}

fn clearSurfaceCallback(
    block: *const ClearSurfaceBlock.Context,
) callconv(.c) void {
    defer block.surface_generation.release();
    if (!block.surface_generation.shouldClear(block.cutoff)) return;
    const layer = objc.Object.fromId(block.layer);
    layer.setProperty("contents", @as(?*anyopaque, null));
}

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;
    if (!subclass.addIvar("surface_updates_active")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}

test "tokened surface updates defer delivery and teardown invalidates them" {
    const testing = std.testing;

    const CallbackState = struct {
        gate_count: usize = 0,
        callback_count: usize = 0,
        failure_count: usize = 0,

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.gate_count += 1;
        }

        fn callback(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.callback_count += 1;
        }

        fn failure(
            userdata: ?*anyopaque,
            _: u64,
            _: FramePresentation.Status,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.failure_count += 1;
        }
    };

    try testing.expect(!surfaceUpdateRunsInline(true, true));
    try testing.expect(surfaceUpdateRunsInline(true, false));
    try testing.expect(!surfaceUpdateRunsInline(false, false));

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    try testing.expect(layer.surfaceUpdatesActive());
    layer.invalidateSurfaceUpdates();
    try testing.expect(!layer.surfaceUpdatesActive());

    var surface = try IOSurface.init(.{
        .width = 1,
        .height = 1,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
    defer surface.deinit();
    surface.retain();
    layer.surface_generation.retain();

    var state: CallbackState = .{};
    var block = SetSurfaceBlock.init(.{
        .layer = layer.layer.value,
        .surface = surface,
        .surface_generation = layer.surface_generation,
        .generation = layer.surface_generation.schedule(),
        .presentation_callback = &CallbackState.callback,
        .presentation_userdata = &state,
        .presentation_token = 42,
        .presentation_failure_callback = &CallbackState.failure,
        .presentation_failure_userdata = &state,
        .presentation_delivery_gate = &CallbackState.gate,
        .presentation_delivery_gate_userdata = &state,
    }, &setSurfaceCallback);
    setSurfaceCallback(&block);

    try testing.expectEqual(@as(usize, 0), state.gate_count);
    try testing.expectEqual(@as(usize, 0), state.callback_count);
    try testing.expectEqual(@as(usize, 0), state.failure_count);
}

test "discarded surface update releases a gate without a failure callback" {
    const testing = std.testing;
    const CallbackState = struct {
        gate_count: usize = 0,

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.gate_count += 1;
        }

        fn callback(_: ?*anyopaque, _: u64) callconv(.c) void {}
    };

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    var surface = try IOSurface.init(.{
        .width = 1,
        .height = 1,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
    defer surface.deinit();
    surface.retain();
    layer.surface_generation.retain();

    var state: CallbackState = .{};
    var block = SetSurfaceBlock.init(.{
        .layer = layer.layer.value,
        .surface = surface,
        .surface_generation = layer.surface_generation,
        .generation = layer.surface_generation.schedule(),
        .presentation_callback = &CallbackState.callback,
        .presentation_userdata = null,
        .presentation_token = 42,
        .presentation_failure_callback = null,
        .presentation_failure_userdata = null,
        .presentation_delivery_gate = &CallbackState.gate,
        .presentation_delivery_gate_userdata = &state,
    }, &setSurfaceCallback);
    setSurfaceCallback(&block);

    try testing.expectEqual(@as(usize, 1), state.gate_count);
}

test "clear surface drops displayed IOSurface without disabling future updates" {
    const testing = std.testing;

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    var surface = try IOSurface.init(.{
        .width = 1,
        .height = 1,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
    defer surface.deinit();

    layer.setSurfaceSync(surface);
    try testing.expect(
        layer.layer.getProperty(?*anyopaque, "contents") != null,
    );

    const cutoff = layer.surface_generation.latest();
    layer.surface_generation.retain();
    var block = ClearSurfaceBlock.init(.{
        .layer = layer.layer.value,
        .surface_generation = layer.surface_generation,
        .cutoff = cutoff,
    }, &clearSurfaceCallback);
    clearSurfaceCallback(&block);

    try testing.expectEqual(
        @as(?*anyopaque, null),
        layer.layer.getProperty(?*anyopaque, "contents"),
    );
    try testing.expect(layer.surfaceUpdatesActive());
}

test "deferred clear preserves a newer IOSurface" {
    const testing = std.testing;

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    var old_surface = try IOSurface.init(.{
        .width = 1,
        .height = 1,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
    defer old_surface.deinit();
    var new_surface = try IOSurface.init(.{
        .width = 1,
        .height = 1,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
    defer new_surface.deinit();

    layer.setSurfaceSync(old_surface);
    const cutoff = layer.surface_generation.latest();
    layer.surface_generation.retain();
    var block = ClearSurfaceBlock.init(.{
        .layer = layer.layer.value,
        .surface_generation = layer.surface_generation,
        .cutoff = cutoff,
    }, &clearSurfaceCallback);

    layer.setSurfaceSync(new_surface);
    clearSurfaceCallback(&block);

    const contents = layer.layer.getProperty(?*anyopaque, "contents");
    try testing.expectEqual(
        @intFromPtr(new_surface),
        @intFromPtr(contents.?),
    );
}

test "deferred clear uses the last committed surface generation" {
    const testing = std.testing;

    var generations = try SurfaceGeneration.create();
    defer generations.release();

    const committed = generations.schedule();
    generations.commit(committed);

    const rejected = generations.schedule();
    try testing.expect(generations.shouldClear(rejected));

    const replacement = generations.schedule();
    generations.commit(replacement);
    try testing.expect(!generations.shouldClear(rejected));
    try testing.expect(!generations.shouldCommit(committed));
}

test "late presentation cannot reinstall a surface retired by unrealization" {
    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    layer.layer.setProperty("bounds", macos.graphics.Rect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 8, .height = 8 } });
    layer.layer.setProperty("contentsScale", @as(f64, 1));
    const surface = try IOSurface.init(.{ .width = 8, .height = 8, .pixel_format = .@"32BGRA", .bytes_per_element = 4, .colorspace = null });
    defer surface.deinit();
    const State = struct {
        disposition: ?FramePresentation.Status = null,
        fn presented(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            state.disposition = .presented;
        }
        fn failed(userdata: ?*anyopaque, _: u64, status: FramePresentation.Status) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            state.disposition = status;
        }
    };
    var state: State = .{};
    const prepared = layer.prepareSurfaceWithPresentation(surface, .{ .callback = State.presented, .userdata = &state, .token = 42, .failure_callback = State.failed, .failure_userdata = &state });
    defer prepared.layer.release();
    layer.clearSurface();
    var block = SetSurfaceBlock.init(.{
        .layer = prepared.layer.value,
        .surface = prepared.surface,
        .surface_generation = prepared.surface_generation,
        .generation = prepared.generation,
        .presentation_callback = prepared.presentation.callback,
        .presentation_userdata = prepared.presentation.userdata,
        .presentation_token = prepared.presentation.token,
        .presentation_failure_callback = prepared.presentation.failure_callback,
        .presentation_failure_userdata = prepared.presentation.failure_userdata,
        .presentation_delivery_gate = null,
        .presentation_delivery_gate_userdata = null,
    }, &setSurfaceCallback);
    setSurfaceCallback(&block);
    try std.testing.expectEqual(FramePresentation.Status.discarded, state.disposition.?);
    try std.testing.expect(layer.layer.getProperty(?*anyopaque, "contents") == null);
}
