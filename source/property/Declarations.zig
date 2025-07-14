//! Stores groups of CSS declared values (a.k.a. declaration blocks).

const Declarations = @This();

const zss = @import("../zss.zig");
const aggregates = zss.property.aggregates;
const Important = zss.property.Important;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

headers: Headers = .{},
meta: std.ArrayListUnmanaged(Meta) = .empty,
arena: ArenaAllocator.State = .{},
current_block: Block.Tag = 0,
debug: Debug = .{},

pub const Block = enum(u32) {
    _,

    pub const Tag = std.meta.Tag(@This());

    pub fn earlierThan(lhs: Block, rhs: Block) bool {
        return @intFromEnum(lhs) < @intFromEnum(rhs);
    }
};

const Headers = blk: {
    const ns = struct {
        fn fieldMap(comptime aggregate_tag: aggregates.Tag) struct { type, ?*const anyopaque } {
            const T = std.AutoHashMapUnmanaged(Block.Tag, Header(aggregate_tag));
            return .{ T, &T.empty };
        }
    };
    break :blk zss.meta.EnumFieldMapStruct(aggregates.Tag, ns.fieldMap);
};

pub const Meta = struct {
    active_aggregates_normal: Set = .{},
    active_aggregates_important: Set = .{},
    all: ?All = null,

    pub const Set = std.EnumSet(aggregates.Tag);

    pub const All = struct {
        keyword: zss.values.types.CssWideKeyword,
        important: Important,
    };

    pub fn getAll(meta: *const Meta, important: Important) ?zss.values.types.CssWideKeyword {
        if (meta.all) |all| {
            if (all.important == important) {
                return all.keyword;
            }
        }
        return null;
    }

    /// Iterates over every aggregate tag that has declared values.
    pub fn tagIterator(meta: *const Meta, important: Important) Set.Iterator {
        switch (important) {
            .important => return meta.active_aggregates_important.iterator(),
            .normal => return meta.active_aggregates_normal.iterator(),
        }
    }

    fn defaultValue(meta: *const Meta, important: Important) ValueTag {
        if (meta.getAll(important)) |all| {
            return zss.meta.coerceEnum(ValueTag, all);
        } else {
            return .undeclared;
        }
    }
};

const Debug = switch (zss.debug.runtime_safety) {
    true => struct {
        is_block_opened: bool = false,

        fn openBlock(debug: *Debug) void {
            assert(!debug.is_block_opened);
            debug.is_block_opened = true;
        }

        fn closeBlock(debug: *Debug) void {
            assert(debug.is_block_opened);
            debug.is_block_opened = false;
        }

        fn assertBlockOpened(debug: Debug) void {
            assert(debug.is_block_opened);
        }
    },
    false => struct {
        fn openBlock(_: *Debug) void {}

        fn closeBlock(_: *Debug) void {}

        fn assertBlockOpened(_: Debug) void {}
    },
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

pub fn openBlock(decls: *Declarations, allocator: Allocator) !Block {
    decls.debug.openBlock();
    if (decls.current_block == std.math.maxInt(std.meta.Tag(Block))) return error.OutOfDeclBlockIds;
    try decls.meta.append(allocator, .{});
    return @enumFromInt(decls.current_block);
}

pub fn closeBlock(decls: *Declarations) void {
    decls.debug.closeBlock();
    decls.current_block += 1;
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

        pub fn expectEqual(expected: @This(), actual: @This()) !void {
            try std.testing.expectEqual(@as(ValueTag, expected), @as(ValueTag, actual));
            switch (expected) {
                .declared => |expected_value| try std.testing.expectEqual(expected_value, actual.declared),
                else => {},
            }
        }
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

        pub fn expectEqual(expected: @This(), actual: @This()) !void {
            try std.testing.expectEqual(@as(ValueTag, expected), @as(ValueTag, actual));
            switch (expected) {
                .declared => |expected_value| try std.testing.expectEqualSlices(T, expected_value, actual.declared),
                else => {},
            }
        }
    };
}

/// `values` must be a struct such that each field is named after an aggregate.
/// Each field of `values` must also be a struct, such that each field:
///     is named after an aggregate member, and
///     has a type of either `SingleValue` or `MultiValue` (depending on the aggregate)
pub fn addValues(decls: *Declarations, allocator: Allocator, important: Important, values: anytype) !void {
    decls.debug.assertBlockOpened();

    const aggregate_fields = @typeInfo(@TypeOf(values)).@"struct".fields;
    if (aggregate_fields.len == 0) return;

    const meta = &decls.meta.items[decls.current_block];
    // TODO: The 'all' property does not affect some properties
    if (meta.all != null) return;

    var arena = decls.arena.promote(allocator);
    defer decls.arena = arena.state;

    inline for (aggregate_fields) |aggregate_field| {
        const value_fields = @typeInfo(aggregate_field.type).@"struct".fields;
        if (value_fields.len == 0) continue;

        const aggregate_tag = comptime std.enums.nameCast(aggregates.Tag, aggregate_field.name);
        const Aggregate = aggregate_tag.Value();
        const size = comptime aggregate_tag.size();

        const header = try decls.getHeader(aggregate_tag, allocator, decls.current_block);
        const set = switch (important) {
            .important => &meta.active_aggregates_important,
            .normal => &meta.active_aggregates_normal,
        };
        set.insert(aggregate_tag);
        inline for (value_fields) |value_field| {
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

pub fn addAll(decls: *Declarations, important: Important, value: zss.values.types.CssWideKeyword) void {
    // NOTE: We only store the most important value for 'all'.
    //       This means that if a non-important 'all' value is followed by an important one,
    //       the non-important one is essentially lost.
    //       Unsure if this is problematic or not, because as long as values are applied in the correct order
    //       (important, then non-important), it shouldn't make a difference.

    decls.debug.assertBlockOpened();
    const meta = &decls.meta.items[decls.current_block];
    if (meta.all == null or
        @intFromEnum(important) > @intFromEnum(meta.all.?.important))
    {
        meta.all = .{ .keyword = value, .important = important };
    }
}

fn getHeader(decls: *Declarations, comptime aggregate_tag: aggregates.Tag, allocator: Allocator, block: Block.Tag) !*Header(aggregate_tag) {
    const gop_result = try @field(decls.headers, @tagName(aggregate_tag)).getOrPut(allocator, block);
    if (!gop_result.found_existing) gop_result.value_ptr.* = .{};
    return gop_result.value_ptr;
}

/// Returns `true` if `block` has any declared values with importance `important`.
pub fn hasValues(decls: *const Declarations, block: Block, important: Important) bool {
    const meta = decls.meta.items[@intFromEnum(block)];
    const set = switch (important) {
        .important => meta.active_aggregates_important,
        .normal => meta.active_aggregates_normal,
    };
    return (set.count() != 0) or (meta.all != null and meta.all.?.important == important);
}

pub fn AllAggregateValues(comptime aggregate_tag: aggregates.Tag) type {
    const Aggregate = aggregate_tag.Value();
    const FieldEnum = std.meta.FieldEnum(Aggregate);
    const size = aggregate_tag.size();
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

pub fn getMeta(decls: *const Declarations, block: Block) *const Meta {
    return &decls.meta.items[@intFromEnum(block)];
}

// TODO: These non-mutating APIs have some flaws:
//       1. Too much of it is public
//       2. Requires passing pointers to metadata (`getMeta` should not exist)
//       Solution: Move code from users of this API into this file.
//                 Keep a local copy of `meta` for the current block.

/// For each aggregate field, applies from the value within `block` to the value within `dest`.
///
/// To "apply a value from src to dest" means the following:
/// If dest is `.undeclared`, then copy src to dest. Otherwise, do nothing.

// TODO: Rewrite these docs in terms of "partially cascaded values"
pub fn apply(
    decls: *const Declarations,
    comptime aggregate_tag: aggregates.Tag,
    block: Block,
    important: Important,
    meta: *const Meta,
    dest: *AllAggregateValues(aggregate_tag),
) void {
    assert(meta == &decls.meta.items[@intFromEnum(block)]);
    const default_value = meta.defaultValue(important);

    if (@field(decls.headers, @tagName(aggregate_tag)).get(@intFromEnum(block))) |header| {
        return header.apply(important, dest, default_value);
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
    switch (aggregate_tag.size()) {
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

        fn set(header: *@This(), comptime field: FieldEnum, important: Important, value: SingleValue(@FieldType(Aggregate, @tagName(field)))) void {
            const counts, const values = switch (important) {
                .important => .{ &header.important_counts, &header.important },
                .normal => .{ &header.normal_counts, &header.normal },
            };
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

        fn apply(header: *const @This(), important: Important, dest: *AllAggregateValues(aggregate_tag), default_value: ValueTag) void {
            const counts, const values = switch (important) {
                .important => .{ header.important_counts, header.important },
                .normal => .{ header.normal_counts, header.normal },
            };
            inline for (comptime std.enums.values(FieldEnum)) |field| {
                const dest_field = &@field(dest, @tagName(field));
                if (dest_field.* == .undeclared) {
                    const Field = @FieldType(Aggregate, @tagName(field));
                    const count = @field(counts, @tagName(field));
                    dest_field.* = switch (count.keyword) {
                        .none => blk: {
                            if (count.num == 0) {
                                break :blk zss.meta.unionTagToVoidPayload(SingleValue(Field), default_value);
                            } else {
                                assert(count.num == 1);
                                break :blk .{ .declared = @field(values, @tagName(field)) };
                            }
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

        fn set(
            header: *@This(),
            comptime field: FieldEnum,
            important: Important,
            noalias value: MultiValue(@FieldType(Aggregate, @tagName(field))), // TODO: This can't alias header.data.items
            arena: *ArenaAllocator,
        ) !void {
            const counts = switch (important) {
                .important => &header.important_tags,
                .normal => &header.normal_tags,
            };
            const count = &counts[@intFromEnum(field)];
            if (count.* != ValueCount.undeclared) return;

            switch (value) {
                .declared => |slice| {
                    assert(slice.len > 0);
                    if (slice.len > max_list_len) return error.TooManyListItems;
                    count.* = .fromInt(@intCast(slice.len));

                    const Field = @FieldType(Aggregate, @tagName(field));
                    const field_range_start = fieldRangeStart(header, field, important);
                    const field_range_len = std.mem.alignForward(usize, field_range_start + @sizeOf(Field) * count.num, max_alignment);
                    const range = try header.data.addManyAt(arena.allocator(), field_range_start, field_range_len);
                    @memcpy(range.ptr, std.mem.sliceAsBytes(slice));
                },
                .initial, .inherit, .unset, .undeclared => count.* = .fromTag(value),
            }
        }

        fn apply(header: *const @This(), important: Important, dest: *AllAggregateValues(aggregate_tag), default_value: ValueTag) void {
            const counts = switch (important) {
                .important => header.important_tags,
                .normal => header.normal_tags,
            };
            var current_index = fieldRangeStart(header, @enumFromInt(0), important);
            inline for (comptime std.enums.values(FieldEnum)) |field| {
                const Field = @FieldType(Aggregate, @tagName(field));
                const count = counts[@intFromEnum(field)];
                const end_index = current_index + @sizeOf(Field) * count.num;
                defer current_index = std.mem.alignForward(usize, end_index, max_alignment);

                const dest_field = &@field(dest, @tagName(field));
                if (dest_field.* == .undeclared) {
                    dest_field.* = switch (count.keyword) {
                        .none => blk: {
                            if (count.num == 0) {
                                break :blk zss.meta.unionTagToVoidPayload(MultiValue(Field), default_value);
                            } else {
                                const bytes: []align(max_alignment) const u8 = @alignCast(header.data.items[current_index..end_index]);
                                break :blk .{ .declared = std.mem.bytesAsSlice(Field, bytes) };
                            }
                        },
                        .initial => .initial,
                        .inherit => .inherit,
                        .unset => .unset,
                    };
                }
            }
        }

        fn fieldRangeStart(header: *const @This(), field: FieldEnum, important: Important) usize {
            var current_index: usize = 0;
            for ([_]Important{ .normal, .important }) |current_importance| {
                const counts = switch (current_importance) {
                    .important => header.important_tags,
                    .normal => header.normal_tags,
                };
                for (std.enums.values(FieldEnum)) |current_field| {
                    const count = counts[@intFromEnum(current_field)];
                    if (current_importance == important and current_field == field) {
                        assert(current_index % max_alignment == 0);
                        return current_index;
                    } else {
                        const size: usize = switch (current_field) {
                            inline else => |comptime_field| @sizeOf(@FieldType(Aggregate, @tagName(comptime_field))),
                        };
                        current_index = std.mem.alignForward(usize, current_index + size * count.num, max_alignment);
                    }
                }
            }
            unreachable;
        }
    };
}

test "adding values" {
    const allocator = std.testing.allocator;
    var decls = Declarations{};
    defer decls.deinit(allocator);

    const types = zss.values.types;
    const block = try decls.openBlock(allocator);

    try decls.addValues(allocator, .normal, .{
        .box_style = .{
            .display = SingleValue(types.Display){ .declared = .block },
            .position = SingleValue(types.Position){ .declared = .relative },
        },
    });

    const clip_values = &[_]types.BackgroundClip{ .border_box, .padding_box };
    try decls.addValues(allocator, .normal, .{
        .background_clip = .{
            .clip = MultiValue(types.BackgroundClip){ .declared = clip_values },
        },
    });
    try decls.addValues(allocator, .important, .{
        .background_clip = .{
            .clip = MultiValue(types.BackgroundClip).initial,
        },
    });

    decls.closeBlock();

    const ns = struct {
        fn getValues(d: *const Declarations, comptime aggregate_tag: aggregates.Tag, b: Block, important: Important) AllAggregateValues(aggregate_tag) {
            const meta = d.getMeta(b);
            var values: AllAggregateValues(aggregate_tag) = .{};
            d.apply(aggregate_tag, b, important, meta, &values);
            return values;
        }
    };

    const box_style = ns.getValues(&decls, .box_style, block, .normal);
    switch (box_style.display) {
        .declared => |value| try std.testing.expect(value == .block),
        else => return error.TestFailure,
    }
    switch (box_style.position) {
        .declared => |value| try std.testing.expect(value == .relative),
        else => return error.TestFailure,
    }

    const background_clip_normal = ns.getValues(&decls, .background_clip, block, .normal);
    switch (background_clip_normal.clip) {
        .declared => |slice| try std.testing.expectEqualSlices(types.BackgroundClip, clip_values, slice),
        else => return error.TestFailure,
    }

    const background_clip_important = ns.getValues(&decls, .background_clip, block, .important);
    switch (background_clip_important.clip) {
        .initial => {},
        else => return error.TestFailure,
    }
}
