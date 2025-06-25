//! Stores groups of CSS declared values (a.k.a. declaration blocks).

const Declarations = @This();

const zss = @import("zss.zig");
const aggregates = zss.property.aggregates;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

headers: Headers = .{},
arena: std.heap.ArenaAllocator.State = .{},
next_block_id: std.meta.Tag(BlockId) = 0,

const BlockId = enum(u32) { _ };

const Headers = blk: {
    const ns = struct {
        fn fieldMap(comptime aggregate_tag: aggregates.Tag) struct { type, ?*const anyopaque } {
            const T = std.AutoHashMapUnmanaged(BlockId, Header(aggregate_tag));
            return .{ T, &T.empty };
        }
    };
    break :blk zss.meta.EnumFieldMapStruct(aggregates.Tag, ns.fieldMap);
};

pub fn deinit(decls: *Declarations, allocator: Allocator) void {
    var arena = decls.arena.promote(allocator);
    defer decls.arena = arena.state;
    arena.deinit();

    inline for (std.meta.fields(Headers)) |field| {
        @field(decls.headers, field.name).deinit(allocator);
    }
}

pub fn newBlock(decls: *Declarations) !BlockId {
    if (decls.next_block_id == std.math.maxInt(std.meta.Tag(BlockId))) return error.OutOfDeclBlockIds;
    defer decls.next_block_id += 1;
    return @enumFromInt(decls.next_block_id);
}

pub fn addValues(decls: *Declarations, allocator: Allocator, block: BlockId, important: bool, values: anytype) !void {
    var arena_impl = decls.arena.promote(allocator);
    defer decls.arena = arena_impl.state;
    const arena = arena_impl.allocator();

    inline for (std.meta.fields(@TypeOf(values))) |aggregate_field| {
        const aggregate_tag = comptime std.enums.nameCast(aggregates.Tag, aggregate_field.name);
        const size = comptime aggregate_tag.size() orelse
            @compileError(std.fmt.comptimePrint("TODO: aggregate '{s}' not yet implemented", .{@tagName(aggregate_tag)}));

        const Aggregate = aggregate_tag.Value();
        const header = try decls.getHeader(aggregate_tag, allocator, block);
        inline for (std.meta.fields(aggregate_field.type)) |value_field| {
            const field = comptime std.enums.nameCast(std.meta.FieldEnum(Aggregate), value_field.name);
            const value = @field(@field(values, aggregate_field.name), value_field.name);
            switch (size) {
                .single => header.set(field, important, value),
                .multi => try header.set(field, important, value, arena),
            }
        }
    }
}

fn getHeader(decls: *Declarations, comptime aggregate_tag: aggregates.Tag, allocator: Allocator, block: BlockId) !*Header(aggregate_tag) {
    const gop_result = try @field(decls.headers, @tagName(aggregate_tag)).getOrPut(allocator, block);
    if (!gop_result.found_existing) gop_result.value_ptr.* = .{};
    return gop_result.value_ptr;
}

/// Represents a number of non-keyword CSS values.
/// If `num` is 0 (i.e. there are 0 non-keyword values), then this represents either
/// a CSS-wide keyword (`keyword != .none`), or
/// the absence of a declared value (`keyword == .none`).
const ValueCount = packed struct(u8) {
    keyword: Keyword,
    num: u6,

    const Keyword = enum(u2) {
        none,
        initial,
        inherit,
        unset,

        comptime {
            const kw_values = @typeInfo(Keyword).@"enum".fields;
            const tag_values = @typeInfo(ValueOrKeywordTag).@"enum".fields[0..kw_values.len];
            for (kw_values, tag_values) |kw, tag| assert(kw.value == tag.value);
        }

        fn fromTag(tag: ValueOrKeywordTag) Keyword {
            return @enumFromInt(@intFromEnum(tag));
        }
    };

    /// Represents the absence of a declared value.
    const undeclared = ValueCount{ .keyword = .none, .num = 0 };

    fn fromInt(num: u6) ValueCount {
        assert(num > 0);
        return .{ .keyword = .none, .num = num };
    }

    fn fromTag(tag: ValueOrKeywordTag) ValueCount {
        return .{ .keyword = Keyword.fromTag(tag), .num = 0 };
    }
};

pub const max_list_len = std.math.maxInt(@FieldType(ValueCount, "num"));

pub const ValueOrKeywordTag = enum {
    undeclared,
    initial,
    inherit,
    unset,
    declared,
};

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub fn SingleValueOrKeyword(comptime tag: aggregates.Tag, comptime field: std.meta.FieldEnum(tag.Value())) type {
    return union(ValueOrKeywordTag) {
        undeclared,
        initial,
        inherit,
        unset,
        declared: @FieldType(tag.Value(), @tagName(field)),
    };
}

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub fn MultiValueOrKeyword(comptime tag: aggregates.Tag, comptime field: std.meta.FieldEnum(tag.Value())) type {
    return union(ValueOrKeywordTag) {
        undeclared,
        initial,
        inherit,
        unset,
        declared: []const @FieldType(tag.Value(), @tagName(field)),
    };
}

fn Header(comptime aggregate_tag: aggregates.Tag) type {
    switch (aggregate_tag.size() orelse return void) {
        .single => return SingleValueHeader(aggregate_tag),
        .multi => return MultiValueHeader(aggregate_tag),
    }
}

fn SingleValueHeader(comptime aggregate_tag: aggregates.Tag) type {
    const Aggregate = aggregate_tag.Value();
    const FieldEnum = std.meta.FieldEnum(Aggregate);
    const Counts = std.enums.EnumFieldStruct(FieldEnum, ValueCount, .undeclared);

    return struct {
        normal: Aggregate = undefined,
        important: Aggregate = undefined,
        normal_counts: Counts = .{},
        important_counts: Counts = .{},

        fn get(header: *const @This(), comptime field: FieldEnum, important: bool) SingleValueOrKeyword(aggregate_tag, field) {
            const counts, const values = if (important) .{ header.important_counts, header.important } else .{ header.normal_counts, header.normal };
            const count = @field(counts, @tagName(field));
            if (count.num == 0) {
                return switch (count.keyword) {
                    .none => .undeclared,
                    .initial => .initial,
                    .inherit => .inherit,
                    .unset => .unset,
                };
            } else {
                assert(count.num == 1);
                return .{ .declared = @field(values, @tagName(field)) };
            }
        }

        fn set(header: *@This(), comptime field: FieldEnum, important: bool, value: SingleValueOrKeyword(aggregate_tag, field)) void {
            const counts, const values = if (important) .{ &header.important_counts, &header.important } else .{ &header.normal_counts, &header.normal };
            const count = &@field(counts, @tagName(field));
            if (count.* != ValueCount.undeclared) return;

            switch (value) {
                .declared => |val| {
                    count.* = .fromInt(1);
                    @field(values, @tagName(field)) = val;
                },
                .initial, .inherit, .unset, .undeclared => count.* = .fromTag(value),
            }
        }
    };
}

fn MultiValueHeader(comptime aggregate_tag: aggregates.Tag) type {
    const Aggregate = aggregate_tag.Value();
    const FieldEnum = std.meta.FieldEnum(Aggregate);
    const default_counts = std.enums.directEnumArrayDefault(FieldEnum, ValueCount, .undeclared, 0, .{});
    const Counts = @TypeOf(default_counts);

    const max_alignment = blk: {
        var result = 0;
        for (@typeInfo(Aggregate).@"struct".fields) |field| result = @max(result, field.alignment);
        break :blk result;
    };
    return struct {
        data: std.ArrayListAlignedUnmanaged(u8, max_alignment) = .empty,
        normal_tags: Counts = default_counts,
        important_tags: Counts = default_counts,

        fn get(header: *const @This(), comptime field: FieldEnum, important: bool) MultiValueOrKeyword(aggregate_tag, field) {
            const counts = if (important) header.important_tags else header.normal_tags;
            const count = counts[@intFromEnum(field)];
            if (count.num == 0) {
                return switch (count.keyword) {
                    .none => .undeclared,
                    .initial => .initial,
                    .inherit => .inherit,
                    .unset => .unset,
                };
            }

            const field_range_start = fieldRangeStart(header, field, important);
            const field_range_len = fieldRangeLen(field, count.num);
            const bytes: []align(max_alignment) const u8 = @alignCast(header.data.items[field_range_start..][0..field_range_len]);
            const Field = @FieldType(Aggregate, @tagName(field));
            return .{ .declared = std.mem.bytesAsSlice(Field, bytes) };
        }

        fn set(
            header: *@This(),
            comptime field: FieldEnum,
            important: bool,
            noalias value: MultiValueOrKeyword(aggregate_tag, field), // TODO: This can't alias header.data.items
            allocator: Allocator,
        ) !void {
            const counts = if (important) &header.important_tags else &header.normal_tags;
            const count = &counts[@intFromEnum(field)];
            if (count.* != ValueCount.undeclared) return;

            switch (value) {
                .declared => |slice| {
                    assert(slice.len > 0);
                    if (slice.len > max_list_len) return error.TooManyListItems;
                    count.* = .fromInt(@intCast(slice.len));

                    const field_range_start = fieldRangeStart(header, field, important);
                    const field_range_len = fieldRangeLen(field, @intCast(slice.len));
                    const range = try header.data.addManyAt(allocator, field_range_start, field_range_len);
                    @memcpy(range.ptr, std.mem.sliceAsBytes(slice));
                },
                .initial, .inherit, .unset, .undeclared => count.* = .fromTag(value),
            }
        }

        fn fieldRangeStart(header: *const @This(), field: FieldEnum, important: bool) usize {
            var current_index: usize = 0;
            for ([_]bool{ false, true }) |current_importance| {
                const counts = if (current_importance) header.important_tags else header.normal_tags;
                for (std.enums.values(FieldEnum)) |current_field| {
                    const count = counts[@intFromEnum(current_field)];
                    if (current_importance == important and current_field == field) {
                        assert(current_index % max_alignment == 0);
                        return current_index;
                    } else {
                        const field_range_len = fieldRangeLen(current_field, count.num);
                        current_index += field_range_len;
                    }
                }
            }
            unreachable;
        }

        fn fieldRangeLen(field: FieldEnum, count: u6) usize {
            const size: usize = switch (field) {
                inline else => |comptime_field| @sizeOf(@FieldType(Aggregate, @tagName(comptime_field))),
            };
            return std.mem.alignForward(usize, size * count, max_alignment);
        }
    };
}

test "adding values" {
    const allocator = std.testing.allocator;
    var decls = Declarations{};
    defer decls.deinit(allocator);

    const block = try decls.newBlock();

    try decls.addValues(allocator, block, false, .{
        .box_style = .{
            .display = SingleValueOrKeyword(.box_style, .display){ .declared = .block },
            .position = SingleValueOrKeyword(.box_style, .position){ .declared = .relative },
        },
    });

    const BackgroundClip = zss.values.types.BackgroundClip;
    const clip_values = &[_]BackgroundClip{ .border_box, .padding_box };
    try decls.addValues(allocator, block, false, .{
        .background_clip = .{
            .clip = MultiValueOrKeyword(.background_clip, .clip){ .declared = clip_values },
        },
    });
    try decls.addValues(allocator, block, true, .{
        .background_clip = .{
            .clip = MultiValueOrKeyword(.background_clip, .clip).initial,
        },
    });

    const box_style = decls.headers.box_style.get(block).?;
    switch (box_style.get(.display, false)) {
        .declared => |value| try std.testing.expect(value == .block),
        else => return error.TestFailure,
    }
    switch (box_style.get(.position, false)) {
        .declared => |value| try std.testing.expect(value == .relative),
        else => return error.TestFailure,
    }

    const background_clip = decls.headers.background_clip.get(block).?;
    switch (background_clip.get(.clip, false)) {
        .declared => |slice| try std.testing.expectEqualSlices(BackgroundClip, clip_values, slice),
        else => return error.TestFailure,
    }
    switch (background_clip.get(.clip, true)) {
        .initial => {},
        else => return error.TestFailure,
    }
}
