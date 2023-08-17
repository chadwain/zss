const zss = @import("../../zss.zig");
const ElementTree = zss.ElementTree;
const Environment = zss.Environment;
const Specificity = zss.selectors.Specificity;

const std = @import("std");
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

pub const Name = enum {
    unrecognized,
};

pub const Declaration = struct {
    name: Name,
    component_index: zss.syntax.ComponentTree.Size,
};

/// Groups declarations that have the same precedence in the cascade (i.e. they have the same origin, specificity, order, etc.).
pub const GroupOfDeclarations = struct {
    declarations: []const Declaration,
    specificity: Specificity,
    important: bool,
};

pub const DeclaredValuesList = MultiArrayList(GroupOfDeclarations);

/// Gets all declared values for an element.
pub fn getDeclaredValuesList(
    env: *const Environment,
    tree: ElementTree.Slice,
    element: ElementTree.Element,
    allocator: Allocator,
) !DeclaredValuesList {
    if (env.stylesheets.items.len == 0) return .{};
    if (env.stylesheets.items.len > 1) panic("TODO: getDeclaredValues: Can only handle one stylesheet", .{});

    const rules = env.stylesheets.items[0].rules.slice();

    var result = DeclaredValuesList{};
    errdefer result.deinit(allocator);

    for (rules.items(.selector), 0..) |selector, i| {
        const specificity = selector.matchElement(tree, element) orelse continue;
        try result.append(allocator, .{ .declarations = rules.items(.important_declarations)[i], .specificity = specificity, .important = true });
        try result.append(allocator, .{ .declarations = rules.items(.normal_declarations)[i], .specificity = specificity, .important = false });
    }

    // Sort the declared values such that values that are of higher precedence in the cascade are earlier in the list.
    const SortContext = struct {
        slice: DeclaredValuesList.Slice,

        const Field = std.meta.FieldEnum(GroupOfDeclarations);

        pub fn swap(sc: @This(), a_index: usize, b_index: usize) void {
            inline for (std.meta.fields(GroupOfDeclarations), 0..) |field_info, i| {
                const field = @intToEnum(Field, i);
                const ptr = sc.slice.items(field);
                std.mem.swap(field_info.type, &ptr[a_index], &ptr[b_index]);
            }
        }

        pub fn lessThan(sc: @This(), a_index: usize, b_index: usize) bool {
            const left_important = sc.slice.items(.important)[a_index];
            const right_important = sc.slice.items(.important)[b_index];
            if (left_important != right_important) {
                return left_important;
            }

            const left_specificity = sc.slice.items(.specificity)[a_index];
            const right_specificity = sc.slice.items(.specificity)[b_index];
            switch (left_specificity.order(right_specificity)) {
                .lt => return false,
                .gt => return true,
                .eq => {},
            }

            return false;
        }
    };

    // Must be a stable sort.
    std.sort.insertionContext(0, result.len, SortContext{ .slice = result.slice() });

    return result;
}

test "declarations" {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    const input =
        \\test {
        \\  color: blue;
        \\  color: red !important;
        \\}
        \\
        \\* {
        \\  width: 2;
        \\  height: tall ! important;
        \\}
    ;
    const source = zss.syntax.parse.Source.init(try zss.syntax.tokenize.Source.init(zss.util.ascii8ToAscii7(input)));
    try env.addStylesheet(source);

    var tree = zss.ElementTree{};
    defer tree.deinit(allocator);
    const element = try tree.allocateElement(allocator);
    const tree_slice = tree.slice();
    tree_slice.set(.fq_type, element, .{ .namespace = .none, .name = @intToEnum(Environment.NameId, 0) });

    var declared_values = try getDeclaredValuesList(&env, tree_slice, element, allocator);
    defer declared_values.deinit(allocator);

    var stderr = std.io.getStdErr().writer();
    for (declared_values.items(.declarations)) |decls| {
        for (decls) |decl| {
            try stderr.print("{} {}\n", .{ @enumToInt(decl.name), decl.component_index });
        }
    }
}
