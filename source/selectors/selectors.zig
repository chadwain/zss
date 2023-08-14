const zss = @import("../../zss.zig");
const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;
const NameId = Environment.NameId;
const IdId = Environment.IdId;
const ClassId = Environment.ClassId;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = zss.syntax.parse.Source;

const parse = @import("./parse.zig");

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;

/// Represents the specificity of a complex selector.
pub const Specificity = struct {
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
        @field(specificity, field_name) +|= 1;
    }

    pub fn order(lhs: Specificity, rhs: Specificity) std.math.Order {
        const ord = std.math.order;
        return switch (ord(lhs.a, .rhs.a)) {
            .lt => .lt,
            .gt => .gt,
            .eq => switch (ord(lhs.b, rhs.b)) {
                .lt => .lt,
                .gt => .gt,
                .eq => ord(lhs.c, rhs.c),
            },
        };
    }
};

pub const ComplexSelectorList = struct {
    list: []ComplexSelectorFull,

    pub fn deinit(complex_selector_list: *ComplexSelectorList, allocator: Allocator) void {
        for (complex_selector_list.list) |*full| full.deinit(allocator);
        allocator.free(complex_selector_list.list);
    }

    pub fn matchElement(sel: ComplexSelectorList, slice: ElementTree.Slice, element: Element) bool {
        for (sel.list) |complex| {
            if (complex.matchElement(slice, element)) return true;
        }
        return false;
    }
};

pub const ComplexSelectorFull = struct {
    selector: ComplexSelector,
    specificity: Specificity,

    pub fn deinit(full: *ComplexSelectorFull, allocator: Allocator) void {
        full.selector.deinit(allocator);
    }

    pub fn matchElement(sel: ComplexSelectorFull, slice: ElementTree.Slice, element: Element) bool {
        return sel.selector.matchElement(slice, element);
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

    fn matchElement(sel: ComplexSelector, slice: ElementTree.Slice, element: Element) bool {
        if (sel.compounds.len > 1) panic("TODO: More than 1 compound selector in a complex selector", .{});
        for (0..sel.compounds.len) |i| {
            const compound = sel.compounds[sel.compounds.len - 1 - i];
            if (compound.matchElement(slice, element)) return true;
        }
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

    fn matchElement(sel: CompoundSelector, slice: ElementTree.Slice, element: Element) bool {
        if (sel.type_selector) |type_selector| {
            const element_type = slice.get(.type, element);
            if (!type_selector.matches(element_type)) return false;
        }
        if (sel.subclasses.len > 0) panic("TODO: Subclass selectors in a compound selector", .{});
        if (sel.pseudo_elements.len > 0) panic("TODO: Pseudo element selectors in a compound selector", .{});
        return true;
    }
};

pub const PseudoElement = struct {
    name: PseudoName,
    classes: []PseudoName,
};

pub const TypeSelector = struct {
    namespace: NamespaceId,
    name: NameId,

    fn matches(selector: TypeSelector, element_type: ElementTree.Type) bool {
        assert(element_type.namespace != .any);
        assert(element_type.name != .any);

        switch (selector.namespace) {
            .any => {},
            else => if (selector.namespace != element_type.namespace) return false,
        }

        switch (selector.name) {
            .any => {},
            .unspecified => return false,
            _ => if (selector.name != element_type.name) return false,
        }

        return true;
    }
};

test "matching type selectors" {
    const some_namespace = @intToEnum(NamespaceId, 24);
    const some_name = @intToEnum(NameId, 42);

    const e1 = ElementTree.Type{ .namespace = .none, .name = .unspecified };
    const e2 = ElementTree.Type{ .namespace = .none, .name = some_name };
    const e3 = ElementTree.Type{ .namespace = some_namespace, .name = .unspecified };
    const e4 = ElementTree.Type{ .namespace = some_namespace, .name = some_name };

    const expect = std.testing.expect;
    const matches = TypeSelector.matches;

    try expect(matches(.{ .namespace = .any, .name = .any }, e1));
    try expect(matches(.{ .namespace = .any, .name = .any }, e2));
    try expect(matches(.{ .namespace = .any, .name = .any }, e3));
    try expect(matches(.{ .namespace = .any, .name = .any }, e4));

    try expect(!matches(.{ .namespace = .any, .name = .unspecified }, e1));
    try expect(!matches(.{ .namespace = .any, .name = .unspecified }, e2));
    try expect(!matches(.{ .namespace = .any, .name = .unspecified }, e3));
    try expect(!matches(.{ .namespace = .any, .name = .unspecified }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = .any }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = .any }, e2));
    try expect(matches(.{ .namespace = some_namespace, .name = .any }, e3));
    try expect(matches(.{ .namespace = some_namespace, .name = .any }, e4));

    try expect(!matches(.{ .namespace = .any, .name = some_name }, e1));
    try expect(matches(.{ .namespace = .any, .name = some_name }, e2));
    try expect(!matches(.{ .namespace = .any, .name = some_name }, e3));
    try expect(matches(.{ .namespace = .any, .name = some_name }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = .unspecified }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = .unspecified }, e2));
    try expect(!matches(.{ .namespace = some_namespace, .name = .unspecified }, e3));
    try expect(!matches(.{ .namespace = some_namespace, .name = .unspecified }, e4));

    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e1));
    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e2));
    try expect(!matches(.{ .namespace = some_namespace, .name = some_name }, e3));
    try expect(matches(.{ .namespace = some_namespace, .name = some_name }, e4));
}

pub const SubclassSelector = union(enum) {
    id: IdId,
    class: ClassId,
    pseudo: PseudoName,
    attribute: AttributeSelector,
};

pub const PseudoName = enum(u1) { unrecognized };

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
            namespace: NamespaceId = .any,
            name: NameId,
        } = null,
        subclasses: []const union(std.meta.Tag(SubclassSelector)) {
            id: IdId,
            class: ClassId,
            pseudo: PseudoName,
            attribute: struct {
                namespace: NamespaceId = .none,
                name: NameId,
                complex: ?AttributeSelector.Complex = null,
            },
        } = &.{},
        pseudo_elements: []const struct {
            name: PseudoName,
            classes: []const PseudoName = &.{},
        } = &.{},
    } = &.{},
    combinators: []const Combinator = &.{},
};

fn expectEqualComplexSelectorLists(a: TestParseSelectorListExpected, b: []const ComplexSelectorFull) !void {
    const expectEqual = std.testing.expectEqual;
    const expectEqualSlices = std.testing.expectEqualSlices;

    try expectEqual(a.len, b.len);
    for (a, b) |a_complex, b_full| {
        const b_complex = b_full.selector;
        try expectEqual(a_complex.compounds.len, b_complex.compounds.len);
        try expectEqualSlices(Combinator, a_complex.combinators, b_complex.combinators);

        for (a_complex.compounds, b_complex.compounds) |a_compound, b_compound| {
            try expectEqual(a_compound.type_selector == null, b_compound.type_selector == null);
            if (a_compound.type_selector != null) {
                try expectEqual(a_compound.type_selector.?.namespace, b_compound.type_selector.?.namespace);
                try expectEqual(a_compound.type_selector.?.name, b_compound.type_selector.?.name);
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
                        try expectEqual(a_sub.attribute.namespace, b_sub.attribute.namespace);
                        try expectEqual(a_sub.attribute.name, b_sub.attribute.name);
                        try expectEqual(a_sub.attribute.complex, b_sub.attribute.complex);
                    },
                }
            }

            try expectEqual(a_compound.pseudo_elements.len, b_compound.pseudo_elements.len);
            for (a_compound.pseudo_elements, b_compound.pseudo_elements) |a_pseudo, b_pseudo| {
                try expectEqual(a_pseudo.name, b_pseudo.name);
                try expectEqualSlices(PseudoName, a_pseudo.classes, b_pseudo.classes);
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
    const n = struct {
        fn f(x: u24) NameId {
            return @intToEnum(NameId, x);
        }
    }.f;
    const i = struct {
        fn f(x: u24) IdId {
            return @intToEnum(IdId, x);
        }
    }.f;
    const c = struct {
        fn f(x: u24) ClassId {
            return @intToEnum(ClassId, x);
        }
    }.f;

    try testParseSelectorList(a("element-name"), &.{
        .{
            .compounds = &.{
                .{ .type_selector = .{ .name = n(0) } },
            },
        },
    });
    try testParseSelectorList(a("h1[size].class#my-id"), &.{
        .{
            .compounds = &.{
                .{
                    .type_selector = .{ .name = n(0) },
                    .subclasses = &.{
                        .{ .attribute = .{ .name = n(1) } },
                        .{ .class = c(0) },
                        .{ .id = i(1) },
                    },
                },
            },
        },
    });
    try testParseSelectorList(a("h1 h2 > h3"), &.{
        .{
            .combinators = &.{ .descendant, .child },
            .compounds = &.{
                .{ .type_selector = .{ .name = n(0) } },
                .{ .type_selector = .{ .name = n(1) } },
                .{ .type_selector = .{ .name = n(2) } },
            },
        },
    });
    try testParseSelectorList(a("*"), &.{.{
        .compounds = &.{
            .{ .type_selector = .{ .name = .any } },
        },
    }});
    try testParseSelectorList(a("\\*"), &.{.{
        .compounds = &.{
            .{ .type_selector = .{ .name = n(0) } },
        },
    }});
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
            switch (ts.namespace) {
                .any => try writer.writeAll("*|"),
                .none => {},
                _ => try writer.print("{}|", .{@enumToInt(ts.namespace)}),
            }
            switch (ts.name) {
                .any => try writer.writeAll("*"),
                else => try writer.print("{}", .{@enumToInt(ts.name)}),
            }
        }

        for (c.subclasses) |sub| {
            switch (sub) {
                .id => try writer.print("#{}", .{sub.id}),
                .class => try writer.print(".{}", .{sub.class}),
                .pseudo => try writer.print(":{s}", .{@tagName(sub.pseudo)}),
                .attribute => |at| {
                    switch (at.namespace) {
                        .any => try writer.writeAll("[*|"),
                        .none => try writer.writeAll("["),
                        _ => try writer.print("[{}|", .{@enumToInt(at.namespace)}),
                    }
                    switch (at.name) {
                        .any => unreachable,
                        else => try writer.print("{}", .{@enumToInt(at.name)}),
                    }
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
                try writer.print(":{s}", .{@tagName(class)});
            }
        }
    }
};
