const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const ClassId = Environment.ClassId;
const Element = ElementTree.Element;
const ElementTree = zss.ElementTree;
const Environment = zss.Environment;
const IdId = Environment.IdId;
const NamespaceId = Environment.Namespaces.Id;
const NameId = Environment.NameId;
const Stylesheet = zss.Stylesheet;
const TokenSource = zss.syntax.TokenSource;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MultiArrayList = std.MultiArrayList;

pub const Parser = @import("selectors/parse.zig").Parser;

pub const Size = u24;

pub const Code = union {
    /// The index of the start of the next complex selector.
    /// If this is the last complex selector within the code list, then this just points to the end of the code list.
    next_complex_selector: Size,
    /// Found after every compound selector.
    trailing: Trailing,
    simple_selector_tag: SimpleSelectorTag,
    type_selector: QualifiedName,
    id_selector: IdId,
    class_selector: ClassId,
    attribute_selector: QualifiedName,
    // TODO: Intern attribute values parsed from selectors
    attribute_selector_value: Ast.Size,
    pseudo_class_selector: PseudoClass,
    pseudo_element_selector: PseudoElement,

    pub const Trailing = packed struct {
        /// The combinator applied to this compound selector (the left-hand side) and the compound selector after it (the right-hand side).
        /// If this is the last compound selector in a complex selector, this field is undefined and should not be used.
        combinator: Combinator,
        /// The index of the start of this compound selector (i.e. the first `simple_selector_tag` within this compound).
        compound_selector_start: Size,
    };

    // TODO: Put payloads into this union, fit it all into 4 bytes
    pub const SimpleSelectorTag = union(enum) {
        /// The next Code is a `type_selector`
        type,
        /// The next Code is a `id_selector`
        id,
        /// The next Code is a `class_selector`
        class,
        /// The next Code is a `attribute_selector`
        /// If non-null, then there is also an `attribute_selector_value` following the `attribute_selector`
        attribute: ?AttributeOperatorCase,
        /// The next Code is a `pseudo_class_selector`
        pseudo_class,
        /// The next Code is a `pseudo_element_selector`
        pseudo_element,
    };

    pub const AttributeOperatorCase = struct {
        operator: AttributeOperator,
        case: AttributeCase,
    };
};

comptime {
    if (!zss.debug.runtime_safety) assert(@sizeOf(Code) == 4);
}

pub const QualifiedName = packed struct {
    namespace: NamespaceId,
    name: NameId,

    fn matchElement(qualified: QualifiedName, element_type: ElementTree.FqType) bool {
        assert(element_type.namespace != .any);
        assert(element_type.name != .any);

        switch (qualified.namespace) {
            .any => {},
            else => if (qualified.namespace != element_type.namespace) return false,
        }

        switch (qualified.name) {
            .any => {},
            .anonymous => return false,
            _ => if (qualified.name != element_type.name) return false,
        }

        return true;
    }
};

pub const Combinator = enum(u8) { descendant, child, next_sibling, subsequent_sibling, column };

pub const PseudoElement = enum { unrecognized };

pub const PseudoClass = enum { unrecognized };

pub const AttributeOperator = enum { equals, list_contains, equals_or_prefix_dash, starts_with, ends_with, contains };

pub const AttributeCase = enum { default, same_case, ignore_case };

/// A list of complex selectors.
/// Each complex selector is represented as an array of `Code`.
///
/// Data layout (items in backticks represent fields of `Code`):
/// <list> = [ `next_complex_selector` <complex-selector> ]*
/// <complex-selector> = [ <compound-selector> `trailing` ]+
/// <compound-selector> = [ `simple_selector_tag` <simple-selector> ]+
/// <simple-selector> = <variable data, depending on the previous `simple_selector_tag`>
pub const CodeList = struct {
    list: std.ArrayList(Code),

    pub fn init(allocator: Allocator) CodeList {
        return .{ .list = .init(allocator) };
    }

    pub fn deinit(code_list: *CodeList) void {
        code_list.list.deinit();
    }

    pub fn len(code_list: *const CodeList) Size {
        return @intCast(code_list.list.items.len);
    }

    pub fn toOwnedSlice(code_list: *CodeList) ![]Code {
        return code_list.list.toOwnedSlice();
    }

    pub fn append(code_list: *CodeList, code: Code) !void {
        if (code_list.list.items.len == std.math.maxInt(Size)) return error.OutOfMemory;
        try code_list.list.append(code);
    }

    pub fn appendSlice(code_list: *CodeList, codes: []const Code) !void {
        if (codes.len > std.math.maxInt(Size) - code_list.list.items.len) return error.OutOfMemory;
        try code_list.list.appendSlice(codes);
    }

    pub fn beginComplexSelector(code_list: *CodeList) !Size {
        const index = code_list.len();
        try code_list.append(undefined);
        return index;
    }

    /// `start` is the value previously returned by `beginComplexSelector`
    pub fn endComplexSelector(code_list: *CodeList, start: Size) void {
        code_list.list.items[start] = .{ .next_complex_selector = code_list.len() };
        code_list.list.items[code_list.len() - 1].trailing.combinator = undefined;
    }

    pub fn reset(code_list: *CodeList, complex_selector_start: Size) void {
        code_list.list.shrinkRetainingCapacity(complex_selector_start);
    }
};

/// Represents the specificity of a complex selector.
pub const Specificity = packed struct {
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,

    pub fn order(lhs: Specificity, rhs: Specificity) std.math.Order {
        return std.math.order(lhs.toInt(), rhs.toInt());
    }

    fn toInt(specificity: Specificity) u24 {
        // TODO: Figure out how to avoid this byte swapping
        return std.mem.nativeToBig(u24, @as(u24, @bitCast(specificity)));
    }
};

test "Specificity.order" {
    const Order = std.math.Order;
    const order = Specificity.order;
    const ex = std.testing.expectEqual;

    try ex(Order.lt, order(.{}, .{ .c = 1 }));
    try ex(Order.lt, order(.{}, .{ .b = 1 }));
    try ex(Order.lt, order(.{}, .{ .a = 1 }));

    try ex(Order.eq, order(.{ .a = 1 }, .{ .a = 1 }));
    try ex(Order.gt, order(.{ .a = 1, .b = 1 }, .{ .a = 1 }));
    try ex(Order.gt, order(.{ .a = 1, .c = 1 }, .{ .a = 1 }));
    try ex(Order.lt, order(.{ .a = 1, .c = 1 }, .{ .a = 1, .b = 1 }));

    try ex(Order.lt, order(.{}, .{ .a = 255, .b = 255, .c = 255 }));
}

pub fn matchElement(
    code: []const Code,
    complex_selector_index: Size,
    tree: *const ElementTree,
    match_candidate: Element,
) bool {
    switch (tree.category(match_candidate)) {
        .normal => {},
        .text => unreachable,
    }

    const last_trailing = code[complex_selector_index].next_complex_selector - 1;
    return matchComplexSelector(code, complex_selector_index + 1, last_trailing, tree, match_candidate);
}

fn matchComplexSelector(
    codes: []const Code,
    first_compound: Size,
    last_trailing: Size,
    tree: *const ElementTree,
    match_candidate: Element,
) bool {
    var trailing_index = last_trailing;
    var trailing = codes[trailing_index].trailing;
    var element = match_candidate;
    if (!matchCompoundSelector(codes, trailing.compound_selector_start, trailing_index, tree, element)) return false;
    compound_loop: while (trailing.compound_selector_start != first_compound) {
        trailing_index = trailing.compound_selector_start - 1;
        trailing = codes[trailing_index].trailing;
        switch (trailing.combinator) {
            .descendant => {
                element = tree.parent(element);
                while (!element.eqlNull()) : (element = tree.parent(element)) {
                    switch (tree.category(element)) {
                        .normal => {},
                        .text => unreachable,
                    }
                    if (matchCompoundSelector(codes, trailing.compound_selector_start, trailing_index, tree, element)) continue :compound_loop;
                } else return false;
            },
            .child => {
                element = tree.parent(element);
                while (!element.eqlNull()) : (element = tree.parent(element)) {
                    switch (tree.category(element)) {
                        .normal => break,
                        .text => unreachable,
                    }
                } else return false;
                if (matchCompoundSelector(codes, trailing.compound_selector_start, trailing_index, tree, element)) continue :compound_loop;
                return false;
            },
            .subsequent_sibling => {
                element = tree.previousSibling(element);
                while (!element.eqlNull()) : (element = tree.previousSibling(element)) {
                    switch (tree.category(element)) {
                        .normal => {
                            if (matchCompoundSelector(codes, trailing.compound_selector_start, trailing_index, tree, element)) continue :compound_loop;
                        },
                        .text => {},
                    }
                }
            },
            .next_sibling => {
                element = tree.previousSibling(element);
                while (!element.eqlNull()) : (element = tree.previousSibling(element)) {
                    switch (tree.category(element)) {
                        .normal => break,
                        .text => {},
                    }
                } else return false;
                if (matchCompoundSelector(codes, trailing.compound_selector_start, trailing_index, tree, element)) continue :compound_loop;
                return false;
            },
            else => panic("TODO: Unsupported combinator: {s}\n", .{@tagName(trailing.combinator)}),
        }
    }
    return true;
}

fn matchCompoundSelector(codes: []const Code, start: Size, end: Size, tree: *const ElementTree, element: Element) bool {
    var index = start;
    while (index < end) : (index += 1) {
        switch (codes[index].simple_selector_tag) {
            .type => {
                index += 1;
                const ty = codes[index].type_selector;
                const element_type = tree.fqType(element);
                if (!ty.matchElement(element_type)) return false;
            },
            .id => {
                index += 1;
                const id = codes[index].id_selector;
                const element_with_id = tree.getElementById(id) orelse return false;
                if (element != element_with_id) return false;
            },
            .class,
            .attribute,
            .pseudo_class,
            .pseudo_element,
            => panic("TODO: Handle '{s}' selector in compound selector matching", .{@tagName(codes[index].simple_selector_tag)}),
        }
    }
    return true;
}

test "matching type selectors" {
    const some_namespace = @as(NamespaceId, @enumFromInt(24));
    const some_name = @as(NameId, @enumFromInt(42));

    const e1 = ElementTree.FqType{ .namespace = .none, .name = .anonymous };
    const e2 = ElementTree.FqType{ .namespace = .none, .name = some_name };
    const e3 = ElementTree.FqType{ .namespace = some_namespace, .name = .anonymous };
    const e4 = ElementTree.FqType{ .namespace = some_namespace, .name = some_name };

    const expect = std.testing.expect;
    const matches = QualifiedName.matchElement;

    try expect(matches(.{ .namespace = .any, .name = .any }, e1));
    try expect(matches(.{ .namespace = .any, .name = .any }, e2));
    try expect(matches(.{ .namespace = .any, .name = .any }, e3));
    try expect(matches(.{ .namespace = .any, .name = .any }, e4));

    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e1));
    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e2));
    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e3));
    try expect(!matches(.{ .namespace = .any, .name = .anonymous }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = .any }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = .any }, e2));
    try expect(matches(.{ .namespace = some_namespace, .name = .any }, e3));
    try expect(matches(.{ .namespace = some_namespace, .name = .any }, e4));

    try expect(!matches(.{ .namespace = .any, .name = some_name }, e1));
    try expect(matches(.{ .namespace = .any, .name = some_name }, e2));
    try expect(!matches(.{ .namespace = .any, .name = some_name }, e3));
    try expect(matches(.{ .namespace = .any, .name = some_name }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e2));
    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e3));
    try expect(!matches(.{ .namespace = some_namespace, .name = .anonymous }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e2));
    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e3));
    try expect(matches(.{ .namespace = some_namespace, .name = some_name }, e4));
}

const TestParseSelectorListExpected = []const struct {
    complex: []const struct {
        compound: struct {
            type: ?struct {
                namespace: NamespaceId = .any,
                name: NameId,
            } = null,
            subclasses: []const union(enum) {
                id: IdId,
                class: ClassId,
                pseudo_class: PseudoClass,
                attribute: struct {
                    namespace: NamespaceId = .none,
                    name: NameId,
                    value: ?struct {
                        operator: AttributeOperator,
                        case: AttributeCase,
                    } = null,
                },
            } = &.{},
            pseudo_elements: []const struct {
                element: PseudoElement,
                pseudo_classes: []const PseudoClass = &.{},
            } = &.{},
        },
        combinator: ?Combinator = null,
    },
};

fn expectEqualComplexSelectorLists(expected: TestParseSelectorListExpected, codes: []const Code, num_actual: Size) !void {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(expected.len, num_actual);
    var index_of_complex: Size = 0;
    for (expected) |expected_complex| {
        var index = index_of_complex + 1;
        index_of_complex = codes[index_of_complex].next_complex_selector;

        for (expected_complex.complex, 0..) |expected_item, compound_index| {
            const expected_compound = expected_item.compound;

            if (expected_compound.type) |expected_type| {
                _ = codes[index].simple_selector_tag;
                index += 1;
                const actual_type = codes[index].type_selector;
                index += 1;
                try expectEqual(expected_type.namespace, actual_type.namespace);
                try expectEqual(expected_type.name, actual_type.name);
            }

            for (expected_compound.subclasses) |expected_subclass| {
                const actual_tag = codes[index].simple_selector_tag;
                index += 1;
                switch (expected_subclass) {
                    .id => |expected_id| {
                        const actual_id = codes[index].id_selector;
                        index += 1;
                        try expectEqual(expected_id, actual_id);
                    },
                    .class => |expected_class| {
                        const actual_class = codes[index].class_selector;
                        index += 1;
                        try expectEqual(expected_class, actual_class);
                    },
                    .pseudo_class => |expected_pseudo| {
                        const actual_pseudo = codes[index].pseudo_class_selector;
                        index += 1;
                        try expectEqual(expected_pseudo, actual_pseudo);
                    },
                    .attribute => |expected_attribute| {
                        const actual_attribute = codes[index].attribute_selector;
                        index += 1;
                        try expectEqual(expected_attribute.namespace, actual_attribute.namespace);
                        try expectEqual(expected_attribute.name, actual_attribute.name);
                        if (expected_attribute.value) |expected_value| {
                            _ = codes[index].attribute_selector_value;
                            index += 1;
                            try expectEqual(expected_value.operator, actual_tag.attribute.?.operator);
                            try expectEqual(expected_value.case, actual_tag.attribute.?.case);
                        }
                    },
                }
            }

            for (expected_compound.pseudo_elements) |expected_element| {
                _ = codes[index].simple_selector_tag;
                index += 1;
                const actual_element = codes[index].pseudo_element_selector;
                index += 1;
                try expectEqual(expected_element.element, actual_element);
                for (expected_element.pseudo_classes) |expected_class| {
                    const actual_class = codes[index].pseudo_class_selector;
                    index += 1;
                    try expectEqual(expected_class, actual_class);
                }
            }

            if (compound_index != expected_complex.complex.len - 1) {
                const expected_combinator = expected_item.combinator.?;
                const actual_combinator = codes[index].trailing.combinator;
                index += 1;
                try expectEqual(expected_combinator, actual_combinator);
            }
        }
    }

    try expectEqual(codes.len, index_of_complex);
}

fn stringToSelectorList(input: []const u8, env: *Environment, allocator: Allocator, code_list: *CodeList) !Size {
    const source = try TokenSource.init(input);

    var ast = blk: {
        var parser = zss.syntax.Parser.init(source, env.allocator);
        defer parser.deinit();
        break :blk try parser.parseListOfComponentValues(env.allocator);
    };
    defer ast.deinit(env.allocator);

    const component_list: Ast.Size = 0;
    assert(ast.tag(component_list) == .component_list);

    var parser = Parser.init(env, allocator, source, ast, &.{});
    defer parser.deinit();

    try parser.parseComplexSelectorList(code_list, ast.children(component_list));
    return @intCast(parser.specificities.items.len);
}

fn testParseSelectorList(input: []const u8, expected: TestParseSelectorListExpected) !void {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    var code_list = CodeList.init(allocator);
    defer code_list.deinit();

    const num_selectors = try stringToSelectorList(input, &env, allocator, &code_list);
    try expectEqualComplexSelectorLists(expected, code_list.list.items, num_selectors);
}

test "parsing selector lists" {
    const n = struct {
        fn f(x: u24) NameId {
            return @as(NameId, @enumFromInt(x));
        }
    }.f;
    const i = struct {
        fn f(x: u24) IdId {
            return @as(IdId, @enumFromInt(x));
        }
    }.f;
    const c = struct {
        fn f(x: u24) ClassId {
            return @as(ClassId, @enumFromInt(x));
        }
    }.f;

    try testParseSelectorList("element-name", &.{.{
        .complex = &.{
            .{ .compound = .{
                .type = .{ .name = n(0) },
            } },
        },
    }});
    try testParseSelectorList("h1[size].class#my-id", &.{.{
        .complex = &.{.{
            .compound = .{
                .type = .{ .name = n(0) },
                .subclasses = &.{
                    .{ .attribute = .{ .name = n(1) } },
                    .{ .class = c(0) },
                    .{ .id = i(1) },
                },
            },
        }},
    }});
    try testParseSelectorList("h1 h2 > h3", &.{
        .{ .complex = &.{
            .{
                .compound = .{ .type = .{ .name = n(0) } },
                .combinator = .descendant,
            },
            .{
                .compound = .{ .type = .{ .name = n(1) } },
                .combinator = .child,
            },
            .{
                .compound = .{ .type = .{ .name = n(2) } },
            },
        } },
    });
    try testParseSelectorList("*", &.{.{
        .complex = &.{.{
            .compound = .{
                .type = .{ .name = .any },
            },
        }},
    }});
    try testParseSelectorList("\\*", &.{.{
        .complex = &.{.{
            .compound = .{
                .type = .{ .name = n(0) },
            },
        }},
    }});
    try testParseSelectorList("a||b", &.{.{
        .complex = &.{
            .{
                .compound = .{ .type = .{ .name = n(0) } },
                .combinator = .column,
            },
            .{
                .compound = .{ .type = .{ .name = n(1) } },
            },
        },
    }});
    try testParseSelectorList("a::unknown", &.{.{
        .complex = &.{.{
            .compound = .{
                .type = .{ .name = n(0) },
                .pseudo_elements = &.{
                    .{ .element = .unrecognized },
                },
            },
        }},
    }});
}

test "complex selector matching" {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    var code_list = CodeList.init(allocator);
    defer code_list.deinit();

    const type_names = [5]Environment.NameId{
        try env.addTypeOrAttributeNameString("root"),
        try env.addTypeOrAttributeNameString("first"),
        try env.addTypeOrAttributeNameString("second"),
        try env.addTypeOrAttributeNameString("grandchild"),
        try env.addTypeOrAttributeNameString("third"),
    };

    const ids = [2]Environment.IdId{
        try env.addIdNameString("alice"),
        try env.addIdNameString("jeff"),
    };

    var tree = ElementTree.init();
    defer tree.deinit(allocator);

    var elements: [6]ElementTree.Element = undefined;
    try tree.allocateElements(allocator, &elements);

    tree.initElement(elements[0], .normal, .orphan);
    tree.initElement(elements[1], .normal, .{ .last_child_of = elements[0] });
    tree.initElement(elements[2], .normal, .{ .last_child_of = elements[0] });
    tree.initElement(elements[3], .normal, .{ .first_child_of = elements[2] });
    tree.initElement(elements[4], .text, .{ .last_child_of = elements[0] });
    tree.initElement(elements[5], .normal, .{ .last_child_of = elements[0] });

    tree.setFqType(elements[0], .{ .namespace = .none, .name = type_names[0] });
    tree.setFqType(elements[1], .{ .namespace = .none, .name = type_names[1] });
    tree.setFqType(elements[2], .{ .namespace = .none, .name = type_names[2] });
    tree.setFqType(elements[3], .{ .namespace = .none, .name = type_names[3] });
    tree.setFqType(elements[5], .{ .namespace = .none, .name = type_names[4] });

    try tree.registerId(allocator, ids[0], elements[0]);
    try tree.registerId(allocator, ids[1], elements[5]);

    const doTest = struct {
        fn f(selector_string: []const u8, en: *Environment, d: *CodeList, ar: *ArenaAllocator, t: *const ElementTree, e: ElementTree.Element) !bool {
            const complex_start = d.len();
            const num_selectors = stringToSelectorList(selector_string, en, ar.allocator(), d) catch |err| switch (err) {
                error.ParseError => return false,
                else => |er| return er,
            };
            assert(num_selectors == 1);
            return matchElement(d.list.items, complex_start, t, e);
        }
    }.f;
    const expect = std.testing.expect;

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    try expect(try doTest("root", &env, &code_list, &arena, &tree, elements[0]));
    try expect(try doTest("first", &env, &code_list, &arena, &tree, elements[1]));
    try expect(try doTest("root > first", &env, &code_list, &arena, &tree, elements[1]));
    try expect(try doTest("root first", &env, &code_list, &arena, &tree, elements[1]));
    try expect(try doTest("second", &env, &code_list, &arena, &tree, elements[2]));
    try expect(try doTest("first + second", &env, &code_list, &arena, &tree, elements[2]));
    try expect(try doTest("first ~ second", &env, &code_list, &arena, &tree, elements[2]));
    try expect(try doTest("third", &env, &code_list, &arena, &tree, elements[5]));
    try expect(try doTest("second + third", &env, &code_list, &arena, &tree, elements[5]));
    try expect(try doTest("second ~ third", &env, &code_list, &arena, &tree, elements[5]));
    try expect(!try doTest("first + third", &env, &code_list, &arena, &tree, elements[5]));
    try expect(try doTest("first ~ third", &env, &code_list, &arena, &tree, elements[5]));
    try expect(try doTest("grandchild", &env, &code_list, &arena, &tree, elements[3]));
    try expect(try doTest("second > grandchild", &env, &code_list, &arena, &tree, elements[3]));
    try expect(try doTest("second grandchild", &env, &code_list, &arena, &tree, elements[3]));
    try expect(try doTest("root grandchild", &env, &code_list, &arena, &tree, elements[3]));
    try expect(try doTest("root second grandchild", &env, &code_list, &arena, &tree, elements[3]));
    try expect(!try doTest("root > grandchild", &env, &code_list, &arena, &tree, elements[3]));
    try expect(try doTest("#alice", &env, &code_list, &arena, &tree, elements[0]));
    try expect(!try doTest("#alice", &env, &code_list, &arena, &tree, elements[5]));
    try expect(try doTest("#alice > #jeff", &env, &code_list, &arena, &tree, elements[5]));
}
