//! Stores groups of CSS declared values (a.k.a. declaration blocks).

// TODO: move to `property` module
const Declarations = @This();

const zss = @import("zss.zig");
const aggregates = zss.property.aggregates;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

headers: Headers = .{},
meta: std.ArrayListUnmanaged(Meta) = .empty,
arena: ArenaAllocator.State = .{},
next_block_id: std.meta.Tag(BlockId) = 0,

pub const BlockId = enum(u32) { _ };

const Headers = blk: {
    const ns = struct {
        fn fieldMap(comptime aggregate_tag: aggregates.Tag) struct { type, ?*const anyopaque } {
            const T = std.AutoHashMapUnmanaged(BlockId, Header(aggregate_tag));
            return .{ T, &T.empty };
        }
    };
    break :blk zss.meta.EnumFieldMapStruct(aggregates.Tag, ns.fieldMap);
};

const Meta = struct {
    has_normal_values: bool = false,
    has_important_values: bool = false,
    all: ?All = null,

    const All = struct {
        keyword: zss.values.types.CssWideKeyword,
        important: bool,
    };
};

pub fn deinit(decls: *Declarations, allocator: Allocator) void {
    var arena = decls.arena.promote(allocator);
    defer decls.arena = arena.state;
    arena.deinit();

    decls.meta.deinit(allocator);
    inline for (std.meta.fields(Headers)) |field| {
        @field(decls.headers, field.name).deinit(allocator);
    }
}

pub fn newBlock(decls: *Declarations, allocator: Allocator) !BlockId {
    if (decls.next_block_id == std.math.maxInt(std.meta.Tag(BlockId))) return error.OutOfDeclBlockIds;
    try decls.meta.append(allocator, .{});
    defer decls.next_block_id += 1;
    return @enumFromInt(decls.next_block_id);
}

pub const ValueTag = enum {
    undeclared,
    initial,
    inherit,
    unset,
    declared,
};

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub fn SingleValue(comptime T: type) type {
    return union(ValueTag) {
        undeclared,
        initial,
        inherit,
        unset,
        declared: T,
    };
}

/// Represents either a CSS value, or a CSS-wide keyword, or `undeclared` (the absence of a declared value)
pub fn MultiValue(comptime T: type) type {
    return union(ValueTag) {
        undeclared,
        initial,
        inherit,
        unset,
        declared: []const T,
    };
}

/// `values` must be a struct such that each field is named after an aggregate.
/// Each field of `values` must also be a struct, such that each field:
///     is named after an aggregate member, and
///     has a type of either `SingleValue` or `MultiValue` (depending on the aggregate)
pub fn addValues(decls: *Declarations, allocator: Allocator, block: BlockId, important: bool, values: anytype) !void {
    if (@sizeOf(@TypeOf(values)) == 0) return;

    const meta = &decls.meta.items[@intFromEnum(block)];
    // TODO: The 'all' property does not affect some properties
    if (meta.all != null) return;
    if (important) meta.has_important_values = true else meta.has_normal_values = true;

    var arena = decls.arena.promote(allocator);
    defer decls.arena = arena.state;

    inline for (@typeInfo(@TypeOf(values)).@"struct".fields) |aggregate_field| {
        const aggregate_tag = comptime std.enums.nameCast(aggregates.Tag, aggregate_field.name);
        const size = comptime aggregate_tag.size() orelse
            @compileError(std.fmt.comptimePrint("TODO: aggregate '{s}' not yet implemented", .{@tagName(aggregate_tag)}));

        const Aggregate = aggregate_tag.Value();
        const header = try decls.getHeader(aggregate_tag, allocator, block);
        inline for (@typeInfo(aggregate_field.type).@"struct".fields) |value_field| {
            // TODO: If a value of equal or higher importance already exists, then do not add this value.

            const field = comptime std.enums.nameCast(std.meta.FieldEnum(Aggregate), value_field.name);
            const value = @field(@field(values, aggregate_field.name), value_field.name);
            switch (size) {
                .single => header.set(field, important, value),
                .multi => try header.set(field, important, value, &arena),
            }
        }
    }
}

pub fn addAll(decls: *Declarations, block: BlockId, important: bool, value: zss.values.types.CssWideKeyword) void {
    // NOTE: We only store the most important value for 'all'.
    //       This means that if a non-important 'all' value is followed by an important one,
    //       the non-important one is essentially lost.
    //       Unsure if this is problematic or not, because as long as values are applied in the correct order
    //       (important, then non-important), it shouldn't make a difference.

    const meta = &decls.meta.items[@intFromEnum(block)];
    if (meta.all == null or
        @intFromBool(important) > @intFromBool(meta.all.?.important))
    {
        meta.all = .{ .keyword = value, .important = important };
    }
}

fn getHeader(decls: *Declarations, comptime aggregate_tag: aggregates.Tag, allocator: Allocator, block: BlockId) !*Header(aggregate_tag) {
    const gop_result = try @field(decls.headers, @tagName(aggregate_tag)).getOrPut(allocator, block);
    if (!gop_result.found_existing) gop_result.value_ptr.* = .{};
    return gop_result.value_ptr;
}

pub fn AllAggregateValues(comptime aggregate_tag: aggregates.Tag) type {
    const Aggregate = aggregate_tag.Value();
    const FieldEnum = std.meta.FieldEnum(Aggregate);
    const size = aggregate_tag.size() orelse return void;
    const ns = struct {
        fn fieldMap(comptime field: FieldEnum) struct { type, ?*const anyopaque } {
            const Field = @FieldType(Aggregate, @tagName(field));
            const Type = switch (size) {
                .single => SingleValue(Field),
                .multi => MultiValue(Field),
            };
            const default: *const Type = &.undeclared;
            return .{ Type, default };
        }
    };
    return zss.meta.EnumFieldMapStruct(FieldEnum, ns.fieldMap);
}

/// For each aggregate field, applies from the value within `block` to the value within `dest`.
///
/// To "apply a value from src to dest" means the following:
/// If dest is `.undeclared`, then copy src to dest. Otherwise, do nothing.

// TODO: Rewrite these docs in terms of "partially cascaded values"
pub fn apply(
    decls: *const Declarations,
    comptime aggregate_tag: aggregates.Tag,
    block: BlockId,
    important: bool,
    dest: *AllAggregateValues(aggregate_tag),
) void {
    const meta = decls.meta.items[@intFromEnum(block)];
    const default_value: ValueTag = if (meta.all != null and meta.all.?.important == important)
        switch (meta.all.?.keyword) {
            .initial => .initial,
            .inherit => .inherit,
            .unset => .unset,
        }
    else
        .undeclared;

    blk: {
        const has_values = if (important) meta.has_important_values else meta.has_normal_values;
        if (!has_values) break :blk;
        const header = @field(decls.headers, @tagName(aggregate_tag)).get(block) orelse break :blk;
        header.apply(important, dest, default_value);
        return;
    }

    if (default_value == .undeclared) return;
    inline for (std.meta.fields(aggregate_tag.Value())) |field| {
        const dest_field = &@field(dest, field.name);
        if (dest_field.* == .undeclared) {
            dest_field.* = zss.meta.unionTagToVoidPayload(@TypeOf(dest_field.*), default_value);
        }
    }
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
            const tag_values = @typeInfo(ValueTag).@"enum".fields[0..kw_values.len];
            for (kw_values, tag_values) |kw, tag| assert(kw.value == tag.value);
        }

        fn fromTag(tag: ValueTag) Keyword {
            return @enumFromInt(@intFromEnum(tag));
        }
    };

    /// Represents the absence of a declared value.
    const undeclared = ValueCount{ .keyword = .none, .num = 0 };

    fn fromInt(num: u6) ValueCount {
        assert(num > 0);
        return .{ .keyword = .none, .num = num };
    }

    fn fromTag(tag: ValueTag) ValueCount {
        return .{ .keyword = Keyword.fromTag(tag), .num = 0 };
    }
};

pub const max_list_len = std.math.maxInt(@FieldType(ValueCount, "num"));

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

        fn get(header: *const @This(), comptime field: FieldEnum, important: bool) SingleValue(@FieldType(Aggregate, @tagName(field))) {
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

        fn set(header: *@This(), comptime field: FieldEnum, important: bool, value: SingleValue(@FieldType(Aggregate, @tagName(field)))) void {
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

        fn apply(header: *const @This(), important: bool, dest: *AllAggregateValues(aggregate_tag), default_value: ValueTag) void {
            const counts, const values = if (important) .{ &header.important_counts, &header.important } else .{ &header.normal_counts, &header.normal };
            inline for (comptime std.enums.values(FieldEnum)) |field| {
                const dest_field = &@field(dest, @tagName(field));
                if (dest_field.* == .undeclared) {
                    const Field = @FieldType(Aggregate, @tagName(field));
                    const count = @field(counts, @tagName(field));
                    dest_field.* = switch (count.keyword) {
                        .none => if (count.num == 0)
                            zss.meta.unionTagToVoidPayload(SingleValue(Field), default_value)
                        else blk: {
                            assert(count.num == 1);
                            break :blk .{ .declared = @field(values, @tagName(field)) };
                        },
                        .initial => .initial,
                        .inherit => .inherit,
                        .unset => .unset,
                    };
                }
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

        fn get(header: *const @This(), comptime field: FieldEnum, important: bool) MultiValue(@FieldType(Aggregate, @tagName(field))) {
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
            const Field = @FieldType(Aggregate, @tagName(field));
            const bytes: []align(max_alignment) const u8 = @alignCast(header.data.items[field_range_start..][0 .. @sizeOf(Field) * count.num]);
            return .{ .declared = std.mem.bytesAsSlice(Field, bytes) };
        }

        fn set(
            header: *@This(),
            comptime field: FieldEnum,
            important: bool,
            noalias value: MultiValue(@FieldType(Aggregate, @tagName(field))), // TODO: This can't alias header.data.items
            arena: *ArenaAllocator,
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
                    const range = try header.data.addManyAt(arena.allocator(), field_range_start, field_range_len);
                    @memcpy(range.ptr, std.mem.sliceAsBytes(slice));
                },
                .initial, .inherit, .unset, .undeclared => count.* = .fromTag(value),
            }
        }

        fn apply(header: *const @This(), important: bool, dest: *AllAggregateValues(aggregate_tag), default_value: ValueTag) void {
            const counts = if (important) header.important_tags else header.normal_tags;
            var current_index = fieldRangeStart(header, @enumFromInt(0), important);
            inline for (comptime std.enums.values(FieldEnum)) |field| {
                const Field = @FieldType(Aggregate, @tagName(field));
                const count = counts[@intFromEnum(field)];
                const end_index = current_index + @sizeOf(Field) * count.num;
                defer current_index = std.mem.alignForward(usize, end_index, max_alignment);

                const dest_field = &@field(dest, @tagName(field));
                if (dest_field.* == .undeclared) {
                    dest_field.* = switch (count.keyword) {
                        .none => if (count.num == 0)
                            zss.meta.unionTagToVoidPayload(MultiValue(Field), default_value)
                        else blk: {
                            const bytes: []align(max_alignment) const u8 = @alignCast(header.data.items[current_index..end_index]);
                            break :blk .{ .declared = std.mem.bytesAsSlice(Field, bytes) };
                        },
                        .initial => .initial,
                        .inherit => .inherit,
                        .unset => .unset,
                    };
                }
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

    const types = zss.values.types;
    const block = try decls.newBlock(allocator);

    try decls.addValues(allocator, block, false, .{
        .box_style = .{
            .display = SingleValue(types.Display){ .declared = .block },
            .position = SingleValue(types.Position){ .declared = .relative },
        },
    });

    const clip_values = &[_]types.BackgroundClip{ .border_box, .padding_box };
    try decls.addValues(allocator, block, false, .{
        .background_clip = .{
            .clip = MultiValue(types.BackgroundClip){ .declared = clip_values },
        },
    });
    try decls.addValues(allocator, block, true, .{
        .background_clip = .{
            .clip = MultiValue(types.BackgroundClip).initial,
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
        .declared => |slice| try std.testing.expectEqualSlices(types.BackgroundClip, clip_values, slice),
        else => return error.TestFailure,
    }
    switch (background_clip.get(.clip, true)) {
        .initial => {},
        else => return error.TestFailure,
    }
}
