//! Whole records read from a source ahead of a `Decoder`, so that a call to
//! `Decoder.next` never waits on the source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const Decoder = @import("snapshot.zig").Decoder;

pub const ReadAhead = struct {
    alloc: Allocator,

    /// Where records come from. `fill` is the only reader of it.
    source: *std.Io.Reader,

    /// Point the decoder's `source` at this reader. Its address must stay
    /// stable while the decoder uses it.
    reader: std.Io.Reader = .fixed(&.{}),

    buf: std.ArrayList(u8) = .empty,

    /// The end in `buf` of each complete record that `Decoder` knows.
    known_ends: std.ArrayList(usize) = .empty,

    /// FINISH was read. Nothing after it belongs to the snapshot.
    finished: bool = false,

    pub const Error = Allocator.Error || std.Io.Reader.Error || record.Header.DecodeError || error{RecordTooLarge};

    pub fn init(alloc: Allocator, source: *std.Io.Reader) ReadAhead {
        return .{ .alloc = alloc, .source = source };
    }

    pub fn deinit(self: *ReadAhead) void {
        self.buf.deinit(self.alloc);
        self.known_ends.deinit(self.alloc);
    }

    /// Read records until the decoder can make its next `next` call from
    /// `reader` alone. Unknown records count for nothing: `next` skips any
    /// number of them, so they only ride along between the known ones.
    pub fn fill(self: *ReadAhead) Error!void {
        self.compact();
        while (!self.finished and self.ahead() < Decoder.known_records_per_next) try self.readRecord();
        const seek = self.reader.seek;
        self.reader = .fixed(self.buf.items);
        self.reader.seek = seek;
    }

    fn ahead(self: *const ReadAhead) usize {
        var count: usize = 0;
        for (self.known_ends.items) |end| count += @intFromBool(end > self.reader.seek);
        return count;
    }

    // Drop the consumed prefix once it is half of the buffer, so the copy
    // costs no more than the bytes consumed.
    fn compact(self: *ReadAhead) void {
        const seek = self.reader.seek;
        if (seek == 0 or seek < self.buf.items.len / 2) return;
        const rest = self.buf.items.len - seek;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[seek..]);
        self.buf.shrinkRetainingCapacity(rest);
        var kept: usize = 0;
        for (self.known_ends.items) |end| {
            if (end <= seek) continue;
            self.known_ends.items[kept] = end - seek;
            kept += 1;
        }
        self.known_ends.shrinkRetainingCapacity(kept);
        self.reader.seek = 0;
    }

    fn readRecord(self: *ReadAhead) Error!void {
        var raw: [record.Header.len]u8 = undefined;
        try self.source.readSliceAll(&raw);
        var fixed: std.Io.Reader = .fixed(&raw);
        const header = try record.Header.decode(&fixed);
        if (header.payload_len > record.max_payload_len) return error.RecordTooLarge;

        const at = self.buf.items.len;
        errdefer self.buf.shrinkRetainingCapacity(at);
        try self.buf.resize(self.alloc, at + raw.len + header.payload_len);
        @memcpy(self.buf.items[at..][0..raw.len], &raw);
        try self.source.readSliceAll(self.buf.items[at + raw.len ..]);
        if (header.tag.known()) try self.known_ends.append(self.alloc, self.buf.items.len);
        self.finished = header.tag == .finish;
    }
};
