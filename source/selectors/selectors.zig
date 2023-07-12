const zss = @import("../../zss.zig");
const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;
const NameId = Environment.NameId;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = zss.syntax.parse.Source;

const parse = @import("./parse.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ComplexSelectorList = struct {
    list: []ComplexSelector,

    pub fn deinit(complex_selector_list: *ComplexSelectorList, allocator: Allocator) void {
        for (complex_selector_list.list) |*complex_selector| complex_selector.deinit(allocator);
        allocator.free(complex_selector_list.list);
    }
};

pub const ComplexSelector = struct {
    compounds: []CompoundSelector,
    combinators: []Combinator,

    pub fn deinit(complex: *ComplexSelector, allocator: Allocator) void {
        for (complex.compounds) |*compound| compound.deinit(allocator);
        allocator.free(complex.compounds);
        allocator.free(complex.combinators);
    }
};

pub const Combinator = enum { descendant, child, next_sibling, subsequent_sibling, column };

pub const CompoundSelector = struct {
    type_selector: ?TypeSelector,
    subclasses: []SubclassSelector,
    pseudo_elements: []PseudoElement,

    pub fn deinit(compound: *CompoundSelector, allocator: Allocator) void {
        allocator.free(compound.subclasses);
        for (compound.pseudo_elements) |element| allocator.free(element.classes);
        allocator.free(compound.pseudo_elements);
    }
};

pub const PseudoElement = struct {
    name: ComponentTree.Size,
    classes: []ComponentTree.Size,
};

pub const TypeSelector = struct {
    namespace: NamespaceId,
    name: NameId,
};

pub const SubclassSelector = union(enum) {
    id: ComponentTree.Size,
    class: ComponentTree.Size,
    pseudo: ComponentTree.Size,
    attribute: AttributeSelector,
};

pub const AttributeSelector = struct {
    namespace: NamespaceId,
    name: NameId,
    complex: ?Complex,

    pub const Complex = struct {
        operator: Operator,
        /// The index of an <ident-token> or a <string-token>
        value: ComponentTree.Size,
        case: Case,
    };

    pub const Operator = enum { equals, list_contains, equals_or_prefix_dash, starts_with, ends_with, contains };

    pub const Case = enum { default, same_case, ignore_case };
};

pub fn parseSelectorList(
    env: *Environment,
    source: ParserSource,
    slice: ComponentTree.List.Slice,
    start: ComponentTree.Size,
    end: ComponentTree.Size,
) !?ComplexSelectorList {
    var parse_context = parse.Context.init(env, source, slice, end);
    const iterator = parse.Iterator.init(start);
    var selector_list = (try parse.complexSelectorList(&parse_context, iterator)) orelse return null;
    if (parse_context.finishParsing(selector_list[1])) {
        return selector_list[0];
    } else {
        selector_list[0].deinit(env.allocator);
        return null;
    }
}

const TestParseSelectorListExpected = []const struct {
    compounds: []const struct {
        type_selector: ?struct {
            namespace: NamespaceId.Value = NamespaceId.any.value,
            name: NameId.Value,
        } = null,
        subclasses: []const union(std.meta.Tag(SubclassSelector)) {
            id: ComponentTree.Size,
            class: ComponentTree.Size,
            pseudo: ComponentTree.Size,
            attribute: struct {
                namespace: NamespaceId.Value = NamespaceId.none.value,
                name: NameId.Value,
                complex: ?AttributeSelector.Complex = null,
            },
        } = &.{},
        pseudo_elements: []const struct {
            name: ComponentTree.Size,
            classes: []const ComponentTree.Size = &.{},
        } = &.{},
    } = &.{},
    combinators: []const Combinator = &.{},
};

fn expectEqualComplexSelectorLists(a: TestParseSelectorListExpected, b: []const ComplexSelector) !void {
    const expectEqual = std.testing.expectEqual;
    const expectEqualSlices = std.testing.expectEqualSlices;

    try expectEqual(a.len, b.len);
    for (a, b) |a_complex, b_complex| {
        try expectEqual(a_complex.compounds.len, b_complex.compounds.len);
        try expectEqualSlices(Combinator, a_complex.combinators, b_complex.combinators);

        for (a_complex.compounds, b_complex.compounds) |a_compound, b_compound| {
            try expectEqual(a_compound.type_selector == null, b_compound.type_selector == null);
            if (a_compound.type_selector != null) {
                try expectEqual(a_compound.type_selector.?.namespace, b_compound.type_selector.?.namespace.value);
                try expectEqual(a_compound.type_selector.?.name, b_compound.type_selector.?.name.value);
            }

            try expectEqual(a_compound.subclasses.len, b_compound.subclasses.len);
            for (a_compound.subclasses, b_compound.subclasses) |a_sub, b_sub| {
                const Tag = std.meta.Tag(SubclassSelector);
                try expectEqual(@as(Tag, a_sub), @as(Tag, b_sub));
                switch (a_sub) {
                    .id => try expectEqual(a_sub.id, b_sub.id),
                    .class => try expectEqual(a_sub.class, b_sub.class),
                    .pseudo => try expectEqual(a_sub.pseudo, b_sub.pseudo),
                    .attribute => {
                        try expectEqual(a_sub.attribute.namespace, b_sub.attribute.namespace.value);
                        try expectEqual(a_sub.attribute.name, b_sub.attribute.name.value);
                        try expectEqual(a_sub.attribute.complex, b_sub.attribute.complex);
                    },
                }
            }

            try expectEqual(a_compound.pseudo_elements.len, b_compound.pseudo_elements.len);
            for (a_compound.pseudo_elements, b_compound.pseudo_elements) |a_pseudo, b_pseudo| {
                try expectEqual(a_pseudo.name, b_pseudo.name);
                try expectEqualSlices(ComponentTree.Size, a_pseudo.classes, b_pseudo.classes);
            }
        }
    }
}

fn testParseSelectorList(input: []const u7, expected: TestParseSelectorListExpected) !void {
    const allocator = std.testing.allocator;
    var env = Environment.init(allocator);
    defer env.deinit();

    const source = ParserSource.init(try zss.syntax.tokenize.Source.init(input));
    var tree = try zss.syntax.parse.parseListOfComponentValues(source, allocator);
    defer tree.deinit(allocator);
    const slice = tree.components.slice();
    std.debug.assert(slice.items(.tag)[0] == .component_list);
    const start: ComponentTree.Size = 0 + 1;
    const end: ComponentTree.Size = slice.items(.next_sibling)[0];

    var selector_list = (try parseSelectorList(&env, source, slice, start, end)) orelse return error.TestFailure;
    defer selector_list.deinit(allocator);
    try expectEqualComplexSelectorLists(expected, selector_list.list);
}

test "parsing selector lists" {
    const a = zss.util.ascii8ToAscii7;
    try testParseSelectorList(a("element-name"), &.{
        .{
            .compounds = &.{
                .{ .type_selector = .{ .name = 0 } },
            },
        },
    });
    try testParseSelectorList(a("h1[size]"), &.{
        .{
            .compounds = &.{
                .{
                    .type_selector = .{ .name = 0 },
                    .subclasses = &.{
                        .{ .attribute = .{ .name = 1 } },
                    },
                },
            },
        },
    });
    try testParseSelectorList(a("h1 h2 > h3"), &.{
        .{
            .combinators = &.{ .descendant, .child },
            .compounds = &.{
                .{ .type_selector = .{ .name = 0 } },
                .{ .type_selector = .{ .name = 1 } },
                .{ .type_selector = .{ .name = 2 } },
            },
        },
    });
}

pub const debug = struct {
    pub fn printComplexSelectorList(complex_selector_list: ComplexSelectorList, writer: anytype) !void {
        for (complex_selector_list.list, 0..) |complex_selector, i| {
            try printComplexSelector(complex_selector, writer);
            if (i + 1 < complex_selector_list.list.len) try writer.writeAll(", ");
        }
    }

    pub fn printComplexSelector(complex: ComplexSelector, writer: anytype) !void {
        try printCompoundSelector(complex.compounds[0], writer);
        for (complex.combinators, complex.compounds[1..]) |com, compound| {
            const com_string = switch (com) {
                .descendant => " ",
                .child => " > ",
                .next_sibling => " + ",
                .subsequent_sibling => " ~ ",
                .column => " || ",
            };
            try writer.writeAll(com_string);
            try printCompoundSelector(compound, writer);
        }
    }

    pub fn printCompoundSelector(c: CompoundSelector, writer: anytype) !void {
        if (c.type_selector) |ts| {
            if (ts.namespace.value == NamespaceId.any.value) {
                try writer.writeAll("*");
            } else if (ts.namespace.value != NamespaceId.none.value) {
                try writer.print("{}", .{ts.namespace.value});
            }
            if (ts.name.value == NamespaceId.any.value) {
                try writer.writeAll("|*");
            } else {
                try writer.print("|{}", .{ts.name.value});
            }
        }

        for (c.subclasses) |sub| {
            switch (sub) {
                .id => try writer.print("#{}", .{sub.id}),
                .class => try writer.print(".{}", .{sub.class}),
                .pseudo => try writer.print(":{}", .{sub.pseudo}),
                .attribute => |at| {
                    if (at.namespace.value == NamespaceId.any.value) {
                        try writer.writeAll("[*");
                    } else if (at.namespace.value == NamespaceId.none.value) {
                        try writer.writeAll("[");
                    } else {
                        try writer.print("[{}", .{at.namespace.value});
                    }
                    try writer.print("|{}", .{at.name.value});
                    if (at.complex) |complex| {
                        const operator = switch (complex.operator) {
                            .equals => "=",
                            .list_contains => "~=",
                            .equals_or_prefix_dash => "|=",
                            .starts_with => "^=",
                            .ends_with => "$=",
                            .contains => "*=",
                        };
                        const case = switch (complex.case) {
                            .default => "",
                            .same_case => " s",
                            .ignore_case => " i",
                        };
                        try writer.print(" {s} {}{s}]", .{ operator, complex.value, case });
                    } else {
                        try writer.writeAll("]");
                    }
                },
            }
        }

        for (c.pseudo_elements) |elem| {
            try writer.print("::{}", .{elem.name});
            for (elem.classes) |class| {
                try writer.print(":{}", .{class});
            }
        }
    }
};
