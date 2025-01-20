const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const ClassId = Environment.ClassId;
const Element = ElementTree.Element;
const ElementTree = zss.ElementTree;
const Environment = zss.Environment;
const IdId = Environment.IdId;
const NamespaceId = Environment.NamespaceId;
const NameId = Environment.NameId;
const TokenSource = zss.syntax.TokenSource;

const Parser = @import("selectors/parse.zig").Parser;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MultiArrayList = std.MultiArrayList;

pub fn parseSelectorList(
    env: *Environment,
    arena: *ArenaAllocator,
    source: TokenSource,
    slice: Ast.Slice,
    sequence: Ast.Sequence,
) !ComplexSelectorList {
    var parser = Parser.init(env, arena, source, slice, sequence);
    return try parser.parseComplexSelectorList();
}

pub const ComplexSelectorList = struct {
    list: List,

    pub const Item = struct {
        complex: ComplexSelector,
        specificity: Specificity,
    };

    pub const List = MultiArrayList(Item).Slice;

    pub fn deinit(complex_selector_list: *ComplexSelectorList, allocator: Allocator) void {
        for (complex_selector_list.list.items(.complex)) |*complex| {
            complex.deinit(allocator);
        }
        complex_selector_list.list.deinit(allocator);
    }

    /// Determines if the element matches the complex selector list, and if so, returns the specificity of the list.
    /// Note that the specificity of a selector list depends on the object that it's being matched on:
    /// it is that of the most specific selector in the list that matches the element.
    /// See CSS Selectors Level 4 section 17 "Calculating a selector's specificity".
    pub fn matchElement(complex_selector_list: ComplexSelectorList, tree: ElementTree.Slice, element: Element) ?Specificity {
        // TODO: If selectors in the list were already sorted by specificity (highest to lowest), we could return on the first match.
        var result: ?Specificity = null;
        for (complex_selector_list.list.items(.complex), 0..) |complex, i| {
            if (!complex.matchElement(tree, element)) continue;
            const specificity = complex_selector_list.list.items(.specificity)[i];
            if (result == null or result.?.order(specificity) == .lt) {
                result = specificity;
            }
        }
        return result;
    }
};

/// Represents the specificity of a complex selector.
pub const Specificity = packed struct {
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,

    pub const SelectorKind = enum { id, class, attribute, pseudo_class, type_ident, pseudo_element };

    pub fn add(specificity: *Specificity, comptime kind: SelectorKind) void {
        const field_name = switch (kind) {
            .id => "a",
            .class, .attribute, .pseudo_class => "b",
            .type_ident, .pseudo_element => "c",
        };
        const field = &@field(specificity, field_name);
        if (field.* < 254) field.* += 1;
    }

    pub fn order(lhs: Specificity, rhs: Specificity) std.math.Order {
        return std.math.order(lhs.toInt(), rhs.toInt());
    }

    fn toInt(specificity: Specificity) u24 {
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

// Data layout:
// <complex-selector> = [ <compound-selector>+ <trailing> ]+
// <compound-selector> = <simple-selector-tag> <simple-selector>
// <simple-selector> = <variable data, depends on simple-selector-tag>
pub const ComplexSelector = struct {
    data: []const Data,

    pub const Index = u24;

    // TODO: Size goal: 4 bytes (in unsafe builds)
    pub const Data = union {
        trailing: struct {
            combinator: Combinator,
            compound_selector_start: Index,
        },
        simple_selector_tag: union(enum) {
            /// The next Data is a `type_selector`
            type,
            /// The next Data is a `id_selector`
            id,
            /// The next Data is a `class_selector`
            class,
            /// The next Data is a `attribute_selector`
            /// If non-null, then there is also a `attribute_selector_value` following the `attribute_selector`
            attribute: ?struct {
                operator: AttributeOperator,
                case: AttributeCase,
            },
            /// The next Data is a `pseudo_class_selector`
            pseudo_class,
            /// The next Data is a `pseudo_element_selector`
            pseudo_element,
        },
        type_selector: Type,
        id_selector: IdId,
        class_selector: ClassId,
        attribute_selector: Type,
        // TODO: Store attribute values parsed from selectors in the Environment
        attribute_selector_value: Ast.Size,
        pseudo_class_selector: PseudoClass,
        pseudo_element_selector: PseudoElement,
    };

    fn deinit(complex: *ComplexSelector, allocator: Allocator) void {
        allocator.free(complex.data);
    }

    fn matchElement(complex: ComplexSelector, tree: ElementTree.Slice, match_candidate: Element) bool {
        switch (tree.category(match_candidate)) {
            .normal => {},
            .text => unreachable,
        }

        var trailing_index: Index = @intCast(complex.data.len - 1);
        var trailing = complex.data[trailing_index].trailing;
        var compound = complex.data[trailing.compound_selector_start..trailing_index];
        var element = match_candidate;
        if (!matchCompoundSelector(compound, tree, element)) return false;
        compound_loop: while (trailing.compound_selector_start != 0) {
            trailing_index = trailing.compound_selector_start - 1;
            trailing = complex.data[trailing_index].trailing;
            compound = complex.data[trailing.compound_selector_start..trailing_index];
            switch (trailing.combinator) {
                .descendant => {
                    element = tree.parent(element);
                    while (!element.eqlNull()) : (element = tree.parent(element)) {
                        switch (tree.category(element)) {
                            .normal => {},
                            .text => unreachable,
                        }
                        if (matchCompoundSelector(compound, tree, element)) continue :compound_loop;
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
                    if (matchCompoundSelector(compound, tree, element)) continue :compound_loop;
                    return false;
                },
                .subsequent_sibling => {
                    element = tree.previousSibling(element);
                    while (!element.eqlNull()) : (element = tree.previousSibling(element)) {
                        switch (tree.category(element)) {
                            .normal => {
                                if (matchCompoundSelector(compound, tree, element)) continue :compound_loop;
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
                    if (matchCompoundSelector(compound, tree, element)) continue :compound_loop;
                    return false;
                },
                else => panic("TODO: Unsupported combinator: {s}\n", .{@tagName(trailing.combinator)}),
            }
        }
        return true;
    }

    fn matchCompoundSelector(compound: []const Data, tree: ElementTree.Slice, element: Element) bool {
        var index: Index = 0;
        while (index < compound.len) : (index += 1) {
            switch (compound[index].simple_selector_tag) {
                .type => {
                    index += 1;
                    const ty = compound[index].type_selector;
                    const element_type = tree.get(.fq_type, element);
                    if (!ty.matchElement(element_type)) return false;
                },
                .id,
                .class,
                .attribute,
                .pseudo_class,
                .pseudo_element,
                => panic("TODO: Handle '{s}' selector in compound selector matching", .{@tagName(compound[index].simple_selector_tag)}),
            }
        }
        return true;
    }
};

pub const Type = struct {
    namespace: NamespaceId,
    name: NameId,

    fn matchElement(ty: Type, element_type: ElementTree.FqType) bool {
        assert(element_type.namespace != .any);
        assert(element_type.name != .any);

        switch (ty.namespace) {
            .any => {},
            else => if (ty.namespace != element_type.namespace) return false,
        }

        switch (ty.name) {
            .any => {},
            .anonymous => return false,
            _ => if (ty.name != element_type.name) return false,
        }

        return true;
    }
};

pub const Combinator = enum { descendant, child, next_sibling, subsequent_sibling, column };

pub const PseudoElement = enum { unrecognized };

pub const PseudoClass = enum { unrecognized };

pub const AttributeOperator = enum { equals, list_contains, equals_or_prefix_dash, starts_with, ends_with, contains };

pub const AttributeCase = enum { default, same_case, ignore_case };

test "matching type selectors" {
    const some_namespace = @as(NamespaceId, @enumFromInt(24));
    const some_name = @as(NameId, @enumFromInt(42));

    const e1 = ElementTree.FqType{ .namespace = .none, .name = .anonymous };
    const e2 = ElementTree.FqType{ .namespace = .none, .name = some_name };
    const e3 = ElementTree.FqType{ .namespace = some_namespace, .name = .anonymous };
    const e4 = ElementTree.FqType{ .namespace = some_namespace, .name = some_name };

    const expect = std.testing.expect;
    const matches = Type.matchElement;

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

fn expectEqualComplexSelectorLists(expected: TestParseSelectorListExpected, actual: ComplexSelectorList.List) !void {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(expected.len, actual.len);
    for (expected, actual.items(.complex)) |expected_complex, actual_complex| {
        const data = actual_complex.data;
        var index: ComplexSelector.Index = 0;
        for (expected_complex.complex, 0..) |expected_item, compound_index| {
            const expected_compound = expected_item.compound;

            if (expected_compound.type) |expected_type| {
                _ = data[index].simple_selector_tag;
                index += 1;
                const actual_type = data[index].type_selector;
                index += 1;
                try expectEqual(expected_type.namespace, actual_type.namespace);
                try expectEqual(expected_type.name, actual_type.name);
            }

            for (expected_compound.subclasses) |expected_subclass| {
                const actual_tag = data[index].simple_selector_tag;
                index += 1;
                switch (expected_subclass) {
                    .id => |expected_id| {
                        const actual_id = data[index].id_selector;
                        index += 1;
                        try expectEqual(expected_id, actual_id);
                    },
                    .class => |expected_class| {
                        const actual_class = data[index].class_selector;
                        index += 1;
                        try expectEqual(expected_class, actual_class);
                    },
                    .pseudo_class => |expected_pseudo| {
                        const actual_pseudo = data[index].pseudo_class_selector;
                        index += 1;
                        try expectEqual(expected_pseudo, actual_pseudo);
                    },
                    .attribute => |expected_attribute| {
                        const actual_attribute = data[index].attribute_selector;
                        index += 1;
                        try expectEqual(expected_attribute.namespace, actual_attribute.namespace);
                        try expectEqual(expected_attribute.name, actual_attribute.name);
                        if (expected_attribute.value) |expected_value| {
                            _ = data[index].attribute_selector_value;
                            index += 1;
                            try expectEqual(expected_value.operator, actual_tag.attribute.?.operator);
                            try expectEqual(expected_value.case, actual_tag.attribute.?.case);
                        }
                    },
                }
            }

            for (expected_compound.pseudo_elements) |expected_element| {
                const actual_element = data[index].pseudo_element_selector;
                index += 1;
                try expectEqual(expected_element.element, actual_element);
                for (expected_element.pseudo_classes) |expected_class| {
                    const actual_class = data[index].pseudo_class_selector;
                    index += 1;
                    try expectEqual(expected_class, actual_class);
                }
            }

            if (compound_index != expected_complex.complex.len - 1) {
                const expected_combinator = expected_item.combinator.?;
                const actual_combinator = data[index].trailing.combinator;
                index += 1;
                try expectEqual(expected_combinator, actual_combinator);
            }
        }
    }
}

fn stringToSelectorList(input: []const u8, env: *Environment, arena: *ArenaAllocator) !ComplexSelectorList {
    const source = try TokenSource.init(input);
    var tree = try zss.syntax.parse.parseListOfComponentValues(source, env.allocator);
    defer tree.deinit(env.allocator);
    const slice = tree.slice();

    const component_list: Ast.Size = 0;
    assert(slice.tag(component_list) == .component_list);
    const start = component_list + 1;
    const end = slice.nextSibling(component_list);

    return try parseSelectorList(env, arena, source, slice, Ast.Sequence{ .start = start, .end = end });
}

fn testParseSelectorList(input: []const u8, expected: TestParseSelectorListExpected) !void {
    const allocator = std.testing.allocator;
    var env = Environment.init(allocator);
    defer env.deinit();
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();
    const selector_list = try stringToSelectorList(input, &env, &arena);
    // defer selector_list.deinit(allocator);
    try expectEqualComplexSelectorLists(expected, selector_list.list);
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
}

test "complex selector matching" {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();
    const type_names = [5]Environment.NameId{
        try env.addTypeOrAttributeNameString("root"),
        try env.addTypeOrAttributeNameString("first"),
        try env.addTypeOrAttributeNameString("second"),
        try env.addTypeOrAttributeNameString("grandchild"),
        try env.addTypeOrAttributeNameString("third"),
    };

    var tree = ElementTree.init(allocator);
    defer tree.deinit();
    var elements: [6]ElementTree.Element = undefined;
    try tree.allocateElements(&elements);
    const slice = tree.slice();

    slice.initElement(elements[0], .normal, .orphan);
    slice.initElement(elements[1], .normal, .{ .last_child_of = elements[0] });
    slice.initElement(elements[2], .normal, .{ .last_child_of = elements[0] });
    slice.initElement(elements[3], .normal, .{ .first_child_of = elements[2] });
    slice.initElement(elements[4], .text, .{ .last_child_of = elements[0] });
    slice.initElement(elements[5], .normal, .{ .last_child_of = elements[0] });

    slice.set(.fq_type, elements[0], .{ .namespace = .none, .name = type_names[0] });
    slice.set(.fq_type, elements[1], .{ .namespace = .none, .name = type_names[1] });
    slice.set(.fq_type, elements[2], .{ .namespace = .none, .name = type_names[2] });
    slice.set(.fq_type, elements[3], .{ .namespace = .none, .name = type_names[3] });
    slice.set(.fq_type, elements[5], .{ .namespace = .none, .name = type_names[4] });

    const doTest = struct {
        fn f(selector_string: []const u8, en: *Environment, ar: *ArenaAllocator, s: ElementTree.Slice, e: ElementTree.Element) !bool {
            var selector = stringToSelectorList(selector_string, en, ar) catch |err| switch (err) {
                error.ParseError => return false,
                else => |er| return er,
            };
            // defer selector.deinit(allocator);
            return (selector.matchElement(s, e) != null);
        }
    }.f;
    const expect = std.testing.expect;

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    try expect(try doTest("root", &env, &arena, slice, elements[0]));
    try expect(try doTest("first", &env, &arena, slice, elements[1]));
    try expect(try doTest("root > first", &env, &arena, slice, elements[1]));
    try expect(try doTest("root first", &env, &arena, slice, elements[1]));
    try expect(try doTest("second", &env, &arena, slice, elements[2]));
    try expect(try doTest("first + second", &env, &arena, slice, elements[2]));
    try expect(try doTest("first ~ second", &env, &arena, slice, elements[2]));
    try expect(try doTest("third", &env, &arena, slice, elements[5]));
    try expect(try doTest("second + third", &env, &arena, slice, elements[5]));
    try expect(try doTest("second ~ third", &env, &arena, slice, elements[5]));
    try expect(!try doTest("first + third", &env, &arena, slice, elements[5]));
    try expect(try doTest("first ~ third", &env, &arena, slice, elements[5]));
    try expect(try doTest("grandchild", &env, &arena, slice, elements[3]));
    try expect(try doTest("second > grandchild", &env, &arena, slice, elements[3]));
    try expect(try doTest("second grandchild", &env, &arena, slice, elements[3]));
    try expect(try doTest("root grandchild", &env, &arena, slice, elements[3]));
    try expect(try doTest("root second grandchild", &env, &arena, slice, elements[3]));
    try expect(!try doTest("root > grandchild", &env, &arena, slice, elements[3]));
}
