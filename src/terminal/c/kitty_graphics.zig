const std = @import("std");
const testing = std.testing;
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const kitty_storage = @import("../kitty/graphics_storage.zig");
const kitty_cmd = @import("../kitty/graphics_command.zig");
const kitty_image = @import("../kitty/graphics_image.zig");
const Image = kitty_image.Image;
const ScreenSet = @import("../ScreenSet.zig");
const grid_ref = @import("grid_ref.zig");
const selection_c = @import("selection.zig");
const terminal_c = @import("terminal.zig");
const Terminal = @import("../Terminal.zig");
const PageList = @import("../PageList.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyKittyGraphics
pub const KittyGraphics = if (build_options.kitty_graphics)
    *kitty_storage.ImageStorage
else
    *anyopaque;

/// C: GhosttyKittyGraphicsImage
pub const ImageHandle = if (build_options.kitty_graphics)
    ?*const Image
else
    ?*const anyopaque;

/// C: GhosttyKittyGraphicsPlacementIterator
pub const PlacementIterator = if (build_options.kitty_graphics)
    ?*PlacementIteratorWrapper
else
    ?*anyopaque;

const PlacementMap = if (build_options.kitty_graphics)
    std.AutoHashMapUnmanaged(
        kitty_storage.ImageStorage.PlacementKey,
        kitty_storage.ImageStorage.Placement,
    )
else
    void;

const PlacementIteratorWrapper = if (build_options.kitty_graphics)
    struct {
        alloc: std.mem.Allocator,
        inner: PlacementMap.Iterator = undefined,
        entry: ?PlacementMap.Entry = null,
        layer_filter: PlacementLayer = .all,
    }
else
    void;

/// C: GhosttyKittyGraphicsData
pub const Data = enum(c_int) {
    invalid = 0,
    placement_iterator = 1,
    generation = 2,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .placement_iterator => PlacementIterator,
            .generation => u64,
        };
    }
};

/// C: GhosttyKittyGraphicsPlacementData
pub const PlacementData = enum(c_int) {
    invalid = 0,
    image_id = 1,
    placement_id = 2,
    is_virtual = 3,
    x_offset = 4,
    y_offset = 5,
    source_x = 6,
    source_y = 7,
    source_width = 8,
    source_height = 9,
    columns = 10,
    rows = 11,
    z = 12,

    pub fn OutType(comptime self: PlacementData) type {
        return switch (self) {
            .invalid => void,
            .image_id, .placement_id => u32,
            .is_virtual => bool,
            .x_offset,
            .y_offset,
            .source_x,
            .source_y,
            .source_width,
            .source_height,
            .columns,
            .rows,
            => u32,
            .z => i32,
        };
    }
};

pub fn get(
    graphics_: KittyGraphics,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            graphics_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    graphics_: KittyGraphics,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const storage = graphics_;
    switch (data) {
        .invalid => return .invalid_value,
        .placement_iterator => {
            const it = out.* orelse return .invalid_value;
            it.* = .{
                .alloc = it.alloc,
                .inner = storage.placements.iterator(),
                .layer_filter = it.layer_filter,
            };
        },
        .generation => out.* = storage.generation,
    }
    return .success;
}

/// C: GhosttyKittyPlacementLayer
pub const PlacementLayer = enum(c_int) {
    all = 0,
    below_bg = 1,
    below_text = 2,
    above_text = 3,

    fn matches(self: PlacementLayer, z: i32) bool {
        return switch (self) {
            .all => true,
            .below_bg => z < std.math.minInt(i32) / 2,
            .below_text => z >= std.math.minInt(i32) / 2 and z < 0,
            .above_text => z >= 0,
        };
    }
};

/// C: GhosttyKittyGraphicsPlacementIteratorOption
pub const PlacementIteratorOption = enum(c_int) {
    layer = 0,

    pub fn InType(comptime self: PlacementIteratorOption) type {
        return switch (self) {
            .layer => PlacementLayer,
        };
    }
};

/// C: GhosttyKittyImageFormat
pub const ImageFormat = kitty_cmd.Transmission.Format;

/// C: GhosttyKittyImageCompression
pub const ImageCompression = kitty_cmd.Transmission.Compression;

/// C: GhosttyKittyGraphicsImageData
pub const ImageData = enum(c_int) {
    invalid = 0,
    id = 1,
    number = 2,
    width = 3,
    height = 4,
    format = 5,
    compression = 6,
    data_ptr = 7,
    data_len = 8,
    generation = 9,
    frame_count = 10,
    animation_state = 11,
    current_frame = 12,
    max_loops = 13,
    current_loop = 14,
    pending_frames = 15,

    pub fn OutType(comptime self: ImageData) type {
        return switch (self) {
            .invalid => void,
            .id, .number, .width, .height => u32,
            .frame_count, .current_frame, .max_loops, .current_loop => u32,
            .animation_state => AnimationState,
            .pending_frames => bool,
            .format => ImageFormat,
            .compression => ImageCompression,
            .data_ptr => [*]const u8,
            .data_len => usize,
            .generation => u64,
        };
    }
};

/// C: GhosttyKittyAnimationState
pub const AnimationState = enum(c_int) {
    none = 0,
    stopped = 1,
    loading = 2,
    running = 3,
};

/// C: GhosttyKittyGraphicsFrameData
pub const FrameData = enum(c_int) {
    invalid = 0,
    format = 1,
    compression = 2,
    data_ptr = 3,
    data_len = 4,
    generation = 5,
    gap_ms = 6,

    pub fn OutType(comptime self: FrameData) type {
        return switch (self) {
            .invalid => void,
            .format => ImageFormat,
            .compression => ImageCompression,
            .data_ptr => [*]const u8,
            .data_len => usize,
            .generation => u64,
            .gap_ms => u32,
        };
    }
};

fn screenStorage(t: *Terminal, screen: ScreenSet.Key) ?*kitty_storage.ImageStorage {
    return &(t.screens.get(screen) orelse return null).kitty_images;
}

/// Write one data kind of a frame to the C value `out`. The `data_ptr`
/// kind needs the pixels, so it is for callers that hold the terminal
/// still while the pointer is used.
pub fn writeFrameValue(info: kitty_image.Image.FrameInfo, data: FrameData, out: ?*anyopaque) Result {
    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| writeFrameValueTyped(
            info,
            comptime_data,
            @ptrCast(@alignCast(out orelse return .invalid_value)),
        ),
    };
}

fn writeFrameValueTyped(
    info: kitty_image.Image.FrameInfo,
    comptime data: FrameData,
    out: *data.OutType(),
) Result {
    switch (data) {
        .invalid => return .invalid_value,
        .format => out.* = info.format,
        .compression => out.* = .none,
        .data_ptr => out.* = (info.bytes orelse return .no_value).ptr,
        .data_len => out.* = info.len,
        .generation => out.* = info.serial,
        .gap_ms => out.* = info.gap_ms,
    }
    return .success;
}

/// The result code of a frame lookup that failed.
pub fn frameLookupResult(err: kitty_storage.ImageStorage.FrameError) Result {
    return switch (err) {
        error.NoImage => .no_value,
        error.NoFrame => .invalid_value,
    };
}

pub fn frame_get(
    terminal_: terminal_c.Terminal,
    screen: ScreenSet.Key,
    image_id: u32,
    frame: u32,
    data: FrameData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;
    const t = terminal_c.zigTerminal(terminal_) orelse return .invalid_value;
    const storage = screenStorage(t, screen) orelse return .no_value;
    const info = storage.frameInfo(image_id, frame) catch |err| return frameLookupResult(err);
    return writeFrameValue(info, data, out);
}

pub fn frame_get_multi(
    terminal_: terminal_c.Terminal,
    screen: ScreenSet.Key,
    image_id: u32,
    frame: u32,
    count: usize,
    keys: ?[*]const FrameData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;
    const t = terminal_c.zigTerminal(terminal_) orelse return .invalid_value;
    const storage = screenStorage(t, screen) orelse return .no_value;
    const info = storage.frameInfo(image_id, frame) catch |err| return frameLookupResult(err);

    for (0..count) |i| {
        const result = writeFrameValue(info, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

/// Where the pixels of a frame come from.
pub const FrameSource = union(enum) {
    /// Pixels to copy.
    copy: []const u8,

    /// A read-only mapping that the terminal takes over on success.
    mapping: struct {
        base: ?*anyopaque,
        map_len: usize,
        offset: usize,
        len: usize,
    },
};

/// Make the frame data of a source. This allocates, so a caller that holds
/// a lock around the terminal calls it before taking the lock. The data
/// goes to `finishFrame` with the answer of `ImageStorage.storeFrame`.
pub fn prepareFrame(alloc: std.mem.Allocator, source: FrameSource) error{ InvalidValue, OutOfMemory }!kitty_image.Image.Data {
    switch (source) {
        .copy => |pixels| return .{ .complete = try alloc.dupe(u8, pixels) },
        .mapping => |m| {
            const base = m.base orelse return error.InvalidValue;
            if (@intFromPtr(base) % std.heap.pageSize() != 0) return error.InvalidValue;
            const end = std.math.add(usize, m.offset, m.len) catch return error.InvalidValue;
            if (end > m.map_len) return error.InvalidValue;
            const memory: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(base));
            return .{ .mapped = try kitty_image.Image.Mapping.init(alloc, memory[0..m.map_len], m.offset, end) };
        },
    }
}

/// The result code of a failed `prepareFrame`. A mapping that cannot be
/// taken stays with the caller.
pub fn prepareResult(err: error{ InvalidValue, OutOfMemory }) Result {
    return switch (err) {
        error.InvalidValue => .invalid_value,
        error.OutOfMemory => .out_of_memory,
    };
}

/// The answer of a frame store as a result code. A copy is freed when the
/// store refused it. A refused mapping stays the caller's: only its
/// bookkeeping is freed.
pub fn finishFrame(
    alloc: std.mem.Allocator,
    data: kitty_image.Image.Data,
    answer: kitty_storage.ImageStorage.FrameAttach,
) Result {
    switch (answer) {
        .attached => return .success,
        .no_value, .invalid_value => {
            switch (data) {
                .mapped => |mapping| alloc.destroy(mapping),
                else => {
                    var owned = data;
                    owned.deinit(alloc);
                },
            }
            return if (answer == .no_value) .no_value else .invalid_value;
        },
    }
}

pub fn frame_attach(
    terminal_: terminal_c.Terminal,
    screen: ScreenSet.Key,
    image_id: u32,
    frame: u32,
    generation: u64,
    pixels: ?[*]const u8,
    len: usize,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;
    const p = pixels orelse return .invalid_value;
    return frameStore(terminal_, screen, image_id, frame, generation, .{ .copy = p[0..len] });
}

pub fn frame_adopt(
    terminal_: terminal_c.Terminal,
    screen: ScreenSet.Key,
    image_id: u32,
    frame: u32,
    generation: u64,
    base: ?*anyopaque,
    map_len: usize,
    offset: usize,
    len: usize,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;
    return frameStore(terminal_, screen, image_id, frame, generation, .{ .mapping = .{
        .base = base,
        .map_len = map_len,
        .offset = offset,
        .len = len,
    } });
}

fn frameStore(
    terminal_: terminal_c.Terminal,
    screen: ScreenSet.Key,
    image_id: u32,
    frame: u32,
    generation: u64,
    source: FrameSource,
) Result {
    const t = terminal_c.zigTerminal(terminal_) orelse return .invalid_value;
    if (frame == 0) return .invalid_value;
    // Serial 0 is a frame with no identity, which no fetch can complete.
    if (generation == 0) return .no_value;
    const s = t.screens.get(screen) orelse return .no_value;
    const data = prepareFrame(s.alloc, source) catch |err| return prepareResult(err);
    return finishFrame(s.alloc, data, s.kitty_images.storeFrame(t.io(), image_id, frame, generation, data));
}

pub fn animation_tick(
    graphics_: KittyGraphics,
    now_ms: u64,
    next_ms: ?*u64,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const out = next_ms orelse return .invalid_value;
    const storage = graphics_;

    // The tick needs an Io only to hand out new generation numbers.
    // The storage handle doesn't carry one, but TinyIo has no state,
    // so a fresh one works just as well as the terminal's.
    const delay = storage.animationTick(
        terminal_c.Io.init.io(),
        now_ms,
    ) orelse return .no_value;
    // The Zig tick returns a delay. The C API returns the absolute
    // time instead, so callers don't have to remember when they
    // called.
    out.* = now_ms +| delay;
    return .success;
}

pub fn image_get_handle(
    graphics_: KittyGraphics,
    image_id: u32,
) callconv(lib.calling_conv) ImageHandle {
    if (comptime !build_options.kitty_graphics) return null;

    const storage = graphics_;
    return storage.images.getPtr(image_id);
}

pub fn screen_image(
    terminal_: terminal_c.Terminal,
    screen: ScreenSet.Key,
    image_id: u32,
) callconv(lib.calling_conv) ImageHandle {
    if (comptime !build_options.kitty_graphics) return null;
    const t = terminal_c.zigTerminal(terminal_) orelse return null;
    const storage = screenStorage(t, screen) orelse return null;
    return storage.images.getPtr(image_id);
}

pub fn image_get(
    image_: ImageHandle,
    data: ImageData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| imageGetTyped(
            image_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn image_get_multi(
    image_: ImageHandle,
    count: usize,
    keys: ?[*]const ImageData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = image_get(image_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn imageGetTyped(
    image_: ImageHandle,
    comptime data: ImageData,
    out: *data.OutType(),
) Result {
    const image = image_ orelse return .invalid_value;

    switch (data) {
        .invalid => return .invalid_value,
        .id => out.* = image.id,
        .number => out.* = image.number,
        .width => out.* = image.width,
        .height => out.* = image.height,
        .format => out.* = image.format,
        .compression => out.* = image.compression,
        // For animated images this is the current animation frame's
        // data; the image generation changes whenever the current
        // frame does, so generation-keyed caches stay coherent.
        .data_ptr => out.* = (image.renderData().bytes() orelse return .no_value).ptr,
        .data_len => out.* = image.renderData().len(),
        .generation => out.* = image.generation,
        .frame_count => out.* = if (image.animation) |anim| anim.frameCount() else 1,
        .animation_state => out.* = if (image.animation) |anim| switch (anim.state) {
            .stopped => .stopped,
            .loading => .loading,
            .running => .running,
        } else .none,
        .current_frame => out.* = if (image.animation) |anim| anim.current_index + 1 else 1,
        .max_loops => out.* = if (image.animation) |anim| anim.max_loops else 0,
        .current_loop => out.* = if (image.animation) |anim| anim.current_loop else 0,
        .pending_frames => out.* = image.hasPendingFrames(),
    }

    return .success;
}

pub fn placement_iterator_new(
    alloc_: ?*const CAllocator,
    out: *PlacementIterator,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) {
        out.* = null;
        return .no_value;
    }
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(PlacementIteratorWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    ptr.* = .{ .alloc = alloc };
    out.* = ptr;
    return .success;
}

pub fn placement_iterator_free(iter_: PlacementIterator) callconv(lib.calling_conv) void {
    if (comptime !build_options.kitty_graphics) return;
    const iter = iter_ orelse return;
    iter.alloc.destroy(iter);
}

pub fn placement_iterator_set(
    iter_: PlacementIterator,
    option: PlacementIteratorOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(PlacementIteratorOption, @backingInt(option)) orelse {
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| placementIteratorSetTyped(
            iter_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn placementIteratorSetTyped(
    iter_: PlacementIterator,
    comptime option: PlacementIteratorOption,
    value: *const option.InType(),
) Result {
    const iter = iter_ orelse return .invalid_value;
    switch (option) {
        .layer => iter.layer_filter = value.*,
    }
    return .success;
}

pub fn placement_iterator_next(iter_: PlacementIterator) callconv(lib.calling_conv) bool {
    if (comptime !build_options.kitty_graphics) return false;

    const iter = iter_ orelse return false;
    while (iter.inner.next()) |entry| {
        if (iter.layer_filter.matches(entry.value_ptr.z)) {
            iter.entry = entry;
            return true;
        }
    }
    return false;
}

pub fn placement_get(
    iter_: PlacementIterator,
    data: PlacementData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| placementGetTyped(
            iter_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn placement_get_multi(
    iter_: PlacementIterator,
    count: usize,
    keys: ?[*]const PlacementData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = placement_get(iter_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn placementGetTyped(
    iter_: PlacementIterator,
    comptime data: PlacementData,
    out: *data.OutType(),
) Result {
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;

    const key = entry.key_ptr;
    const val = entry.value_ptr;

    switch (data) {
        .invalid => return .invalid_value,
        .image_id => out.* = key.image_id,
        .placement_id => out.* = key.placement_id.id,
        .is_virtual => out.* = val.location == .virtual,
        .x_offset => out.* = val.x_offset,
        .y_offset => out.* = val.y_offset,
        .source_x => out.* = val.source_x,
        .source_y => out.* = val.source_y,
        .source_width => out.* = val.source_width,
        .source_height => out.* = val.source_height,
        .columns => out.* = val.columns,
        .rows => out.* = val.rows,
        .z => out.* = val.z,
    }

    return .success;
}

pub fn placement_rect(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out: *selection_c.CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const r = entry.value_ptr.rect(
        image.*,
        wrapper.terminal,
    ) orelse return .no_value;

    out.* = .{
        .start = grid_ref.CGridRef.fromPin(r.top_left),
        .end = grid_ref.CGridRef.fromPin(r.bottom_right),
        .rectangle = true,
    };

    return .success;
}

pub fn placement_pixel_size(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_width: *u32,
    out_height: *u32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const s = entry.value_ptr.pixelSize(image.*, wrapper.terminal);

    out_width.* = s.width;
    out_height.* = s.height;

    return .success;
}

pub fn placement_grid_size(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_cols: *u32,
    out_rows: *u32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const s = entry.value_ptr.gridSize(image.*, wrapper.terminal);

    out_cols.* = s.cols;
    out_rows.* = s.rows;

    return .success;
}

pub fn placement_viewport_pos(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_col: *i32,
    out_row: *i32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;

    const vp = computeViewportPos(entry.value_ptr, image, wrapper.terminal);
    if (!vp.visible) return .no_value;

    out_col.* = vp.col;
    out_row.* = vp.row;

    return .success;
}

pub fn placement_source_rect(
    iter_: PlacementIterator,
    image_: ImageHandle,
    out_x: *u32,
    out_y: *u32,
    out_width: *u32,
    out_height: *u32,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const p = entry.value_ptr;

    const source = p.sourceRect(image.*);

    out_x.* = source.x;
    out_y.* = source.y;
    out_width.* = source.width;
    out_height.* = source.height;

    return .success;
}

/// C: GhosttyKittyGraphicsPlacementRenderInfo
pub const PlacementRenderInfo = extern struct {
    size: usize = @sizeOf(PlacementRenderInfo),
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    grid_cols: u32 = 0,
    grid_rows: u32 = 0,
    viewport_col: i32 = 0,
    viewport_row: i32 = 0,
    viewport_visible: bool = false,
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,
};

pub fn placement_render_info(
    iter_: PlacementIterator,
    image_: ImageHandle,
    terminal_: terminal_c.Terminal,
    out_: ?*PlacementRenderInfo,
) callconv(lib.calling_conv) Result {
    if (comptime !build_options.kitty_graphics) return .no_value;

    const wrapper = terminal_ orelse return .invalid_value;
    const image = image_ orelse return .invalid_value;
    const iter = iter_ orelse return .invalid_value;
    const entry = iter.entry orelse return .invalid_value;
    const out = out_ orelse return .invalid_value;
    if (out.size < @sizeOf(PlacementRenderInfo)) return .invalid_value;

    const p = entry.value_ptr;

    const ps = p.pixelSize(image.*, wrapper.terminal);
    out.pixel_width = ps.width;
    out.pixel_height = ps.height;

    const gs = p.gridSize(image.*, wrapper.terminal);
    out.grid_cols = gs.cols;
    out.grid_rows = gs.rows;

    const vp = computeViewportPos(p, image, wrapper.terminal);
    out.viewport_col = vp.col;
    out.viewport_row = vp.row;
    out.viewport_visible = vp.visible;

    const source = p.sourceRect(image.*);
    out.source_x = source.x;
    out.source_y = source.y;
    out.source_width = source.width;
    out.source_height = source.height;

    return .success;
}

/// Compute viewport-relative position of a placement, for the C API
/// functions that inspect the storage. Drawing doesn't use this. The
/// render state positions placements on its own.
///
/// Converts the placement's internal pin to viewport-relative column
/// and row coordinates by getting screen-absolute coordinates for
/// both the pin and the viewport origin, then subtracting to get
/// viewport-relative coordinates. The row value can be negative when
/// the placement's origin has scrolled above the top of the viewport.
///
/// A placement is considered not visible if it is a virtual (unicode
/// placeholder) placement, its tracked content has been pruned, or it is
/// fully off-screen (its bottom edge is above the viewport or its top edge is
/// at or below the viewport's last row).
fn computeViewportPos(
    p: *const kitty_storage.ImageStorage.Placement,
    image: *const Image,
    t: *Terminal,
) struct { col: i32, row: i32, visible: bool } {
    // Virtual placements use unicode placeholders and don't have a
    // screen position of their own. Relative placements are anchored at
    // the root of their parent chain, offset by the accumulated chain
    // offsets. A chain rooted at a virtual placement has no resolvable
    // position here: its origin is the parent's placeholder cells, which
    // the render state finds while it scans the captured rows.
    const origin: struct {
        pin: *const PageList.Pin,
        col_offset: i32 = 0,
        row_offset: i32 = 0,
    } = switch (p.location) {
        .pin => |pin| .{ .pin = pin },
        .virtual => return .{ .col = 0, .row = 0, .visible = false },
        .relative => |rel| origin: {
            const storage = &t.screens.active.kitty_images;
            const chain = storage.resolveChain(rel) orelse
                return .{ .col = 0, .row = 0, .visible = false };
            switch (chain.root.location) {
                .pin => |root_pin| break :origin .{
                    .pin = root_pin,
                    .col_offset = chain.horizontal_offset,
                    .row_offset = chain.vertical_offset,
                },
                .virtual => return .{ .col = 0, .row = 0, .visible = false },
                .relative => unreachable, // resolveChain roots are never relative
            }
        },
    };

    const pin = origin.pin;
    if (pin.garbage) return .{ .col = 0, .row = 0, .visible = false };

    // Convert both the placement's pin and the viewport's top-left
    // corner to screen-absolute coordinates so we can subtract them
    // to get viewport-relative coordinates.
    const pages = &t.screens.active.pages;
    const pin_screen = pages.pointFromPin(.screen, pin.*) orelse
        return .{ .col = 0, .row = 0, .visible = false };
    const vp_tl = pages.getTopLeft(.viewport);
    const vp_screen = pages.pointFromPin(.screen, vp_tl) orelse
        return .{ .col = 0, .row = 0, .visible = false };

    // Subtracting viewport origin from the pin gives us viewport-
    // relative coordinates. The row can be negative when the
    // placement has partially scrolled above the viewport, and both
    // can be negative for relative placements with negative offsets.
    const vp_row: i32 = (@as(i32, @intCast(pin_screen.screen.y)) -
        @as(i32, @intCast(vp_screen.screen.y))) +| origin.row_offset;
    const vp_col: i32 = @as(i32, @intCast(pin_screen.screen.x)) +|
        origin.col_offset;

    // A placement is invisible if its bottom edge (row + height) is
    // above the viewport, or its top edge is at or below the viewport's
    // last row. The same applies horizontally: a pin's column is always
    // in bounds, but a relative placement's offsets can push it fully
    // off either side.
    const grid_size = p.gridSize(image.*, t);
    const bottom_row = @as(i64, vp_row) + @as(i64, grid_size.rows);
    const right_col = @as(i64, vp_col) + @as(i64, grid_size.cols);
    const visible = bottom_row > 0 and vp_row < @as(i32, t.rows) and
        right_col > 0 and vp_col < @as(i32, t.cols);

    return .{ .col = vp_col, .row = vp_row, .visible = visible };
}

test "placement_iterator new/free" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    try testing.expect(iter != null);
    placement_iterator_free(iter);
}

test "placement_iterator free null" {
    placement_iterator_free(null);
}

test "placement_iterator next on empty storage" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(!placement_iterator_next(iter));
}

test "placement_iterator get before next returns invalid" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    var image_id: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_get(iter, .image_id, @ptrCast(&image_id)));
}

test "placement_iterator with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit and display a 1x2 RGB image (image_id=1, placement_id=1).
    // a=T (transmit+display), t=d (direct), f=24 (RGB), i=1, p=1
    // s=1,v=2 (1x2 pixels), c=10,r=1 (10 cols, 1 row)
    // //////// = 8 base64 chars = 6 bytes = 1*2*3 RGB bytes
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    // Should have exactly one placement.
    try testing.expect(placement_iterator_next(iter));

    var image_id: u32 = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .image_id, @ptrCast(&image_id)));
    try testing.expectEqual(1, image_id);

    var placement_id: u32 = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&placement_id)));
    try testing.expectEqual(1, placement_id);

    var is_virtual: bool = undefined;
    try testing.expectEqual(Result.success, placement_get(iter, .is_virtual, @ptrCast(&is_virtual)));
    try testing.expect(!is_virtual);

    // No more placements.
    try testing.expect(!placement_iterator_next(iter));
}

test "placement_iterator with multiple placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit image 1 then display it twice with different placement IDs.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display1 = "\x1b_Ga=p,i=1,p=1,c=10,r=1;\x1b\\";
    const display2 = "\x1b_Ga=p,i=1,p=2,c=5,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display1.ptr, display1.len);
    terminal_c.vt_write(t, display2.ptr, display2.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    // Count placements and collect image IDs.
    var count: usize = 0;
    var seen_p1 = false;
    var seen_p2 = false;
    while (placement_iterator_next(iter)) {
        count += 1;

        var image_id: u32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .image_id, @ptrCast(&image_id)));
        try testing.expectEqual(1, image_id);

        var placement_id: u32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .placement_id, @ptrCast(&placement_id)));
        if (placement_id == 1) seen_p1 = true;
        if (placement_id == 2) seen_p2 = true;
    }

    try testing.expectEqual(2, count);
    try testing.expect(seen_p1);
    try testing.expect(seen_p2);
}

test "placement_iterator_set layer filter" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit image 1.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);

    // Display with z=5 (above text), z=-1 (below text), z=-1073741825 (below bg).
    // INT32_MIN/2 = -1073741824, so -1073741825 < INT32_MIN/2.
    const d1 = "\x1b_Ga=p,i=1,p=1,z=5;\x1b\\";
    const d2 = "\x1b_Ga=p,i=1,p=2,z=-1;\x1b\\";
    const d3 = "\x1b_Ga=p,i=1,p=3,z=-1073741825;\x1b\\";
    terminal_c.vt_write(t, d1.ptr, d1.len);
    terminal_c.vt_write(t, d2.ptr, d2.len);
    terminal_c.vt_write(t, d3.ptr, d3.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    // Filter: above_text (z >= 0) — should yield only p=1.
    var layer = PlacementLayer.above_text;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    var count: u32 = 0;
    while (placement_iterator_next(iter)) {
        var z: i32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .z, @ptrCast(&z)));
        try testing.expect(z >= 0);
        count += 1;
    }
    try testing.expectEqual(1, count);

    // Filter: below_text (INT32_MIN/2 <= z < 0) — should yield only p=2.
    layer = .below_text;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    count = 0;
    while (placement_iterator_next(iter)) {
        var z: i32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .z, @ptrCast(&z)));
        try testing.expect(z >= std.math.minInt(i32) / 2 and z < 0);
        count += 1;
    }
    try testing.expectEqual(1, count);

    // Filter: below_bg (z < INT32_MIN/2) — should yield only p=3.
    layer = .below_bg;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    count = 0;
    while (placement_iterator_next(iter)) {
        var z: i32 = undefined;
        try testing.expectEqual(Result.success, placement_get(iter, .z, @ptrCast(&z)));
        try testing.expect(z < std.math.minInt(i32) / 2);
        count += 1;
    }
    try testing.expectEqual(1, count);

    // Filter: all — should yield all 3.
    layer = .all;
    try testing.expectEqual(Result.success, placement_iterator_set(iter, .layer, @ptrCast(&layer)));
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));

    count = 0;
    while (placement_iterator_next(iter)) count += 1;
    try testing.expectEqual(3, count);
}

test "image_get_handle returns null for missing id" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    try testing.expectEqual(@as(ImageHandle, null), image_get_handle(graphics, 999));
}

test "image_get_handle and image_get with transmitted image" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit a 1x2 RGB image with image_id=1.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var id: u32 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .id, @ptrCast(&id)));
    try testing.expectEqual(1, id);

    var w: u32 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .width, @ptrCast(&w)));
    try testing.expectEqual(1, w);

    var h: u32 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .height, @ptrCast(&h)));
    try testing.expectEqual(2, h);

    var fmt: ImageFormat = undefined;
    try testing.expectEqual(Result.success, image_get(img, .format, @ptrCast(&fmt)));
    try testing.expectEqual(.rgb, fmt);

    var comp: ImageCompression = undefined;
    try testing.expectEqual(Result.success, image_get(img, .compression, @ptrCast(&comp)));
    try testing.expectEqual(.none, comp);

    var data_len: usize = undefined;
    try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&data_len)));
    try testing.expect(data_len > 0);
}

test "image_get exposes pending metadata without a data pointer" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const alloc = lib.alloc.default(&lib.alloc.test_allocator);
    const pending = try graphics.addPendingImage(testing.io, alloc, terminal_c.zigTerminal(t).?.screens.active, .{
        .id = 42,
        .number = 7,
        .width = 1,
        .height = 4,
        .format = .rgb,
        .data = .{ .pending = 12 },
    });

    const img = image_get_handle(graphics, 42);
    try testing.expect(img != null);

    var number: u32 = 0;
    try testing.expectEqual(Result.success, image_get(img, .number, @ptrCast(&number)));
    try testing.expectEqual(@as(u32, 7), number);

    var data_len: usize = 0;
    try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&data_len)));
    try testing.expectEqual(@as(usize, 12), data_len);

    var data_ptr: [*]const u8 = undefined;
    try testing.expectEqual(Result.no_value, image_get(img, .data_ptr, @ptrCast(&data_ptr)));

    const pixels = try alloc.alloc(u8, 12);
    @memset(pixels, '*');
    try testing.expect(pending.complete(graphics, testing.io, pixels));
    const completed_img = image_get_handle(graphics, 42);
    try testing.expect(completed_img != null);
    try testing.expectEqual(Result.success, image_get(completed_img, .data_ptr, @ptrCast(&data_ptr)));
    try testing.expectEqualSlices(u8, pixels, data_ptr[0..data_len]);
}

test "placement_rect with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Set cell size so grid calculations are deterministic.
    // 80 cols * 10px = 800px, 24 rows * 20px = 480px.
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image at cursor (0,0).
    // c=10,r=1 => 10 columns, 1 row.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, placement_rect(iter, img, t, &sel));

    // Placement starts at cursor origin (0,0).
    try testing.expectEqual(0, sel.start.x);
    try testing.expectEqual(0, sel.start.y);

    // 10 columns wide, 1 row tall => bottom-right is (9, 0).
    try testing.expectEqual(9, sel.end.x);
    try testing.expectEqual(0, sel.end.y);

    try testing.expect(sel.rectangle);
}

test "placement_rect null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.invalid_value, placement_rect(null, null, null, &sel));
}

test "placement_pixel_size with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // 80 cols * 10px = 800px, 24 rows * 20px = 480px.
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image with c=10,r=1.
    // 10 cols * 10px = 100px width, 1 row * 20px = 20px height.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_pixel_size(iter, img, t, &w, &h));

    try testing.expectEqual(100, w);
    try testing.expectEqual(20, h);
}

test "placement_pixel_size null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_pixel_size(null, null, null, &w, &h));
}

test "placement_grid_size with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // 80 cols * 10px = 800px, 24 rows * 20px = 480px.
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image with c=10,r=1.
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var cols: u32 = undefined;
    var rows: u32 = undefined;
    try testing.expectEqual(Result.success, placement_grid_size(iter, img, t, &cols, &rows));

    try testing.expectEqual(10, cols);
    try testing.expectEqual(1, rows);
}

test "placement_grid_size null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var cols: u32 = undefined;
    var rows: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_grid_size(null, null, null, &cols, &rows));
}

test "placement_viewport_pos with transmit and display" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display at cursor (0,0).
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(
        t,
        .kitty_graphics,
        @ptrCast(&graphics),
    ));

    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(
        &lib.alloc.test_allocator,
        &iter,
    ));
    defer placement_iterator_free(iter);

    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));

    try testing.expectEqual(0, col);
    try testing.expectEqual(0, row);
}

test "placement_viewport_pos fully off-screen above" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, then display at cursor (0,0) spanning 1 row.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll the image completely off: 10 newlines in a 5-row terminal
    // scrolls by 5+ rows, so a 1-row image at row 0 is fully gone.
    const scroll = "\n\n\n\n\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.no_value, placement_viewport_pos(iter, img, t, &col, &row));
}

test "placement_viewport_pos top off-screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, display at cursor (0,0) spanning 4 rows.
    // C=1 prevents cursor movement after display.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=4,C=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll by 2: cursor starts at row 0, 4 newlines to reach bottom,
    // then 2 more to scroll by 2. Image top-left moves to vp_row=-2,
    // but bottom rows -2+4=2 > 0 so it's still partially visible.
    const scroll = "\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));
    try testing.expectEqual(0, col);
    try testing.expectEqual(-2, row);
}

test "placement_viewport_pos bottom off-screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, move cursor to row 3 (1-based: row 4), display spanning 4 rows.
    // C=1 prevents cursor movement after display.
    // Image occupies rows 3-6 but viewport only has rows 0-4, so bottom is clipped.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const cursor = "\x1b[4;1H";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=4,C=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, cursor.ptr, cursor.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));
    try testing.expectEqual(0, col);
    try testing.expectEqual(3, row);
}

test "placement_viewport_pos top and bottom off-screen" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    // Transmit image, display at cursor (0,0) spanning 10 rows.
    // C=1 prevents cursor movement after display.
    // After scrolling by 3, image occupies vp rows -3..6, viewport is 0..4,
    // so both top and bottom are clipped but center is visible.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=10,C=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll by 3: 4 newlines to reach bottom + 3 more to scroll.
    const scroll = "\n\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.success, placement_viewport_pos(iter, img, t, &col, &row));
    try testing.expectEqual(0, col);
    try testing.expectEqual(-3, row);
}

test "placement_viewport_pos null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var col: i32 = undefined;
    var row: i32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_viewport_pos(null, null, null, &col, &row));
}

test "placement_source_rect defaults to full image" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit and display a 1x2 RGB image with no source rect specified.
    // source_width=0 and source_height=0 should resolve to full image (1x2).
    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_source_rect(iter, img, &x, &y, &w, &h));
    try testing.expectEqual(0, x);
    try testing.expectEqual(0, y);
    try testing.expectEqual(1, w);
    try testing.expectEqual(2, h);
}

test "placement_source_rect with explicit source rect" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit a 4x4 RGBA image (64 bytes = 4*4*4).
    // Base64 of 64 zero bytes: 88 chars (21 full groups + AA== padding).
    const transmit = "\x1b_Ga=t,t=d,f=32,i=1,s=4,v=4;" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" ++
        "\x1b\\";
    // Display with explicit source rect: x=1, y=1, w=2, h=2.
    const display = "\x1b_Ga=p,i=1,p=1,x=1,y=1,w=2,h=2;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_source_rect(iter, img, &x, &y, &w, &h));
    try testing.expectEqual(1, x);
    try testing.expectEqual(1, y);
    try testing.expectEqual(2, w);
    try testing.expectEqual(2, h);
}

test "placement_source_rect clamps to image bounds" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    // Transmit a 4x4 RGBA image (64 bytes = 4*4*4).
    const transmit = "\x1b_Ga=t,t=d,f=32,i=1,s=4,v=4;" ++
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" ++
        "\x1b\\";
    // Display with source rect that exceeds image bounds: x=3, y=3, w=10, h=10.
    // Should clamp to x=3, y=3, w=1, h=1.
    const display = "\x1b_Ga=p,i=1,p=1,x=3,y=3,w=10,h=10;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.success, placement_source_rect(iter, img, &x, &y, &w, &h));
    try testing.expectEqual(3, x);
    try testing.expectEqual(3, y);
    try testing.expectEqual(1, w);
    try testing.expectEqual(1, h);

    var pixel_width: u32 = undefined;
    var pixel_height: u32 = undefined;
    try testing.expectEqual(
        Result.success,
        placement_pixel_size(iter, img, t, &pixel_width, &pixel_height),
    );
    try testing.expectEqual(1, pixel_width);
    try testing.expectEqual(1, pixel_height);
}

test "placement_source_rect null args return invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var x: u32 = undefined;
    var y: u32 = undefined;
    var w: u32 = undefined;
    var h: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, placement_source_rect(null, null, &x, &y, &w, &h));
}

test "image_get on null returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = undefined;
    try testing.expectEqual(Result.invalid_value, image_get(null, .id, @ptrCast(&id)));
}

test "placement_render_info returns all fields" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(ri.viewport_visible);
    try testing.expectEqual(0, ri.viewport_col);
    try testing.expectEqual(0, ri.viewport_row);
    try testing.expectEqual(10, ri.grid_cols);
    try testing.expectEqual(1, ri.grid_rows);
    try testing.expectEqual(0, ri.source_x);
    try testing.expectEqual(0, ri.source_y);
    try testing.expectEqual(1, ri.source_width);
    try testing.expectEqual(2, ri.source_height);

    const entry = iter.?.entry.?;
    const pin = switch (entry.value_ptr.location) {
        .pin => |pin| pin,
        .virtual, .relative => unreachable,
    };
    pin.garbage = true;

    ri = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(!ri.viewport_visible);

    var rect: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.no_value, placement_rect(iter, img, t, &rect));
}

test "placement_render_info handles maximum grid dimensions" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=1,r=4294967295,C=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(ri.viewport_visible);
    try testing.expectEqual(std.math.maxInt(u32), ri.grid_rows);
}

test "placement_render_info off-screen sets viewport_visible false" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        5,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 5, 10, 20));

    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=1;\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    terminal_c.vt_write(t, display.ptr, display.len);

    // Scroll the image completely off-screen.
    const scroll = "\n\n\n\n\n\n\n\n\n\n";
    terminal_c.vt_write(t, scroll.ptr, scroll.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.success, placement_render_info(iter, img, t, &ri));
    try testing.expect(!ri.viewport_visible);
    // Other fields should still be populated.
    try testing.expectEqual(1, ri.grid_cols);
    try testing.expectEqual(1, ri.grid_rows);
    try testing.expectEqual(1, ri.source_width);
    try testing.expectEqual(2, ri.source_height);
}

test "placement_render_info null returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var ri: PlacementRenderInfo = .{};
    try testing.expectEqual(Result.invalid_value, placement_render_info(null, null, null, &ri));
}

test "image_get_multi success" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var id: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var written: usize = 0;

    const keys = [_]ImageData{ .id, .width, .height };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&width), @ptrCast(&height) };
    try testing.expectEqual(Result.success, image_get_multi(img, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(1, id);
    try testing.expectEqual(1, width);
    try testing.expectEqual(2, height);
}

test "image_get_multi error sets out_written" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var written: usize = 99;

    const keys = [_]ImageData{ .id, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&id) };
    try testing.expectEqual(Result.invalid_value, image_get_multi(null, keys.len, &keys, &values, &written));
    try testing.expectEqual(0, written);
}

test "image_get_multi null keys returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var values = [_]?*anyopaque{@ptrCast(&id)};
    try testing.expectEqual(Result.invalid_value, image_get_multi(null, 1, null, &values, null));
}

test "placement_get_multi success" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.success, terminal_c.resize(t, 80, 24, 10, 20));

    const cmd = "\x1b_Ga=T,t=d,f=24,i=1,p=1,s=1,v=2,c=10,r=1;////////\x1b\\";
    terminal_c.vt_write(t, cmd.ptr, cmd.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    var iter: PlacementIterator = null;
    try testing.expectEqual(Result.success, placement_iterator_new(&lib.alloc.test_allocator, &iter));
    defer placement_iterator_free(iter);
    try testing.expectEqual(Result.success, get(graphics, .placement_iterator, @ptrCast(&iter)));
    try testing.expect(placement_iterator_next(iter));

    var image_id: u32 = 0;
    var columns: u32 = 0;
    var z: i32 = 99;
    var written: usize = 0;

    const keys = [_]PlacementData{ .image_id, .columns, .z };
    var values = [_]?*anyopaque{ @ptrCast(&image_id), @ptrCast(&columns), @ptrCast(&z) };
    try testing.expectEqual(Result.success, placement_get_multi(iter, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(1, image_id);
    try testing.expectEqual(10, columns);
    try testing.expectEqual(0, z);
}

test "placement_get_multi error sets out_written" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var written: usize = 99;

    const keys = [_]PlacementData{ .image_id, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&id) };
    try testing.expectEqual(Result.invalid_value, placement_get_multi(null, keys.len, &keys, &values, &written));
    try testing.expectEqual(0, written);
}

test "placement_get_multi null keys returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var id: u32 = 0;
    var values = [_]?*anyopaque{@ptrCast(&id)};
    try testing.expectEqual(Result.invalid_value, placement_get_multi(null, 1, null, &values, null));
}

test "storage generation via get" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    // Fresh storage: generation zero.
    var gen0: u64 = 99;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen0)));
    try testing.expectEqual(0, gen0);

    // Transmit bumps the generation.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen1: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen1)));
    try testing.expect(gen1 > gen0);

    // Unrelated terminal writes (plain text) do not bump it.
    const text = "hello world";
    terminal_c.vt_write(t, text.ptr, text.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen2: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen2)));
    try testing.expectEqual(gen1, gen2);

    // Placement bumps it.
    const display = "\x1b_Ga=p,i=1,p=1,c=1,r=1;\x1b\\";
    terminal_c.vt_write(t, display.ptr, display.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen3: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen3)));
    try testing.expect(gen3 > gen2);

    // Delete bumps it.
    const del = "\x1b_Ga=d,d=A\x1b\\";
    terminal_c.vt_write(t, del.ptr, del.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    var gen4: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen4)));
    try testing.expect(gen4 > gen3);
}

test "image generation detects same-sized retransmission" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit a 1x2 RGB image with id=1.
    const transmit1 = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit1.ptr, transmit1.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    var gen1: u64 = 0;
    var w1: u32 = 0;
    var h1: u32 = 0;
    var len1: usize = 0;
    {
        const img = image_get_handle(graphics, 1);
        try testing.expect(img != null);
        try testing.expectEqual(Result.success, image_get(img, .generation, @ptrCast(&gen1)));
        try testing.expectEqual(Result.success, image_get(img, .width, @ptrCast(&w1)));
        try testing.expectEqual(Result.success, image_get(img, .height, @ptrCast(&h1)));
        try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&len1)));
        try testing.expect(gen1 > 0);
    }

    // Retransmit the same ID with identical dimensions but different
    // pixel bytes. All size heuristics match; only the generation
    // reveals the change.
    const transmit2 = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;AAAAAAAA\x1b\\";
    terminal_c.vt_write(t, transmit2.ptr, transmit2.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    {
        const img = image_get_handle(graphics, 1);
        try testing.expect(img != null);
        var gen2: u64 = 0;
        var w2: u32 = 0;
        var h2: u32 = 0;
        var len2: usize = 0;
        try testing.expectEqual(Result.success, image_get(img, .generation, @ptrCast(&gen2)));
        try testing.expectEqual(Result.success, image_get(img, .width, @ptrCast(&w2)));
        try testing.expectEqual(Result.success, image_get(img, .height, @ptrCast(&h2)));
        try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&len2)));

        // Size heuristics are identical...
        try testing.expectEqual(w1, w2);
        try testing.expectEqual(h1, h2);
        try testing.expectEqual(len1, len2);

        // ...but the generation changed.
        try testing.expect(gen2 > gen1);
    }
}

test "image generation via image_get_multi" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    var id: u32 = 0;
    var generation: u64 = 0;
    var written: usize = 0;
    const keys = [_]ImageData{ .id, .generation };
    var values = [_]?*anyopaque{ @ptrCast(&id), @ptrCast(&generation) };
    try testing.expectEqual(Result.success, image_get_multi(img, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(1, id);
    try testing.expect(generation > 0);

    // The image stamp came from the same sequence as (and here, the
    // same event as) the storage stamp.
    var storage_gen: u64 = 0;
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&storage_gen)));
    try testing.expectEqual(storage_gen, generation);
}

test "image compression and format always report decoded data" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Transmit a zlib-compressed 1x1 RGB image (o=z). The payload is
    // base64(zlib([0xFF, 0x00, 0x00])).
    const compressed = comptime blk: {
        // zlib stream for the 3 bytes FF 00 00 (stored block).
        // 78 01: zlib header; 01: final stored block; 03 00 len;
        // FC FF nlen; FF 00 00 data; adler32 = 0x03000100 (big endian).
        const raw = [_]u8{ 0x78, 0x01, 0x01, 0x03, 0x00, 0xFC, 0xFF, 0xFF, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00 };
        var buf: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
        const enc = std.base64.standard.Encoder.encode(&buf, &raw);
        break :blk enc[0..enc.len].*;
    };
    const transmit = "\x1b_Ga=t,t=d,f=24,o=z,i=1,s=1,v=1;" ++ compressed ++ "\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    try testing.expect(img != null);

    // Compression must report NONE: the data was inflated at
    // transmission time.
    var comp: ImageCompression = undefined;
    try testing.expectEqual(Result.success, image_get(img, .compression, @ptrCast(&comp)));
    try testing.expectEqual(.none, comp);

    // Data is the decoded pixels: width * height * bpp.
    var data_len: usize = 0;
    try testing.expectEqual(Result.success, image_get(img, .data_len, @ptrCast(&data_len)));
    try testing.expectEqual(3, data_len);

    var data_ptr: [*]const u8 = undefined;
    try testing.expectEqual(Result.success, image_get(img, .data_ptr, @ptrCast(&data_ptr)));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00 }, data_ptr[0..data_len]);
}

test "generation never recurs across resets and screen switches" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    var gen: u64 = 0;

    // Transmit on the main screen.
    const transmit = "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2;////////\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    const gen_main = gen;
    try testing.expect(gen_main > 0);

    // Switch to the alternate screen: its storage is untouched, so its
    // generation is zero (which always means "empty").
    const alt_on = "\x1b[?1049h";
    terminal_c.vt_write(t, alt_on.ptr, alt_on.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expectEqual(0, gen);

    // A transmit on the alt screen draws from the same global sequence,
    // so its stamp is strictly greater than anything seen on the main
    // screen: an embedder keying a cache on the generation value alone
    // can never confuse the two storages.
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    const gen_alt = gen;
    try testing.expect(gen_alt > gen_main);

    // Back to the main screen: its generation is unchanged.
    const alt_off = "\x1b[?1049l";
    terminal_c.vt_write(t, alt_off.ptr, alt_off.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expectEqual(gen_main, gen);

    // Reset zeroes the storage (empty), and the next mutation continues
    // from the global sequence: past values are never reused for
    // different content.
    terminal_c.reset(t);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expectEqual(0, gen);

    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.success, get(graphics, .generation, @ptrCast(&gen)));
    try testing.expect(gen > gen_alt);
}

test "animation_tick advances a running animation" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Place a red 1x1 RGBA image and add a blue second frame that
    // shows for 40ms. The first frame starts with no display time,
    // so give it 30ms. Then start looping playback.
    const cmds = "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\" ++
        "\x1b_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\x1b\\" ++
        "\x1b_Ga=a,i=1,r=1,z=30\x1b\\" ++
        "\x1b_Ga=a,i=1,s=3\x1b\\";
    terminal_c.vt_write(t, cmds.ptr, cmds.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));

    const Snapshot = struct {
        gen: u64,
        pixel: [4]u8,

        fn read(g: KittyGraphics) !@This() {
            const img = image_get_handle(g, 1) orelse return error.TestUnexpectedResult;
            var gen: u64 = 0;
            var ptr: [*]const u8 = undefined;
            try testing.expectEqual(Result.success, image_get(img, .generation, @ptrCast(&gen)));
            try testing.expectEqual(Result.success, image_get(img, .data_ptr, @ptrCast(&ptr)));
            return .{ .gen = gen, .pixel = ptr[0..4].* };
        }
    };
    const red: [4]u8 = .{ 255, 0, 0, 255 };
    const blue: [4]u8 = .{ 0, 0, 255, 255 };

    // The first tick starts the first frame's 30ms timer.
    var next: u64 = 0;
    const s0 = try Snapshot.read(graphics);
    try testing.expectEqualSlices(u8, &red, &s0.pixel);
    try testing.expectEqual(Result.success, animation_tick(graphics, 1000, &next));
    try testing.expectEqual(@as(u64, 1030), next);
    try testing.expectEqual(s0, try Snapshot.read(graphics));

    // An early tick changes nothing and reports the same time.
    try testing.expectEqual(Result.success, animation_tick(graphics, 1010, &next));
    try testing.expectEqual(@as(u64, 1030), next);
    try testing.expectEqual(s0, try Snapshot.read(graphics));

    // On time, the blue frame shows with a new generation.
    try testing.expectEqual(Result.success, animation_tick(graphics, 1030, &next));
    try testing.expectEqual(@as(u64, 1070), next);
    const s1 = try Snapshot.read(graphics);
    try testing.expectEqualSlices(u8, &blue, &s1.pixel);
    try testing.expect(s1.gen > s0.gen);

    // It then loops back to the first frame.
    try testing.expectEqual(Result.success, animation_tick(graphics, 1070, &next));
    try testing.expectEqual(@as(u64, 1100), next);
    const s2 = try Snapshot.read(graphics);
    try testing.expectEqualSlices(u8, &red, &s2.pixel);
    try testing.expect(s2.gen > s1.gen);

    // After a stop command (a=a,s=1) the tick reports nothing to
    // play and leaves next_ms and the image alone.
    const stop = "\x1b_Ga=a,i=1,s=1\x1b\\";
    terminal_c.vt_write(t, stop.ptr, stop.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    next = 42;
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 1100, &next));
    try testing.expectEqual(@as(u64, 42), next);
    try testing.expectEqual(s2, try Snapshot.read(graphics));
}

test "animation_tick without animations returns no value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    var next: u64 = 0;

    // Empty storage.
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 0, &next));

    // A placed static image.
    const transmit = "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\";
    terminal_c.vt_write(t, transmit.ptr, transmit.len);
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 0, &next));
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 1000, &next));
}

test "animation_tick null out returns invalid_value" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    try testing.expectEqual(Result.invalid_value, animation_tick(graphics, 0, null));
}

test "frame calls read, refuse and complete the frames of a two-frame upload" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    // The third frame comes from a shared memory object this terminal
    // cannot read, so it is pending.
    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "/kido-missing-{d}", .{std.c.getpid()});
    var encoded_name: [64]u8 = undefined;
    const name_b64 = std.base64.standard.Encoder.encode(&encoded_name, name);
    var cmds: [512]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &cmds,
        "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\" ++
            "\x1b_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\x1b\\" ++
            "\x1b_Ga=f,i=1,t=s,f=32,s=1,v=1,z=20;{s}\x1b\\",
        .{name_b64},
    );
    terminal_c.vt_write(t, input.ptr, input.len);

    var graphics: KittyGraphics = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_graphics, @ptrCast(&graphics)));
    const img = image_get_handle(graphics, 1);
    var count: u32 = 0;
    try testing.expectEqual(Result.success, image_get(img, .frame_count, @ptrCast(&count)));
    try testing.expectEqual(@as(u32, 3), count);
    var pending: bool = false;
    try testing.expectEqual(Result.success, image_get(img, .pending_frames, @ptrCast(&pending)));
    try testing.expect(pending);
    var state: AnimationState = undefined;
    try testing.expectEqual(Result.success, image_get(img, .animation_state, @ptrCast(&state)));
    try testing.expectEqual(AnimationState.stopped, state);

    // Frame 2: pixels, format and the serial of its command.
    var ptr: [*]const u8 = undefined;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .data_ptr, @ptrCast(&ptr)));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, ptr[0..4]);
    var format: ImageFormat = undefined;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .format, @ptrCast(&format)));
    try testing.expectEqual(ImageFormat.rgba, format);
    var serial2: u64 = 0;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .generation, @ptrCast(&serial2)));
    var gap: u32 = 0;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .gap_ms, @ptrCast(&gap)));
    try testing.expectEqual(@as(u32, 40), gap);

    // Frame 3 is pending: no pointer, its length, a newer serial.
    var serial3: u64 = 0;
    try testing.expectEqual(Result.no_value, frame_get(t, .primary, 1, 3, .data_ptr, @ptrCast(&ptr)));
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 3, .generation, @ptrCast(&serial3)));
    try testing.expect(serial3 > serial2);
    var len: usize = 0;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 3, .data_len, @ptrCast(&len)));
    try testing.expectEqual(@as(usize, 4), len);

    // multi
    const keys = [_]FrameData{ .data_len, .generation };
    var out_len: usize = 0;
    var out_gen: u64 = 0;
    var values = [_]?*anyopaque{ @ptrCast(&out_len), @ptrCast(&out_gen) };
    var written: usize = 0;
    try testing.expectEqual(Result.success, frame_get_multi(t, .primary, 1, 3, 2, &keys, &values, &written));
    try testing.expectEqual(@as(usize, 2), written);
    try testing.expectEqual(serial3, out_gen);

    // No such image, no such frame, frame 0, the other screen.
    try testing.expectEqual(Result.no_value, frame_get(t, .primary, 9, 1, .data_len, @ptrCast(&len)));
    try testing.expectEqual(Result.invalid_value, frame_get(t, .primary, 1, 4, .data_len, @ptrCast(&len)));
    try testing.expectEqual(Result.invalid_value, frame_get(t, .primary, 1, 0, .data_len, @ptrCast(&len)));
    try testing.expectEqual(Result.no_value, frame_get(t, .alternate, 1, 1, .data_len, @ptrCast(&len)));

    // The pending generation names the pending frame.
    var pending_generation: u64 = 0;
    try testing.expectEqual(Result.success, terminal_c.get(t, .kitty_pending_generation, @ptrCast(&pending_generation)));
    try testing.expect(pending_generation != 0);

    // The animation does not play while a frame is pending.
    const run = "\x1b_Ga=a,i=1,s=3\x1b\\";
    terminal_c.vt_write(t, run.ptr, run.len);
    var next: u64 = 0;
    try testing.expectEqual(Result.no_value, animation_tick(graphics, 1000, &next));

    // Attach: a serial that moved on, a wrong length, a frame that is not
    // pending, and then the right one.
    const pixels = [_]u8{ 1, 2, 3, 255 };
    try testing.expectEqual(Result.no_value, frame_attach(t, .primary, 1, 3, serial3 - 1, &pixels, 4));
    try testing.expectEqual(Result.invalid_value, frame_attach(t, .primary, 1, 3, serial3, &pixels, 3));
    try testing.expectEqual(Result.invalid_value, frame_attach(t, .primary, 1, 3, serial3, null, 4));
    try testing.expectEqual(Result.no_value, frame_attach(t, .primary, 1, 2, serial2, &pixels, 4));
    try testing.expectEqual(Result.no_value, frame_attach(t, .primary, 1, 4, serial3, &pixels, 4));
    try testing.expectEqual(Result.invalid_value, frame_attach(t, .primary, 1, 0, serial3, &pixels, 4));
    try testing.expectEqual(Result.no_value, frame_get(t, .primary, 1, 3, .data_ptr, @ptrCast(&ptr)));
    const playback = graphics.images.getPtr(1).?.animation.?;
    playback.frame_shown_at_ms = 1;
    try testing.expectEqual(Result.success, frame_attach(t, .primary, 1, 3, serial3, &pixels, 4));
    try testing.expectEqual(@as(?u64, null), playback.frame_shown_at_ms);
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 3, .data_ptr, @ptrCast(&ptr)));
    try testing.expectEqualSlices(u8, &pixels, ptr[0..4]);
    try testing.expect(ptr != &pixels);
    var serial_after: u64 = 0;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 3, .generation, @ptrCast(&serial_after)));
    try testing.expectEqual(serial3, serial_after);
    try testing.expectEqual(Result.success, image_get(img, .pending_frames, @ptrCast(&pending)));
    try testing.expect(!pending);

    // The last frame arrived: playback resumes and the timer starts at the
    // first tick after it.
    try testing.expectEqual(Result.success, animation_tick(graphics, 5000, &next));
    try testing.expect(next >= 5000 and next <= 5040);
}

test "frame_adopt maps pixels without a copy and refuses what it cannot take" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    var name_buffer: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "/kido-missing-{d}", .{std.c.getpid()});
    var encoded_name: [64]u8 = undefined;
    const name_b64 = std.base64.standard.Encoder.encode(&encoded_name, name);
    var cmds: [512]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &cmds,
        "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\" ++
            "\x1b_Ga=f,i=1,t=s,f=32,s=1,v=1;{s}\x1b\\",
        .{name_b64},
    );
    terminal_c.vt_write(t, input.ptr, input.len);
    var serial: u64 = 0;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .generation, @ptrCast(&serial)));

    const page = std.heap.pageSize();
    const memory = try std.posix.mmap(null, page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    var owned = true;
    defer if (owned) std.posix.munmap(memory);
    @memcpy(memory[8..12], &[_]u8{ 9, 8, 7, 255 });

    // Refused: stale serial, unaligned base, a range past the mapping, a
    // wrong length. The caller still owns the mapping.
    try testing.expectEqual(Result.no_value, frame_adopt(t, .primary, 1, 2, serial + 1, memory.ptr, page, 8, 4));
    try testing.expectEqual(Result.invalid_value, frame_adopt(t, .primary, 1, 2, serial, memory.ptr + 1, page, 8, 4));
    try testing.expectEqual(Result.invalid_value, frame_adopt(t, .primary, 1, 2, serial, memory.ptr, page, page - 2, 4));
    try testing.expectEqual(Result.invalid_value, frame_adopt(t, .primary, 1, 2, serial, memory.ptr, page, 8, 5));
    try testing.expectEqual(Result.invalid_value, frame_adopt(t, .primary, 1, 2, serial, null, page, 8, 4));

    try testing.expectEqual(Result.success, frame_adopt(t, .primary, 1, 2, serial, memory.ptr, page, 8, 4));
    owned = false;
    var ptr: [*]const u8 = undefined;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .data_ptr, @ptrCast(&ptr)));
    try testing.expectEqual(memory.ptr + 8, @constCast(ptr));

    // An in-place edit copies the pixels first and releases the mapping.
    const edit = "\x1b_Ga=f,i=1,r=2,f=32,s=1,v=1;AAAAAA==\x1b\\";
    terminal_c.vt_write(t, edit.ptr, edit.len);
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .data_ptr, @ptrCast(&ptr)));
    try testing.expect(memory.ptr + 8 != @constCast(ptr));
}

test "screen_image reads an image of the screen that is not active" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    const input = "\x1b_Ga=T,f=32,i=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\" ++
        "\x1b_Ga=f,f=32,i=1,s=1,v=1,z=40;AAD//w==\x1b\\" ++
        "\x1b[?1049h";
    terminal_c.vt_write(t, input.ptr, input.len);

    const primary = screen_image(t, .primary, 1);
    try testing.expect(primary != null);
    var count: u32 = 0;
    try testing.expectEqual(Result.success, image_get(primary, .frame_count, @ptrCast(&count)));
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expect(screen_image(t, .alternate, 1) == null);
    try testing.expect(screen_image(t, .primary, 2) == null);
    try testing.expect(screen_image(null, .primary, 1) == null);

    var len: usize = 0;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .data_len, @ptrCast(&len)));
    try testing.expectEqual(Result.no_value, frame_get(t, .alternate, 1, 1, .data_len, @ptrCast(&len)));
}

test "frame_attach refuses generation 0" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(&lib.alloc.test_allocator, &t, 80, 24));
    defer terminal_c.free(t);

    // A frame that restore input made pending has no serial.
    const zt = terminal_c.zigTerminal(t).?;
    var stream = zt.vtStream();
    defer stream.deinit();
    stream.handler.restoring = true;
    stream.nextSlice("\x1b_Ga=t,f=32,i=1,s=1,v=1;/wAA/w==\x1b\\\x1b_Ga=f,i=1,f=32,s=1,v=1,t=s;L2tpZG8tbWlzc2luZw==\x1b\\");
    var serial: u64 = 99;
    try testing.expectEqual(Result.success, frame_get(t, .primary, 1, 2, .generation, @ptrCast(&serial)));
    try testing.expectEqual(@as(u64, 0), serial);
    const pixels = [_]u8{ 1, 2, 3, 255 };
    try testing.expectEqual(Result.no_value, frame_attach(t, .primary, 1, 2, 0, &pixels, 4));
}
