const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub fn ReferencedSkipTree(comptime IndexType: type, comptime ReferenceType: type, comptime ValueType: type) type {
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

    comptime {
        const info = @typeInfo(ReferenceType);
        if (info != .Int or info.Int.signedness != .unsigned) {
            @compileError("ReferenceType must be an unsigned integer type, instead found '" ++ @typeName(ReferenceType) ++ "'");
        }
    }

    const fields = @typeInfo(ValueType).Struct.fields;

    const ListElement = @Type(std.builtin.Type{ .Struct = .{
        .layout = .Auto,
        .decls = &.{},
        .is_tuple = false,
        .fields = &[_]std.builtin.Type.StructField{
            .{
                .name = "__skip",
                .field_type = IndexType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(IndexType),
            },
            .{
                .name = "__ref",
                .field_type = ReferenceType,
                .default_value = null,
                .is_comptime = false,
                .alignment = @alignOf(ReferenceType),
            },
        } ++ fields,
    } });

    const valueToListElement = struct {
        fn f(skip: IndexType, ref: ReferenceType, value: ValueType) ListElement {
            var result: ListElement = undefined;
            result.__skip = skip;
            result.__ref = ref;
            inline for (fields) |field_info| {
                @field(result, field_info.name) = @field(value, field_info.name);
            }
            return result;
        }
    }.f;

    return struct {
        list: List = .{},
        next_ref: Ref = 0,

        pub const Index = IndexType;
        pub const Ref = ReferenceType;
        pub const Value = ValueType;
        pub const List = MultiArrayList(ListElement);
        pub const Iterator = @import("./skip_tree.zig").SkipTreeIterator(IndexType);

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.list.deinit(allocator);
        }

        pub fn size(self: Self) Index {
            return @intCast(Index, self.list.len);
        }

        pub fn iterator(self: Self) Iterator {
            return Iterator{ .index = 0, .end = self.size() };
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: Index) error{ OutOfRefs, OutOfMemory }!void {
            const additional = std.math.cast(Ref, count -| self.list.len) orelse return error.OutOfRefs;
            _ = std.math.add(Ref, self.next_ref, additional) catch return error.OutOfRefs;
            const count_usize = std.math.cast(usize, count) orelse return error.OutOfMemory;
            try self.list.ensureTotalCapacity(allocator, count_usize);
        }

        fn nextRef(self: *Self) Ref {
            defer self.next_ref += 1;
            return self.next_ref;
        }

        /// Creates the root element.
        /// The tree must be empty, and must already have enough capacity to hold one element.
        /// Returns the ref of the new element.
        pub fn createRootAssumeCapacity(self: *Self, value: Value) Ref {
            assert(self.list.len == 0);
            const ref = self.nextRef();
            self.list.appendAssumeCapacity(valueToListElement(1, ref, value));
            return ref;
        }

        /// Create a new element that is the last child of `parent`, and give it the value `value`.
        /// There must already be enough capacity to hold one more element.
        /// Returns the ref of the new element.
        pub fn appendChildAssumeCapacity(self: *Self, parent: Ref, value: Value) Ref {
            const slice = self.list.slice();
            const refs = slice.items(.__ref);
            const parent_index = @intCast(Index, std.mem.indexOfScalar(Ref, refs, parent).?);

            const skips = slice.items(.__skip);
            const parent_next_sibling = parent_index + skips[parent_index];

            var index: Index = 0;
            while (true) {
                while (true) {
                    const next = index + skips[index];
                    if (next > parent_index) break;
                    index = next;
                }
                skips[index] += 1;
                if (index == parent_index) break;
                index += 1;
            }

            const ref = self.nextRef();
            self.list.insertAssumeCapacity(parent_next_sibling, valueToListElement(1, ref, value));
            return ref;
        }
    };
}

test "ReferencedSkipTree" {
    const allocator = std.testing.allocator;
    const Index = u16;
    const Ref = u8;
    const ST = ReferencedSkipTree(Index, Ref, struct {});

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

    const st_skips = st.list.items(.__skip);
    try expectEqualSlices(Index, &[_]Index{ 9, 6, 3, 1, 1, 2, 1, 2, 1 }, st_skips);
}
