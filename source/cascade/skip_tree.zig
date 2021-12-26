const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub fn SkipTree(comptime IndexType: type, comptime Value: type) type {
    comptime {
        const info = @typeInfo(IndexType);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("IndexType must be an unsigned integer type, instead found '" ++ @typeName(IndexType) ++ "'");
        }
    }

    const MultiElem = @Type(std.builtin.TypeInfo{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = @typeInfo(Value).Struct.fields ++ &[_]std.builtin.TypeInfo.StructField{
            .{
                .name = "__skip_tree_skip",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
        },
    } });

    const valueToMultiElem = struct {
        fn f(skip_tree_skip: IndexType, value: Value) MultiElem {
            var result: MultiElem = undefined;
            result.__skip_tree_skip = skip_tree_skip;
            inline for (std.meta.fields(Value)) |field| {
                @field(result, field.name) = @field(value, field.name);
            }
            return result;
        }
    }.f;

    return struct {
        multi_list: MultiArrayList(MultiElem) = .{},

        pub const Index = IndexType;

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.multi_list.deinit(allocator);
        }

        pub fn skips(self: Self) []const Index {
            return self.multi_list.items(.__skip_tree_skip);
        }

        pub fn size(self: Self) Index {
            return @intCast(Index, self.multi_list.len);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: Index) !void {
            return self.multi_list.ensureTotalCapacity(allocator, count);
        }

        pub fn createRootAssumeCapacity(self: *Self, value: Value) Index {
            assert(self.multi_list.len == 0);
            self.multi_list.appendAssumeCapacity(valueToMultiElem(1, value));
            return 0;
        }

        pub fn appendChildAssumeCapacity(self: *Self, parent: Index, value: Value) Index {
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

            self.multi_list.insertAssumeCapacity(parent_next_sibling, valueToMultiElem(1, value));
            return parent_next_sibling;
        }
    };
}

pub fn SparseSkipTree(comptime IndexType: type, comptime ValueSpec: type) type {
    comptime {
        const info = @typeInfo(IndexType);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("IndexType must be an unsigned integer type, instead found '" ++ @typeName(IndexType) ++ "'");
        }
    }

    const MultiElem = @Type(std.builtin.TypeInfo{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = @typeInfo(ValueSpec).Struct.fields ++ &[_]std.builtin.TypeInfo.StructField{
            .{
                .name = "__sparse_tree_skip",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
            .{
                .name = "__sparse_tree_reference_index",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
        },
    } });

    const valueToMultiElem = struct {
        fn f(sparse_tree_skip: IndexType, sparse_tree_reference_index: IndexType, value: ValueSpec) MultiElem {
            var result: MultiElem = undefined;
            result.__sparse_tree_reference_index = sparse_tree_reference_index;
            result.__sparse_tree_skip = sparse_tree_skip;
            inline for (std.meta.fields(ValueSpec)) |field| {
                @field(result, field.name) = @field(value, field.name);
            }
            return result;
        }
    }.f;

    return struct {
        multi_list: MultiList = .{},

        pub const Index = IndexType;
        pub const Value = ValueSpec;
        pub const ValueEnum = std.meta.FieldEnum(Value);

        const Self = @This();
        const MultiList = MultiArrayList(MultiElem);

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

        pub fn insertAssumeCapacity(self: *Self, reference_tree_index: Index, reference_tree_skips: []const Index, value: Value) void {
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

                // We have found that the new element should be inserted after the element at `previous_index`,
                // but we must find out if it (the new element) is a sibling or a child of the one at `previous_index`.

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
                    // Find all elements after `insertion_point` which should become the children of the new element.
                    const reference_end = reference_tree_index + reference_tree_skips[reference_tree_index];
                    while (index < end) {
                        const reference_index = reference_indeces[index];
                        if (reference_index >= reference_end) break;
                        index += skips_[index];
                    }
                    return self.multi_list.insertAssumeCapacity(
                        insertion_point,
                        valueToMultiElem(index - insertion_point + 1, reference_tree_index, value),
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
    sst.insertAssumeCapacity(root, st_skips, .{});
    sst.insertAssumeCapacity(root_1, st_skips, .{});
    sst.insertAssumeCapacity(root_0, st_skips, .{});
    sst.insertAssumeCapacity(root_0_0_0, st_skips, .{});
}

pub fn SSTSeeker(comptime SST: type) type {
    const sst_value_fields = std.meta.fields(SST.Value);

    const SlicePointers = SlicePointers: {
        var fields: [sst_value_fields.len]std.builtin.TypeInfo.StructField = undefined;
        inline for (sst_value_fields) |field, i| {
            fields[i] = .{
                .name = field.name,
                .field_type = [*]const field.field_type,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf([*]const field.field_type),
            };
        }
        break :SlicePointers @Type(std.builtin.TypeInfo{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    return struct {
        pointers: SlicePointers,
        refs: [*]const SST.Index,
        len: SST.Index,
        current_ref: SST.Index = 0,

        pub const TreeType = SST;

        const Self = @This();

        pub fn seekForward(self: *Self, index: SST.Index) bool {
            while (self.current_ref < self.len) {
                const current = self.refs[self.current_ref];
                if (current == index) return true;
                if (current > index) return false;
                self.current_ref += 1;
            }
            return false;
        }

        pub fn get(self: Self) SST.Value {
            var result: SST.Value = undefined;
            inline for (sst_value_fields) |field_info| {
                @field(result, field_info.name) = @field(self.pointers, field_info.name)[self.current_ref];
            }
            return result;
        }

        pub fn getField(self: Self, comptime field: SST.ValueEnum) std.meta.fieldInfo(SST.Value, field).field_type {
            return @field(self.pointers, @tagName(field))[self.current_ref];
        }
    };
}

pub fn sstSeeker(sst: anytype) SSTSeeker(@TypeOf(sst)) {
    const SST = @TypeOf(sst);
    const slice = sst.multi_list.slice();
    var result = SSTSeeker(SST){
        .pointers = undefined,
        .refs = slice.items(.__sparse_tree_reference_index).ptr,
        .len = @intCast(SST.Index, sst.multi_list.len),
    };
    inline for (std.meta.fields(SST.Value)) |field| {
        const tag = comptime std.meta.stringToEnum(SST.MultiList.Field, field.name).?;
        @field(result.pointers, field.name) = slice.items(tag).ptr;
    }
    return result;
}
