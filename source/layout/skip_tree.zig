const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub fn SkipTree(comptime Index: type, comptime Values: type) type {
    comptime {
        const info = @typeInfo(Index);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("Index must be an unsigned integer type, instead found '" ++ @typeName(Index) ++ "'");
        }
    }

    const MultiElem = @Type(std.builtin.TypeInfo{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = @typeInfo(Values).Struct.fields ++ &[_]std.builtin.TypeInfo.StructField{
            .{
                .name = "__skip_tree_skip",
                .field_type = Index,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(Index),
            },
        },
    } });

    const valuesToMultiElem = struct {
        fn f(skip_tree_skip: Index, values: Values) MultiElem {
            var result: MultiElem = undefined;
            result.__skip_tree_skip = skip_tree_skip;
            inline for (std.meta.fields(Values)) |field| {
                @field(result, field.name) = @field(values, field.name);
            }
            return result;
        }
    }.f;

    return struct {
        multi_list: MultiArrayList(MultiElem) = .{},

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.multi_list.deinit(allocator);
        }

        pub fn skips(self: *Self) []const Index {
            return self.multi_list.items(.__skip_tree_skip);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: Index) !void {
            return self.multi_list.ensureTotalCapacity(allocator, count);
        }

        pub fn createRootAssumeCapacity(self: *Self, values: Values) Index {
            assert(self.multi_list.len == 0);
            self.multi_list.appendAssumeCapacity(valuesToMultiElem(1, values));
            return 0;
        }

        pub fn appendChildAssumeCapacity(self: *Self, parent: Index, values: Values) Index {
            const skips_ = self.multi_list.items(.__skip_tree_skip);
            const parent_next_sibling = parent + skips_[parent];

            var index: Index = 0;
            while (true) {
                while (true) {
                    const next = index + skips_[index];
                    if (next > parent) break;
                    index = next;
                }
                skips_[index] += 1;
                if (index == parent) break;
                index += 1;
            }

            self.multi_list.insertAssumeCapacity(parent_next_sibling, valuesToMultiElem(1, values));
            return parent_next_sibling;
        }
    };
}

pub fn SparseSkipTree(comptime Index: type, comptime Values: type) type {
    comptime {
        const info = @typeInfo(Index);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("Index must be an unsigned integer type, instead found '" ++ @typeName(Index) ++ "'");
        }
    }

    const MultiElem = @Type(std.builtin.TypeInfo{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = @typeInfo(Values).Struct.fields ++ &[_]std.builtin.TypeInfo.StructField{
            .{
                .name = "__sparse_tree_skip",
                .field_type = Index,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(Index),
            },
            .{
                .name = "__sparse_tree_reference_index",
                .field_type = Index,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(Index),
            },
        },
    } });

    const valuesToMultiElem = struct {
        fn f(sparse_tree_skip: Index, sparse_tree_reference_index: Index, values: Values) MultiElem {
            var result: MultiElem = undefined;
            result.__sparse_tree_reference_index = sparse_tree_reference_index;
            result.__sparse_tree_skip = sparse_tree_skip;
            inline for (std.meta.fields(Values)) |field| {
                @field(result, field.name) = @field(values, field.name);
            }
            return result;
        }
    }.f;

    return struct {
        multi_list: MultiArrayList(MultiElem) = .{},

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.multi_list.deinit(allocator);
        }

        pub fn skips(self: Self) []const Index {
            return self.multi_list.items(.__sparse_tree_skip);
        }

        pub fn referenceIndeces(self: Self) []const Index {
            return self.multi_list.items(.__sparse_tree_reference_index);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: Index) !void {
            return self.multi_list.ensureTotalCapacity(allocator, count);
        }

        pub fn insertAssumeCapacity(self: *Self, reference_tree_index: Index, reference_tree_skips: []const Index, values: Values) void {
            const slice = self.multi_list.slice();
            const skips_ = slice.items(.__sparse_tree_skip);
            const reference_indeces = slice.items(.__sparse_tree_reference_index);

            var index: Index = 0;
            var end: Index = @intCast(Index, slice.len);
            var previous_index: ?Index = null;

            while (true) {
                if (index < end) {
                    const current_reference_index = reference_indeces[index];
                    if (current_reference_index == reference_tree_index) {
                        // TODO: UB, return, or return error?
                        unreachable; // Element is already in the tree
                    } else if (current_reference_index < reference_tree_index) {
                        previous_index = index;
                        index += skips_[index];
                        continue;
                    }
                }

                const is_child_of_previous = if (previous_index) |pi| blk: {
                    const previous_reference_index = reference_indeces[pi];
                    break :blk reference_tree_index < previous_reference_index + reference_tree_skips[previous_reference_index];
                } else false;
                if (is_child_of_previous) {
                    end = previous_index.? + skips_[previous_index.?];
                    index = previous_index.? + 1;
                    skips_[previous_index.?] += 1;
                    previous_index = null;
                } else {
                    const insertion_point = index;
                    const reference_end = reference_tree_index + reference_tree_skips[reference_tree_index];
                    while (index < end) {
                        const reference_index = reference_indeces[index];
                        if (reference_index >= reference_end) break;
                        index += skips_[index];
                    }
                    return self.multi_list.insertAssumeCapacity(
                        insertion_point,
                        valuesToMultiElem(index - insertion_point + 1, reference_tree_index, values),
                    );
                }
            }
        }
    };
}

test "SkipTree and SparseSkipTree" {
    const allocator = std.testing.allocator;

    const Int = u16;
    const ST = SkipTree(Int, struct {});
    var st = ST{};
    defer st.deinit(allocator);

    try st.ensureTotalCapacity(allocator, 9);
    const root = st.createRootAssumeCapacity(.{});
    const root_0 = st.appendChildAssumeCapacity(root, .{});
    const root_0_0 = st.appendChildAssumeCapacity(root_0, .{});
    const root_0_0_0 = st.appendChildAssumeCapacity(root_0_0, .{});
    const root_0_0_1 = st.appendChildAssumeCapacity(root_0_0, .{});
    const root_0_1 = st.appendChildAssumeCapacity(root_0, .{});
    const root_0_1_0 = st.appendChildAssumeCapacity(root_0_1, .{});
    const root_1 = st.appendChildAssumeCapacity(root, .{});
    const root_1_0 = st.appendChildAssumeCapacity(root_1, .{});
    _ = root_0_0_0;
    _ = root_0_0_1;
    _ = root_0_1_0;
    _ = root_1_0;

    const st_skips = st.skips();
    try expectEqualSlices(Int, &[_]Int{ 9, 6, 3, 1, 1, 2, 1, 2, 1 }, st_skips);

    const SST = SparseSkipTree(Int, struct {});
    var sst = SST{};
    defer sst.deinit(allocator);

    try sst.ensureTotalCapacity(allocator, 5);
    sst.insertAssumeCapacity(0, st_skips, .{});
    sst.insertAssumeCapacity(7, st_skips, .{});
    sst.insertAssumeCapacity(4, st_skips, .{});
    sst.insertAssumeCapacity(2, st_skips, .{});

    try expectEqualSlices(Int, &[_]Int{ 4, 2, 1, 1 }, sst.skips());
    try expectEqualSlices(Int, &[_]Int{ 0, 2, 4, 7 }, sst.referenceIndeces());
}
