//! An append-only list data structure that holds a UTF-8 encoded string.
//! The string is broken into segments, with each new segment being double the size of the previous one.
//! The segments, once allocated, are never moved in memory.
//! Care is taken such that a single codepoint is never split between two different segments.
//!
//! Like std.SegmentedList but way better.

segments: [*]Segment,
/// The position of the next place to append codepoints.
position: Position,
first_segment_len_log2: SegmentIndex,
/// The maximum length of the `segments` array.
max_segments_len: SegmentsLen,
debug: Debug,

/// To ensure that codepoints are not split between two different segments, the last 1-3 bytes of a segment may not get used.
/// For example, if a segment only has 3 bytes left, and you try to append a codepoint that takes up 4 bytes, it will instead create a new segment. Those last 3 bytes become unusable.
/// Segments are allocated with an alignment of 4, so that the last 2 bits of the pointer address can be used to store the number of unusable bytes.
/// Segments cannot be completely empty; they must always have a non-zero amount of either used or unusable bytes.
const Segment = struct {
    int: usize,

    const mask: usize = 0b11;

    fn unusableLen(segment: Segment) u2 {
        return @intCast(segment.int & mask);
    }

    fn setUnusableLen(segment: *Segment, len: u2) void {
        segment.int |= len;
    }

    fn ptr(segment: Segment) [*]align(4) u8 {
        return @ptrFromInt(segment.int & ~mask);
    }
};

/// Imagine concatenating all of the segments within the string, from smallest to largest, including their unusable bytes.
/// This type acts as an index into that large byte array.
pub const Position = usize;

const SegmentIndex = std.math.Log2Int(usize);
const SegmentsLen = std.math.Log2IntCeil(usize);

// TODO: Possible improvements:
// - Statically allocate the segment array
// - Choose a smaller integer index type
const SegmentedUtf8String = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The theoretical maximum length in bytes of this string is `2 * last_segment_len - first_segment_len`.
pub fn init(
    /// The length in bytes of the very first segment to be allocated. Must be a power of 2.
    first_segment_len: usize,
    /// The length in bytes of the very last segment to be allocated. Must be a power of 2. Must be greater than or equal to `first_segment_len`.
    last_segment_len: usize,
) SegmentedUtf8String {
    assert(std.math.isPowerOfTwo(first_segment_len));
    assert(std.math.isPowerOfTwo(last_segment_len));
    const first_segment_len_log2 = std.math.log2_int(usize, first_segment_len);
    return .{
        .segments = undefined,
        .position = 0,
        .first_segment_len_log2 = first_segment_len_log2,
        .max_segments_len = @as(SegmentsLen, 1) + std.math.log2_int(usize, last_segment_len) - first_segment_len_log2,
        .debug = .{},
    };
}

pub fn deinit(string: *SegmentedUtf8String, allocator: Allocator) void {
    const segments = string.segments[0..string.numSegments()];
    for (segments, 0..) |segment, segment_index_usize| {
        const complete_len = string.segmentCompleteLen(@intCast(segment_index_usize));
        allocator.free(segment.ptr()[0..complete_len]);
    }
    allocator.free(segments);
}

/// The length of the array pointed to by `string.segments`.
fn numSegments(string: *const SegmentedUtf8String) SegmentsLen {
    const location = string.positionToLocation(string.position);
    return location.segment_index + @intFromBool(location.byte_offset != 0);
}

fn segmentCompleteLen(string: *const SegmentedUtf8String, segment_index: SegmentIndex) usize {
    return @as(usize, 1) << (string.first_segment_len_log2 + segment_index);
}

const Location = struct {
    segment_index: SegmentsLen,
    byte_offset: usize,
};

fn locationToPositon(string: *const SegmentedUtf8String, location: Location) usize {
    const complete_len = string.segmentCompleteLen(@intCast(location.segment_index));
    return complete_len - (@as(usize, 1) << string.first_segment_len_log2) + location.byte_offset;
}

fn positionToLocation(string: *const SegmentedUtf8String, index: usize) Location {
    const shifted = index + (@as(usize, 1) << string.first_segment_len_log2);
    const segment_index_shifted = std.math.log2_int(usize, shifted);
    const byte_offset = shifted - (@as(usize, 1) << segment_index_shifted);
    return .{
        .segment_index = segment_index_shifted - string.first_segment_len_log2,
        .byte_offset = byte_offset,
    };
}

/// Returns a `Position` that refers to the start of the newly appended substring.
pub fn append(string: *SegmentedUtf8String, allocator: Allocator, items: []const u8) !Position {
    const initial_position = string.position;
    var remaining_items = items;
    while (remaining_items.len > 0) {
        const location = string.positionToLocation(string.position);
        if (location.segment_index == string.max_segments_len) return error.OutOfSegments;

        const complete_len = string.segmentCompleteLen(@intCast(location.segment_index));
        if (location.byte_offset == 0) {
            // `string.position` is the position where new codepoints are appended.
            // Therefore, if `location.byte_offset == 0`, then `location` points to past the the end of the current segment.
            // In that case, a new segment needs to be allocated in order to append codepoints.

            const segment = try allocator.alignedAlloc(u8, 4, complete_len);
            errdefer allocator.free(segment);

            const old_segments = string.segments[0..location.segment_index];
            const new_segments = try allocator.realloc(old_segments, location.segment_index + 1);
            new_segments[location.segment_index] = .{ .int = @intFromPtr(segment.ptr) };
            string.segments = new_segments.ptr;
        }

        const segment = &string.segments[location.segment_index];
        assert(segment.unusableLen() == 0);
        const usable_len = complete_len - location.byte_offset;

        const copyable_len = copyable_len: {
            if (remaining_items.len <= usable_len) {
                string.position += remaining_items.len;
                break :copyable_len remaining_items.len;
            } else {
                string.position += usable_len;

                // Backtrack to find the start byte of the most recent codepoint within `remaining_items`.
                for (0..@min(3, usable_len)) |i| {
                    const index = usable_len - 1 - i;
                    const byte = remaining_items[index];
                    if (!isUtf8CodepointStartByte(byte)) continue;

                    const codepoint_len = std.unicode.utf8ByteSequenceLength(byte) catch unreachable;
                    const copyable_len = if (codepoint_len > usable_len - index) index else usable_len;
                    segment.setUnusableLen(@intCast(usable_len - copyable_len));
                    break :copyable_len copyable_len;
                } else unreachable; // Invalid UTF-8
            }
        };

        @memcpy(segment.ptr() + location.byte_offset, remaining_items[0..copyable_len]);
        remaining_items = remaining_items[copyable_len..];
    }

    return initial_position;
}

fn isUtf8CodepointStartByte(byte: u8) bool {
    return byte & 0b11000000 != 0b10000000;
}

pub const Iterator = struct {
    string: *const SegmentedUtf8String,
    remaining: usize,
    location: Location,

    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.remaining == 0) return null;

        const segment = it.string.segments[it.location.segment_index];
        const complete_len = it.string.segmentCompleteLen(@intCast(it.location.segment_index));
        const usable_len = complete_len - it.location.byte_offset - segment.unusableLen();
        const used_len = @min(it.remaining, usable_len);

        defer {
            it.remaining -= used_len;
            it.location.segment_index += 1;
            it.location.byte_offset = 0;
        }

        return segment.ptr()[it.location.byte_offset..][0..used_len];
    }
};

pub fn iterator(
    string: *const SegmentedUtf8String,
    position: Position,
    /// The length in bytes of the substring.
    len: usize,
) Iterator {
    return .{
        .string = string,
        .remaining = len,
        .location = string.positionToLocation(position),
    };
}

pub const Debug = struct {
    /// The length in bytes of the entire string.
    pub fn len(debug: *const Debug) usize {
        const string: *const SegmentedUtf8String = @alignCast(@fieldParentPtr("debug", debug));
        const num_segments = string.numSegments();
        if (num_segments == 0) return 0;

        var result: usize = 0;
        for (string.segments[0 .. string.numSegments() - 1], 0..) |segment, segment_index| {
            const complete_len = string.segmentCompleteLen(@intCast(segment_index));
            const usable_len = complete_len - segment.unusableLen();
            result += usable_len;
        }

        const end_location = string.positionToLocation(string.position);
        if (end_location.byte_offset != 0) {
            result += end_location.byte_offset;
        } else {
            const last_segment = string.segments[num_segments - 1];
            const complete_len = string.segmentCompleteLen(@intCast(num_segments - 1));
            const usable_len = complete_len - last_segment.unusableLen();
            result += usable_len;
        }

        return result;
    }

    pub fn print(debug: *const Debug, writer: std.io.AnyWriter) !void {
        const string: *const SegmentedUtf8String = @alignCast(@fieldParentPtr("debug", debug));
        const string_len = debug.len();
        try writer.print("{} segments, {} bytes\n", .{ string.numSegments(), string_len });

        var segment_index: SegmentsLen = 0;
        var it = string.iterator(0, string_len);
        while (it.next()) |segment| : (segment_index += 1) {
            try writer.print("Segment {} ({} bytes): \"{s}\"\n", .{ segment_index, segment.len, segment });
        }
    }
};

test init {
    _ = init(1, 1);
    _ = init(1, 16);
    _ = init(4, 16);
    _ = init(16, 16);
    _ = init(1, 1 << (@bitSizeOf(usize) - 1));
}

test append {
    const allocator = std.testing.allocator;

    {
        var string = SegmentedUtf8String.init(8, 8);
        defer string.deinit(allocator);
        _ = try string.append(allocator, "abcdefgh");
    }
    {
        var string = SegmentedUtf8String.init(4, 8);
        defer string.deinit(allocator);
        _ = try string.append(allocator, "abcdefghwxyz");
    }
    {
        var string = SegmentedUtf8String.init(8, 16);
        defer string.deinit(allocator);
        _ = try string.append(allocator, "あいうえお");
    }
    {
        var string = SegmentedUtf8String.init(1, 16);
        defer string.deinit(allocator);
        _ = try string.append(allocator, "日月火水木金土");
    }
    {
        var string = SegmentedUtf8String.init(1, 4);
        defer string.deinit(allocator);
        try std.testing.expectError(error.OutOfSegments, string.append(allocator, "1234567890"));
    }
}

test iterator {
    const allocator = std.testing.allocator;

    const ns = struct {
        fn compareIterator(it: *Iterator, expected: []const u8) !void {
            var remaining = expected;
            while (it.next()) |segment| {
                try std.testing.expectEqualStrings(remaining[0..segment.len], segment);
                remaining = remaining[segment.len..];
            }
            try std.testing.expectEqual(remaining.len, 0);
        }
    };

    {
        var string = SegmentedUtf8String.init(4, 8);
        defer string.deinit(allocator);
        const index = try string.append(allocator, "abcdefghwxyz");
        var it = string.iterator(index, 12);
        try ns.compareIterator(&it, "abcdefghwxyz");
    }
    {
        var string = SegmentedUtf8String.init(4, 16);
        defer string.deinit(allocator);
        const index = try string.append(allocator, "日月火水木金土");
        var it = string.iterator(index, 15);
        try ns.compareIterator(&it, "日月火水木");
    }
    {
        var string = SegmentedUtf8String.init(4, 8);
        defer string.deinit(allocator);
        _ = try string.append(allocator, "abcdef");
        const index = try string.append(allocator, "ghwxyz");
        var it = string.iterator(index, 6);
        try ns.compareIterator(&it, "ghwxyz");
    }
    {
        var string = SegmentedUtf8String.init(4, 16);
        defer string.deinit(allocator);
        const index1 = try string.append(allocator, "日月");
        const index2 = try string.append(allocator, "火水木");
        const index3 = try string.append(allocator, "金土");
        var it1 = string.iterator(index1, 6);
        var it2 = string.iterator(index2, 9);
        var it3 = string.iterator(index3, 6);
        try ns.compareIterator(&it1, "日月");
        try ns.compareIterator(&it2, "火水木");
        try ns.compareIterator(&it3, "金土");
    }
}
