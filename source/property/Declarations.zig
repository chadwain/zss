//! Creates and manages declaration blocks. A declaration block stores declared values
//! from a list of CSS declarations. Create a new block with `openBlock`. Then, add
//! declarations to the currently open block using `addValues` and `addAll`. Finish by
//! calling `closeBlock`.
//!
//! When adding declarations from a list to a declaration block, it is important to
//! add them in the *reverse* order that they appear in the list. The reason for this
//! design is because in CSS, later declarations overwrite previous ones. By adding
//! declarations in reverse order, it allows us to simply discard declarations that
//! would have been overwritten anyway. The end result is that declaration blocks
//! store values don't actually store declared values, but instead values that are,
//! in a sense, between declared values and cascaded values. We refer to these values
//! as "partially cascaded values".
//!
//! Each CSS declaration can be either important (if it ends in "!important"), or
//! normal. Important declarations within a declaration block will always have a
//! higher cascade order than normal declarations within the same block. Conceptually,
//! this splits each declaration block into two: one that only stores important
//! declarations, and one that only stores normal ones. This is why there is an
//! `importance` parameter in every API that sets or retreives values.
//!
//! This struct manages its own memory. When declarations are added, a full copy of
//! all the required memory is made.

const Declarations = @This();

const zss = @import("../zss.zig");
const CssWideKeyword = zss.values.types.CssWideKeyword;
const Importance = zss.property.Importance;

const aggregates = zss.property.aggregates;
const DeclaredValueTag = aggregates.DeclaredValueTag;
const MultiValue = aggregates.MultiValue;
const SingleValue = aggregates.SingleValue;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

headers: Headers = .{},
meta: std.ArrayListUnmanaged(Meta) = .empty,
arena: ArenaAllocator.State = .{},
current: struct {
    block: Block.Tag = 0,
    meta: Meta = undefined,
} = .{},
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
    all_normal: ?CssWideKeyword = null,
    all_important: ?CssWideKeyword = null,

    pub const Set = std.EnumSet(aggregates.Tag);

    pub fn getAll(meta: *const Meta, importance: Importance) ?CssWideKeyword {
        return switch (importance) {
            .important => meta.all_important,
            .normal => meta.all_normal,
        };
    }

    /// Iterates over every aggregate tag that has declared values.
    pub fn tagIterator(meta: *const Meta, importance: Importance) Set.Iterator {
        switch (importance) {
            .important => return meta.active_aggregates_important.iterator(),
            .normal => return meta.active_aggregates_normal.iterator(),
        }
    }

    fn defaultValue(meta: *const Meta, importance: Importance) DeclaredValueTag {
        if (meta.getAll(importance)) |all| {
            return zss.meta.coerceEnum(DeclaredValueTag, all);
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
    if (decls.current.block == std.math.maxInt(std.meta.Tag(Block))) return error.OutOfDeclBlockIds;
    decls.current.meta = .{};
    try decls.meta.ensureUnusedCapacity(allocator, 1);
    return @enumFromInt(decls.current.block);
}

pub fn closeBlock(decls: *Declarations) void {
    decls.debug.closeBlock();
    decls.meta.appendAssumeCapacity(decls.current.meta);
    decls.current.block += 1;
    decls.current.meta = undefined;
}

/// `values` must be a struct such that each field is named after an aggregate.
/// Each field of `values` must also be a struct, such that each field:
///     is named after an aggregate member, and
///     has a type of either `SingleValue` or `MultiValue` (depending on the aggregate)
pub fn addValues(decls: *Declarations, allocator: Allocator, importance: Importance, values: anytype) !void {
    decls.debug.assertBlockOpened();

    const aggregate_fields = @typeInfo(@TypeOf(values)).@"struct".fields;
    if (aggregate_fields.len == 0) return;

    const meta = &decls.current.meta;
    // TODO: The 'all' property does not affect some properties
    const all = switch (importance) {
        .important => meta.all_important,
        .normal => meta.all_normal,
    };
    if (all != null) return;

    var arena = decls.arena.promote(allocator);
    defer decls.arena = arena.state;

    inline for (aggregate_fields) |aggregate_field| {
        const value_fields = @typeInfo(aggregate_field.type).@"struct".fields;
        if (value_fields.len == 0) continue;

        const aggregate_tag = comptime std.enums.nameCast(aggregates.Tag, aggregate_field.name);
        const size = comptime aggregate_tag.size();

        const header = try decls.getHeader(aggregate_tag, allocator, decls.current.block);
        const set = switch (importance) {
            .important => &meta.active_aggregates_important,
            .normal => &meta.active_aggregates_normal,
        };
        set.insert(aggregate_tag);
        inline for (value_fields) |value_field| {
            // TODO: If a value of equal or higher importance already exists, then do not add this value.

            const field = comptime std.enums.nameCast(aggregate_tag.FieldEnum(), value_field.name);
            const value = @field(@field(values, aggregate_field.name), value_field.name);
            switch (size) {
                .single => header.set(field, importance, value),
                .multi => try header.set(field, importance, value, &arena),
            }
        }
    }
}

pub fn addAll(decls: *Declarations, importance: Importance, value: CssWideKeyword) void {
    decls.debug.assertBlockOpened();
    const all = switch (importance) {
        .important => &decls.current.meta.all_important,
        .normal => &decls.current.meta.all_normal,
    };
    if (all.* == null) all.* = value;
}

fn getHeader(decls: *Declarations, comptime aggregate_tag: aggregates.Tag, allocator: Allocator, block: Block.Tag) !*Header(aggregate_tag) {
    const gop_result = try @field(decls.headers, @tagName(aggregate_tag)).getOrPut(allocator, block);
    if (!gop_result.found_existing) gop_result.value_ptr.* = .{};
    return gop_result.value_ptr;
}

/// Returns `true` if `block` has any declared values with importance `important`.
pub fn hasValues(decls: *const Declarations, block: Block, importance: Importance) bool {
    const meta = decls.meta.items[@intFromEnum(block)];
    const all, const set = switch (importance) {
        .important => .{ meta.all_important, meta.active_aggregates_important },
        .normal => .{ meta.all_normal, meta.active_aggregates_normal },
    };
    return (set.count() != 0) or (all != null);
}

pub fn getMeta(decls: *const Declarations, block: Block) *const Meta {
    return &decls.meta.items[@intFromEnum(block)];
}

// TODO: These non-mutating APIs have some flaws:
//       1. Too much of it is public
//       2. Requires passing pointers to metadata (`getMeta` should not exist)
//       Solution: Move code from users of this API into this file.

/// For each aggregate field, gets the partially cascaded value from the
/// declaration block and applies it to `dest`.
///
/// To "apply a value from src to dest" means the following:
/// If dest is undeclared, then copy src to dest. Otherwise, do nothing.
pub fn apply(
    decls: *const Declarations,
    comptime aggregate_tag: aggregates.Tag,
    block: Block,
    importance: Importance,
    meta: *const Meta,
    dest: *aggregate_tag.DeclaredValues(),
) void {
    assert(meta == &decls.meta.items[@intFromEnum(block)]);
    const default_value = meta.defaultValue(importance);

    if (@field(decls.headers, @tagName(aggregate_tag)).get(@intFromEnum(block))) |header| {
        return header.apply(importance, dest, default_value);
    }

    if (default_value == .undeclared) return;
    inline for (aggregate_tag.fields()) |field| {
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
            const tag_values = @typeInfo(DeclaredValueTag).@"enum".fields[0..kw_values.len];
            for (kw_values, tag_values) |kw, tag| assert(kw.value == tag.value);
        }

        fn fromTag(tag: DeclaredValueTag) Keyword {
            return @enumFromInt(@intFromEnum(tag));
        }
    };

    /// Represents the absence of a declared value.
    const undeclared = ValueCount{ .keyword = .none, .num = 0 };

    fn fromInt(num: u6) ValueCount {
        assert(num > 0);
        return .{ .keyword = .none, .num = num };
    }

    fn fromTag(tag: DeclaredValueTag) ValueCount {
        return .{ .keyword = Keyword.fromTag(tag), .num = 0 };
    }
};

/// The maximum number of values allowed in a multi-sized aggregate field.
pub const max_list_len = std.math.maxInt(@FieldType(ValueCount, "num"));

fn Header(comptime aggregate_tag: aggregates.Tag) type {
    switch (aggregate_tag.size()) {
        .single => return SingleValueHeader(aggregate_tag),
        .multi => return MultiValueHeader(aggregate_tag),
    }
}

fn SingleValueHeader(comptime aggregate_tag: aggregates.Tag) type {
    const Aggregate = aggregate_tag.SpecifiedValues();
    const FieldEnum = aggregate_tag.FieldEnum();
    const Counts = std.enums.EnumFieldStruct(FieldEnum, ValueCount, .undeclared);

    return struct {
        normal: Aggregate = undefined,
        important: Aggregate = undefined,
        normal_counts: Counts = .{},
        important_counts: Counts = .{},

        fn set(header: *@This(), comptime field: FieldEnum, importance: Importance, value: SingleValue(aggregate_tag.FieldType(field))) void {
            const counts, const values = switch (importance) {
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

        fn apply(header: *const @This(), importance: Importance, dest: *aggregate_tag.DeclaredValues(), default_value: DeclaredValueTag) void {
            const counts, const values = switch (importance) {
                .important => .{ header.important_counts, header.important },
                .normal => .{ header.normal_counts, header.normal },
            };
            inline for (aggregate_tag.fields()) |field| {
                const dest_field = &@field(dest, field.name);
                if (dest_field.* == .undeclared) {
                    const count = @field(counts, field.name);
                    dest_field.* = switch (count.keyword) {
                        .none => blk: {
                            if (count.num == 0) {
                                break :blk zss.meta.unionTagToVoidPayload(SingleValue(field.type), default_value);
                            } else {
                                assert(count.num == 1);
                                break :blk .{ .declared = @field(values, field.name) };
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
    const FieldEnum = aggregate_tag.FieldEnum();
    const default_counts = std.enums.directEnumArrayDefault(FieldEnum, ValueCount, .undeclared, 0, .{});
    const Counts = @TypeOf(default_counts);

    const max_alignment = comptime blk: {
        var result = 0;
        for (aggregate_tag.fields()) |field| {
            result = @max(result, @alignOf(field.type));
        }
        break :blk result;
    };
    return struct {
        data: std.ArrayListAlignedUnmanaged(u8, max_alignment) = .empty,
        normal_tags: Counts = default_counts,
        important_tags: Counts = default_counts,

        fn set(
            header: *@This(),
            comptime field: FieldEnum,
            importance: Importance,
            noalias value: MultiValue(aggregate_tag.FieldType(field)), // TODO: This can't alias header.data.items
            arena: *ArenaAllocator,
        ) !void {
            const counts = switch (importance) {
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

                    const Field = aggregate_tag.FieldType(field);
                    const field_range_start = fieldRangeStart(header, field, importance);
                    const field_range_len = std.mem.alignForward(usize, field_range_start + @sizeOf(Field) * count.num, max_alignment);
                    const range = try header.data.addManyAt(arena.allocator(), field_range_start, field_range_len);
                    @memcpy(range.ptr, std.mem.sliceAsBytes(slice));
                },
                .initial, .inherit, .unset, .undeclared => count.* = .fromTag(value),
            }
        }

        fn apply(header: *const @This(), importance: Importance, dest: *aggregate_tag.DeclaredValues(), default_value: DeclaredValueTag) void {
            const counts = switch (importance) {
                .important => header.important_tags,
                .normal => header.normal_tags,
            };
            var current_index = fieldRangeStart(header, @enumFromInt(0), importance);
            inline for (aggregate_tag.fields(), 0..) |field, field_index| {
                const count = counts[field_index];
                const end_index = current_index + @sizeOf(field.type) * count.num;
                defer current_index = std.mem.alignForward(usize, end_index, max_alignment);

                const dest_field = &@field(dest, field.name);
                if (dest_field.* == .undeclared) {
                    dest_field.* = switch (count.keyword) {
                        .none => blk: {
                            if (count.num == 0) {
                                break :blk zss.meta.unionTagToVoidPayload(MultiValue(field.type), default_value);
                            } else {
                                const bytes: []align(max_alignment) const u8 = @alignCast(header.data.items[current_index..end_index]);
                                break :blk .{ .declared = std.mem.bytesAsSlice(field.type, bytes) };
                            }
                        },
                        .initial => .initial,
                        .inherit => .inherit,
                        .unset => .unset,
                    };
                }
            }
        }

        fn fieldRangeStart(header: *const @This(), field: FieldEnum, importance: Importance) usize {
            var current_index: usize = 0;
            for ([_]Importance{ .normal, .important }) |current_importance| {
                const counts = switch (current_importance) {
                    .important => header.important_tags,
                    .normal => header.normal_tags,
                };
                for (std.enums.values(FieldEnum)) |current_field| {
                    const count = counts[@intFromEnum(current_field)];
                    if (current_importance == importance and current_field == field) {
                        assert(current_index % max_alignment == 0);
                        return current_index;
                    } else {
                        const size: usize = switch (current_field) {
                            inline else => |comptime_field| @sizeOf(aggregate_tag.FieldType(comptime_field)),
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
        fn getValues(d: *const Declarations, comptime aggregate_tag: aggregates.Tag, b: Block, importance: Importance) aggregate_tag.DeclaredValues() {
            const meta = d.getMeta(b);
            var values: aggregate_tag.DeclaredValues() = .{};
            d.apply(aggregate_tag, b, importance, meta, &values);
            return values;
        }
    };

    const box_style = ns.getValues(&decls, .box_style, block, .normal);
    try box_style.display.expectEqual(.{ .declared = .block });
    try box_style.position.expectEqual(.{ .declared = .relative });

    const background_clip_normal = ns.getValues(&decls, .background_clip, block, .normal);
    try background_clip_normal.clip.expectEqual(.{ .declared = clip_values });

    const background_clip_important = ns.getValues(&decls, .background_clip, block, .important);
    try background_clip_important.clip.expectEqual(.initial);
}
