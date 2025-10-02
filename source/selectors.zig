const zss = @import("zss.zig");
const Ast = zss.syntax.Ast;
const Stylesheet = zss.Stylesheet;
const TokenSource = zss.syntax.TokenSource;

const Environment = zss.Environment;
const AttributeName = Environment.AttributeName;
const AttributeValueId = Environment.AttributeValueId;
const ClassName = Environment.ClassName;
const ElementAttribute = Environment.ElementAttribute;
const ElementType = Environment.ElementType;
const IdName = Environment.IdName;
const NamespaceId = Environment.Namespaces.Id;
const NodeId = Environment.NodeId;
const TypeName = Environment.TypeName;

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const MultiArrayList = std.MultiArrayList;

pub const Parser = @import("selectors/parse.zig").Parser;

/// A data component of a complex selector.
/// Every complex selector is represented as a list of this data type.
///
/// When you have a list of this type, it should be laid out as follows:
/// <list> = [ `next_complex_selector` <complex-selector> ]*
/// <complex-selector> = [ <compound-selector> `trailing` ]+
/// <compound-selector> = [ `simple_selector_tag` <simple-selector> ]+
/// <simple-selector> = <variable data, depending on the previous `simple_selector_tag`>
pub const Data = union {
    /// The index of the start of the next complex selector.
    /// If this is the last complex selector within the data list, then this just points to the end of the data list.
    next_complex_selector: ListIndex,
    /// Found after every compound selector.
    trailing: Trailing,
    simple_selector_tag: SimpleSelectorTag,
    type_selector: ElementType,
    id_selector: IdName,
    class_selector: ClassName,
    attribute_selector: ElementAttribute,
    attribute_selector_value: AttributeValueId,
    pseudo_class_selector: PseudoClass,
    pseudo_element_selector: PseudoElement,

    pub const ListIndex = u24;

    // TODO: Make this an extern struct to avoid issues with undefined values within packed types.
    pub const Trailing = packed struct {
        /// The combinator applied to this compound selector (the left-hand side) and the compound selector after it (the right-hand side).
        /// If this is the last compound selector in a complex selector, this field is undefined and should not be used.
        combinator: Combinator,
        /// The index of the start of this compound selector (i.e. the first `simple_selector_tag` within this compound).
        compound_selector_start: ListIndex,
    };

    // TODO: Put payloads into this union, fit it all into 4 bytes
    pub const SimpleSelectorTag = union(enum) {
        /// The next Data is a `type_selector`
        type,
        /// The next Data is a `id_selector`
        id,
        /// The next Data is a `class_selector`
        class,
        /// The next Data is a `attribute_selector`
        /// If non-null, then there is also an `attribute_selector_value` following the `attribute_selector`
        attribute: ?AttributeOperatorCase,
        /// The next Data is a `pseudo_class_selector`
        pseudo_class,
        /// The next Data is a `pseudo_element_selector`
        pseudo_element,
    };

    pub const AttributeOperatorCase = struct {
        operator: AttributeOperator,
        case: AttributeCase,
    };
};

comptime {
    if (!zss.debug.runtime_safety) assert(@sizeOf(Data) == 4);
}

pub const Combinator = enum(u8) { descendant, child, next_sibling, subsequent_sibling, column };

pub const PseudoElement = enum { unrecognized }; // TODO: Support more pseudo elements

pub const PseudoClass = enum { root, unrecognized }; // TODO: Support more pseudo classes

pub const AttributeOperator = enum { equals, list_contains, equals_or_prefix_dash, starts_with, ends_with, contains };

pub const AttributeCase = enum { default, same_case, ignore_case };

/// Represents the specificity of a complex selector.
// TODO: Make this a normal struct
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

/// Returns `true` if the complex selector matches `match_candidate`.
/// Asserts that `match_candidate` is an element node.
pub fn matchElement(
    data: []const Data,
    complex_selector_index: Data.ListIndex,
    env: *const Environment,
    match_candidate: NodeId,
) bool {
    switch (env.getNodeProperty(.category, match_candidate)) {
        .element => {},
        .text => unreachable,
    }

    const last_trailing = data[complex_selector_index].next_complex_selector - 1;
    return matchComplexSelector(data, complex_selector_index + 1, last_trailing, env, match_candidate);
}

fn matchComplexSelector(
    data: []const Data,
    first_compound: Data.ListIndex,
    last_trailing: Data.ListIndex,
    env: *const Environment,
    match_candidate: NodeId,
) bool {
    var trailing_index = last_trailing;
    var trailing = data[trailing_index].trailing;
    var element: ?NodeId = match_candidate;
    if (!matchCompoundSelector(data, trailing.compound_selector_start, trailing_index, env, element.?)) return false;
    compound_loop: while (trailing.compound_selector_start != first_compound) {
        trailing_index = trailing.compound_selector_start - 1;
        trailing = data[trailing_index].trailing;
        switch (trailing.combinator) {
            .descendant => {
                element = element.?.parent(env);
                while (element) |e| : (element = e.parent(env)) {
                    switch (env.getNodeProperty(.category, e)) {
                        .element => {},
                        .text => unreachable,
                    }
                    if (matchCompoundSelector(data, trailing.compound_selector_start, trailing_index, env, e)) continue :compound_loop;
                } else return false;
            },
            .child => {
                element = element.?.parent(env);
                while (element) |e| : (element = e.parent(env)) {
                    switch (env.getNodeProperty(.category, e)) {
                        .element => break,
                        .text => unreachable,
                    }
                } else return false;
                if (matchCompoundSelector(data, trailing.compound_selector_start, trailing_index, env, element.?)) continue :compound_loop;
                return false;
            },
            .subsequent_sibling => {
                element = element.?.previousSibling(env);
                while (element) |e| : (element = e.previousSibling(env)) {
                    switch (env.getNodeProperty(.category, e)) {
                        .element => {
                            if (matchCompoundSelector(data, trailing.compound_selector_start, trailing_index, env, e)) continue :compound_loop;
                        },
                        .text => {},
                    }
                }
            },
            .next_sibling => {
                element = element.?.previousSibling(env);
                while (element) |e| : (element = e.previousSibling(env)) {
                    switch (env.getNodeProperty(.category, e)) {
                        .element => break,
                        .text => {},
                    }
                } else return false;
                if (matchCompoundSelector(data, trailing.compound_selector_start, trailing_index, env, element.?)) continue :compound_loop;
                return false;
            },
            .column => panic("TODO: Unsupported selector combinator: {s}\n", .{@tagName(trailing.combinator)}),
        }
    }
    return true;
}

fn matchCompoundSelector(
    data: []const Data,
    start: Data.ListIndex,
    end: Data.ListIndex,
    env: *const Environment,
    element: NodeId,
) bool {
    var index = start;
    while (index < end) : (index += 1) {
        switch (data[index].simple_selector_tag) {
            .type => {
                index += 1;
                const selector_type = data[index].type_selector;
                const element_type = env.getNodeProperty(.type, element);
                if (!matchTypeSelector(selector_type, element_type)) return false;
            },
            .id => {
                index += 1;
                const id = data[index].id_selector;
                const element_with_id = env.getElementById(id) orelse return false;
                if (element != element_with_id) return false;
            },
            .class,
            .attribute,
            => panic("TODO: Unsupported simple selector: {s}", .{@tagName(data[index].simple_selector_tag)}),
            .pseudo_class => {
                index += 1;
                const pseudo_class = data[index].pseudo_class_selector;
                switch (pseudo_class) {
                    .root => {
                        if (element != env.root_node) return false;
                    },
                    .unrecognized => return false,
                }
            },
            .pseudo_element => {
                index += 1;
                const pseudo_element = data[index].pseudo_element_selector;
                switch (pseudo_element) {
                    .unrecognized => return false,
                }
            },
        }
    }
    return true;
}

fn matchTypeSelector(selector_type: ElementType, element_type: ElementType) bool {
    assert(element_type.namespace != .any);
    assert(element_type.name != .any);

    switch (selector_type.namespace) {
        .any => {},
        else => if (selector_type.namespace != element_type.namespace) return false,
    }

    switch (selector_type.name) {
        .any => {},
        .anonymous => return false,
        _ => if (selector_type.name != element_type.name) return false,
    }

    return true;
}

test "matching type selectors" {
    const some_namespace = @as(NamespaceId, @enumFromInt(24));
    const some_name = @as(TypeName, @enumFromInt(42));

    const e1 = ElementType{ .namespace = .none, .name = .anonymous };
    const e2 = ElementType{ .namespace = .none, .name = some_name };
    const e3 = ElementType{ .namespace = some_namespace, .name = .anonymous };
    const e4 = ElementType{ .namespace = some_namespace, .name = some_name };

    const expect = std.testing.expect;
    const matches = matchTypeSelector;

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
                name: TypeName,
            } = null,
            subclasses: []const union(enum) {
                id: IdName,
                class: ClassName,
                pseudo_class: PseudoClass,
                attribute: struct {
                    namespace: NamespaceId = .none,
                    name: AttributeName,
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

fn expectEqualComplexSelectorLists(expected: TestParseSelectorListExpected, data: []const Data, num_actual: Data.ListIndex) !void {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(expected.len, num_actual);
    var index_of_complex: Data.ListIndex = 0;
    for (expected) |expected_complex| {
        var index = index_of_complex + 1;
        index_of_complex = data[index_of_complex].next_complex_selector;

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
                _ = data[index].simple_selector_tag;
                index += 1;
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

    try expectEqual(data.len, index_of_complex);
}

fn stringToSelectorList(input: []const u8, env: *Environment, allocator: Allocator, data_list: *std.ArrayList(Data)) !Data.ListIndex {
    const source = try TokenSource.init(input);

    var ast, const component_list_index = blk: {
        var parser = zss.syntax.Parser.init(source, env.allocator);
        defer parser.deinit();
        break :blk try parser.parseListOfComponentValues(env.allocator);
    };
    defer ast.deinit(env.allocator);

    var parser = Parser.init(env, allocator, source, ast, &.{});
    defer parser.deinit();

    try parser.parseComplexSelectorList(data_list, allocator, component_list_index.children(ast));
    return @intCast(parser.specificities.items.len);
}

fn testParseSelectorList(input: []const u8, expected: TestParseSelectorListExpected) !void {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator, .temp_default, .no_quirks);
    defer env.deinit();

    var data_list = std.ArrayList(Data){};
    defer data_list.deinit(allocator);

    const num_selectors = try stringToSelectorList(input, &env, allocator, &data_list);
    try expectEqualComplexSelectorLists(expected, data_list.items, num_selectors);
}

test "parsing selector lists" {
    const n = struct {
        fn f(x: u24) TypeName {
            return @as(TypeName, @enumFromInt(x));
        }
    }.f;
    const en = struct {
        fn f(x: u24) AttributeName {
            return @as(AttributeName, @enumFromInt(x));
        }
    }.f;
    const i = struct {
        fn f(x: u24) IdName {
            return @as(IdName, @enumFromInt(x));
        }
    }.f;
    const c = struct {
        fn f(x: u24) ClassName {
            return @as(ClassName, @enumFromInt(x));
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
                    .{ .attribute = .{ .name = en(0) } },
                    .{ .class = c(0) },
                    .{ .id = i(0) },
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

    var env = Environment.init(allocator, .temp_default, .no_quirks);
    defer env.deinit();

    const token_source = try zss.syntax.TokenSource.init(
        \\root #alice {
        \\  first {}
        \\  second {
        \\    grandchild {}
        \\  }
        \\  ""
        \\  third #bob {}
        \\}
    );
    var document = try zss.zml.createDocumentFromTokenSource(allocator, token_source, &env);
    defer document.deinit(allocator);
    document.setEnvTreeInterface(&env);

    const nodes = blk: {
        const root = document.rootZssNode().?;
        const first = root.firstChild(&env).?;
        const second = first.nextSibling(&env).?;
        const grandchild = second.firstChild(&env).?;
        const third = second.nextSibling(&env).?.nextSibling(&env).?;
        break :blk .{ .root = root, .first = first, .second = second, .grandchild = grandchild, .third = third };
    };

    const doTest = struct {
        fn f(selector_string: []const u8, en: *Environment, ar: *ArenaAllocator, n: Environment.NodeId) !bool {
            var data_list: std.ArrayList(Data) = .empty;
            const complex_start: Data.ListIndex = @intCast(data_list.items.len);
            const num_selectors = stringToSelectorList(selector_string, en, ar.allocator(), &data_list) catch |err| switch (err) {
                error.ParseError => return false,
                else => |er| return er,
            };
            assert(num_selectors == 1);
            return matchElement(data_list.items, complex_start, en, n);
        }
    }.f;
    const expect = std.testing.expect;

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    // zig fmt: off
    try expect(try doTest("root"                  , &env, &arena, nodes.root));
    try expect(try doTest(":root"                 , &env, &arena, nodes.root));
    try expect(try doTest("first"                 , &env, &arena, nodes.first));
    try expect(try doTest("root > first"          , &env, &arena, nodes.first));
    try expect(try doTest("root first"            , &env, &arena, nodes.first));
    try expect(try doTest("second"                , &env, &arena, nodes.second));
    try expect(try doTest("first + second"        , &env, &arena, nodes.second));
    try expect(try doTest("first ~ second"        , &env, &arena, nodes.second));
    try expect(try doTest("third"                 , &env, &arena, nodes.third));
    try expect(try doTest("second + third"        , &env, &arena, nodes.third));
    try expect(try doTest("second ~ third"        , &env, &arena, nodes.third));
    try expect(!try doTest("first + third"        , &env, &arena, nodes.third));
    try expect(try doTest("first ~ third"         , &env, &arena, nodes.third));
    try expect(try doTest("grandchild"            , &env, &arena, nodes.grandchild));
    try expect(try doTest("second > grandchild"   , &env, &arena, nodes.grandchild));
    try expect(try doTest("second grandchild"     , &env, &arena, nodes.grandchild));
    try expect(try doTest("root grandchild"       , &env, &arena, nodes.grandchild));
    try expect(try doTest("root second grandchild", &env, &arena, nodes.grandchild));
    try expect(!try doTest("root > grandchild"    , &env, &arena, nodes.grandchild));
    try expect(try doTest("#alice"                , &env, &arena, nodes.root));
    try expect(!try doTest("#alice"               , &env, &arena, nodes.third));
    try expect(try doTest("#alice > #bob"         , &env, &arena, nodes.third));
    // zig fmt: on
}

// TODO: Make a fuzz test
