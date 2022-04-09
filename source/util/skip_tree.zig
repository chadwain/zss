const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

/// A skip tree is an associative tree data structure that is backed by an array.
/// Each element is given an index of type `IndexType`, and is associated with a value of type `ValueSpec`.
/// Each element also stores the size of its subtree, called its 'skip'.
///
/// The following are always true about a skip tree:
///     1. The root element has index 0, if it exists.
///     2. An element with no children has a skip of 1.
///     3. For any element with index `i`, its first child (if any) has index `i + 1`.
///     4. For any element with index `i` and skip `s`, its next sibling (if any) has index `i + s`.
pub fn SkipTree(comptime IndexType: type, comptime ValueSpec: type) type {
    comptime {
        const info = @typeInfo(IndexType);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("IndexType must be an unsigned integer type, instead found '" ++ @typeName(IndexType) ++ "'");
        }
        const index_bits = info.Int.bits;
        const usize_bits = @typeInfo(usize).Int.bits;
        const print = std.fmt.comptimePrint;
        if (index_bits > usize_bits) {
            @compileError("Bit size of IndexType (" ++ print("{d}", .{index_bits}) ++
                ") cannot be greater than that of usize (" ++ print("{d}", .{usize_bits}) ++ ")");
        }
    }

    const fields = @typeInfo(ValueSpec).Struct.fields;

    const MultiElem = @Type(std.builtin.TypeInfo{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = &[_]std.builtin.TypeInfo.StructField{
            .{
                .name = "__skip",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
        } ++ fields,
    } });

    const valueToMultiElem = struct {
        fn f(skip: IndexType, value: ValueSpec) MultiElem {
            var result: MultiElem = undefined;
            result.__skip = skip;
            inline for (fields) |field_info| {
                @field(result, field_info.name) = @field(value, field_info.name);
            }
            return result;
        }
    }.f;

    return struct {
        multi_list: MultiList = .{},

        pub const Index = IndexType;
        pub const Value = ValueSpec;
        pub const MultiList = MultiArrayList(MultiElem);

        pub const Iterator = SkipTreeIterator(Index);

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.multi_list.deinit(allocator);
        }

        /// The 'skip' associated with each element.
        pub fn skips(self: Self) []const Index {
            return self.multi_list.items(.__skip);
        }

        pub fn slice(self: Self) MultiList.Slice {
            return self.multi_list.slice();
        }

        pub fn size(self: Self) Index {
            return @intCast(Index, self.multi_list.len);
        }

        pub fn iterator(self: Self) ?Iterator {
            if (self.size() == 0) return null;
            return Iterator.init(0, self.skips());
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: Index) !void {
            return self.multi_list.ensureTotalCapacity(allocator, count);
        }

        /// Creates the root element.
        /// The tree must be empty, and must already have enough capacity to hold one element.
        /// Returns the index of the new element.
        pub fn createRootAssumeCapacity(self: *Self, value: Value) Index {
            assert(self.multi_list.len == 0);
            self.multi_list.appendAssumeCapacity(valueToMultiElem(1, value));
            return 0;
        }

        /// Create a new element that as the last child of `parent`, and give it the value `value`.
        /// There must already be enough capacity to hold one more element.
        /// Returns the index of the new element.
        pub fn appendChildAssumeCapacity(self: *Self, parent: Index, value: Value) Index {
            const skip = self.multi_list.items(.__skip);
            const parent_next_sibling = parent + skip[parent];

            var index: Index = 0;
            while (true) {
                while (true) {
                    const next = index + skip[index];
                    if (next > parent) break;
                    index = next;
                }
                skip[index] += 1;
                if (index == parent) break;
                index += 1;
            }

            self.multi_list.insertAssumeCapacity(parent_next_sibling, valueToMultiElem(1, value));
            return parent_next_sibling;
        }
    };
}

pub fn SkipTreeIterator(comptime Index: type) type {
    return struct {
        index: Index,
        end: Index,

        const Self = @This();

        pub fn init(index: Index, skips: []const Index) Self {
            return Self{
                .index = index,
                .end = index + skips[index],
            };
        }

        pub fn empty(self: Self) bool {
            return self.index == self.end;
        }

        pub fn firstChild(self: Self, skips: []const Index) Self {
            return Self{ .index = self.index + 1, .end = self.index + skips[self.index] };
        }

        pub fn nextSibling(self: Self, skips: []const Index) Self {
            return Self{ .index = self.index + skips[self.index], .end = self.end };
        }

        pub fn nextParent(self: Self, child: Index, skips: []const Index) Self {
            assert(child >= self.index);
            var current = self.index;
            var skip: Index = undefined;
            while (true) {
                skip = skips[current];
                if (child < current + skip) break;
                current += skip;
            }
            return Self{ .index = current, .end = current + skip };
        }
    };
}

/// A sparse skip tree (SST) is an associative tree data structure.
/// It is derived from a skip tree, which is called its 'reference tree'.
/// It takes some elements from its reference tree and associates values with them.
/// It is itself a skip tree.
///
/// When a function takes `reference_skips: []const Index` as a parameter, it means to
/// pass in the skips of its reference tree.
pub fn SparseSkipTree(comptime IndexType: type, comptime ValueSpec: type) type {
    comptime {
        const info = @typeInfo(IndexType);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("IndexType must be an unsigned integer type, instead found '" ++ @typeName(IndexType) ++ "'");
        }
        const index_bits = info.Int.bits;
        const usize_bits = @typeInfo(usize).Int.bits;
        const print = std.fmt.comptimePrint;
        if (index_bits > usize_bits) {
            @compileError("Bit size of IndexType (" ++ print("{d}", .{index_bits}) ++
                ") cannot be greater than that of usize (" ++ print("{d}", .{usize_bits}) ++ ")");
        }
    }

    const fields = @typeInfo(ValueSpec).Struct.fields;

    const MultiElem = @Type(std.builtin.TypeInfo{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = &[_]std.builtin.TypeInfo.StructField{
            .{
                .name = "__skip",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
            .{
                .name = "__reference_index",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
        } ++ fields,
    } });

    const valueToMultiElem = struct {
        fn f(skip: IndexType, reference_index: IndexType, value: ValueSpec) MultiElem {
            var result: MultiElem = undefined;
            result.__skip = skip;
            result.__reference_index = reference_index;
            inline for (fields) |field_info| {
                @field(result, field_info.name) = @field(value, field_info.name);
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

        /// The skip associated with each element.
        pub fn skips(self: Self) []const Index {
            return self.multi_list.items(.__skip);
        }

        /// The reference index associated with each element.
        pub fn referenceIndeces(self: Self) []const Index {
            return self.multi_list.items(.__reference_index);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: Index) !void {
            return self.multi_list.ensureTotalCapacity(allocator, count);
        }

        /// Insert the element with reference index `reference_index`, and give it the value `value`.
        pub fn insertAssumeCapacity(self: *Self, reference_skips: []const Index, reference_index: Index, value: Value) void {
            const slice = self.multi_list.slice();
            const skip = slice.items(.__skip);
            const reference_indeces = slice.items(.__reference_index);

            var index: Index = 0;
            var end: Index = @intCast(Index, slice.len);
            var previous_index: ?Index = null;

            while (true) {
                if (index < end) {
                    const current_reference_index = reference_indeces[index];
                    if (current_reference_index == reference_index) {
                        unreachable; // Element is already in the tree
                    } else if (current_reference_index < reference_index) {
                        previous_index = index;
                        index += skip[index];
                        continue;
                    }
                }

                // We have found that the new element should be inserted after the element at `previous_index`,
                // but we must find out if it (the new element) is a sibling or a child of the one at `previous_index`.

                const is_child_of_previous = if (previous_index) |pi| blk: {
                    const previous_reference_index = reference_indeces[pi];
                    break :blk reference_index < previous_reference_index + reference_skips[previous_reference_index];
                } else false;
                if (is_child_of_previous) {
                    index = previous_index.? + 1;
                    end = previous_index.? + skip[previous_index.?];
                    skip[previous_index.?] += 1;
                    previous_index = null;
                } else {
                    const insertion_point = index;
                    // Find all elements after `insertion_point` which should become the children of the new element.
                    const reference_element_end = reference_index + reference_skips[reference_index];
                    while (index < end) {
                        const reference_element_index = reference_indeces[index];
                        if (reference_element_index >= reference_element_end) break;
                        index += skip[index];
                    }
                    return self.multi_list.insertAssumeCapacity(
                        insertion_point,
                        valueToMultiElem(index - insertion_point + 1, reference_index, value),
                    );
                }
            }
        }
    };
}

test "SkipTree and SparseSkipTree" {
    const allocator = std.testing.allocator;
    const Index = u16;
    const ST = SkipTree(Index, struct {});

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
    try expectEqualSlices(Index, &[_]Index{ 9, 6, 3, 1, 1, 2, 1, 2, 1 }, st_skips);

    const SST = SparseSkipTree(Index, struct {});
    var sst = SST{};
    defer sst.deinit(allocator);

    try sst.ensureTotalCapacity(allocator, 4);
    sst.insertAssumeCapacity(st_skips, root, .{});
    sst.insertAssumeCapacity(st_skips, root_1, .{});
    sst.insertAssumeCapacity(st_skips, root_0, .{});
    sst.insertAssumeCapacity(st_skips, root_0_0_0, .{});

    const sst_skips = sst.skips();
    const sst_reference_indexes = sst.referenceIndeces();
    try expectEqualSlices(Index, &[_]Index{ 4, 2, 1, 1 }, sst_skips);
    try expectEqualSlices(Index, &[_]Index{ root, root_0, root_0_0_0, root_1 }, sst_reference_indexes);
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

        pub fn getBinary(self: Self, index: SST.Index) ?SST.Value {
            const compareFn = struct {
                fn f(context: void, lhs: SST.Index, rhs: SST.Index) std.math.Order {
                    _ = context;
                    return std.math.order(lhs, rhs);
                }
            }.f;
            const ref_index = std.sort.binarySearch(SST.Index, index, self.refs[0..self.len], {}, compareFn) orelse return null;

            var result: SST.Value = undefined;
            inline for (sst_value_fields) |field_info| {
                @field(result, field_info.name) = @field(self.pointers, field_info.name)[ref_index];
            }
            return result;
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
        .refs = slice.items(.__reference_index).ptr,
        .len = @intCast(SST.Index, sst.multi_list.len),
    };
    inline for (std.meta.fields(SST.Value)) |field| {
        const tag = comptime std.meta.stringToEnum(SST.MultiList.Field, field.name).?;
        @field(result.pointers, field.name) = slice.items(tag).ptr;
    }
    return result;
}
