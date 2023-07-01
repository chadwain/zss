const zss = @import("../../zss.zig");
const syntax = zss.syntax;
const Component = zss.syntax.Component;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = syntax.parse.Source;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Context = struct {
    source: ParserSource,
    slice: ComponentTree.List.Slice,

    const Next = struct {
        index: ComponentTree.Size,
        tag: Component.Tag,
        location: ParserSource.Location,
        extra: Component.Extra,
        next_it: Iterator,
    };

    fn next(context: Context, it: Iterator) ?Next {
        const tags = context.slice.items(.tag);
        const next_siblings = context.slice.items(.next_sibling);

        var index = it.index;
        while (index < it.end) {
            const tag = tags[index];
            const next_index = next_siblings[index];
            switch (tag) {
                .token_whitespace => index = next_index,
                else => return .{
                    .index = index,
                    .tag = tag,
                    .location = context.slice.items(.location)[index],
                    .extra = context.slice.items(.extra)[index],
                    .next_it = .{ .index = next_index, .end = it.end },
                },
            }
        }

        return null;
    }

    fn nextNoWhitespace(context: Context, it: Iterator) ?Next {
        if (it.index < it.end) {
            const tag = context.slice.items(.tag)[it.index];
            switch (tag) {
                .token_whitespace => return null,
                else => return .{
                    .index = it.index,
                    .tag = tag,
                    .location = context.slice.items(.location)[it.index],
                    .extra = context.slice.items(.extra)[it.index],
                    .next_it = .{ .index = context.slice.items(.next_sibling)[it.index], .end = it.end },
                },
            }
        }

        return null;
    }

    fn nextIsWhitespace(context: Context, it: Iterator) bool {
        if (it.index < it.end) {
            return context.slice.items(.tag)[it.index] == .token_whitespace;
        } else {
            return false;
        }
    }

    fn consumeWhitespace(context: Context, it: Iterator) Iterator {
        const tags = context.slice.items(.tag);
        const next_siblings = context.slice.items(.next_sibling);

        var index = it.index;
        while (index < it.end) {
            const tag = tags[index];
            if (tag == .token_whitespace) {
                index = next_siblings[index];
            } else {
                break;
            }
        }
        return Iterator.init(index, it.end);
    }

    fn finishParsing(context: Context, it: Iterator) bool {
        return context.next(it) == null;
    }

    fn matchKeyword(context: Context, location: ParserSource.Location, string: []const u21) bool {
        return context.source.matchKeyword(location, string);
    }
};

const Iterator = struct {
    index: ComponentTree.Size,
    end: ComponentTree.Size,

    fn init(start: ComponentTree.Size, end: ComponentTree.Size) Iterator {
        return .{ .index = start, .end = end };
    }
};

fn Pair(comptime First: type) type {
    return std.meta.Tuple(&[2]type{ First, Iterator });
}

const Selectors = struct {
    list: []ComplexSelector,

    fn deinit(selectors: *Selectors, allocator: Allocator) void {
        for (selectors.list) |*complex_selector| complex_selector.deinit(allocator);
        allocator.free(selectors.list);
    }
};

fn complexSelectorList(context: Context, start: Iterator, allocator: Allocator) !?Pair(Selectors) {
    var list = ArrayListUnmanaged(ComplexSelector){};
    defer list.deinit(allocator);

    var it = start;
    var expecting_comma = false;
    while (true) {
        if (expecting_comma) {
            const comma = context.next(it) orelse break;
            if (comma.tag != .token_comma) break;
            it = comma.next_it;
            expecting_comma = false;
        } else {
            try list.ensureUnusedCapacity(allocator, 1);
            const complex_selector = (try complexSelector(context, it, allocator)) orelse break;
            list.appendAssumeCapacity(complex_selector[0]);
            it = complex_selector[1];
            expecting_comma = true;
        }
    }

    if (list.items.len == 0) {
        return null;
    } else {
        const owned = try list.toOwnedSlice(allocator);
        return .{ Selectors{ .list = owned }, it };
    }
}

const ComplexSelector = struct {
    compounds: []CompoundSelector,
    combinators: []Combinator,

    fn deinit(complex: *ComplexSelector, allocator: Allocator) void {
        for (complex.compounds) |*compound| compound.deinit(allocator);
        allocator.free(complex.compounds);
        allocator.free(complex.combinators);
    }
};

fn complexSelector(context: Context, start: Iterator, allocator: Allocator) !?Pair(ComplexSelector) {
    var it = start;

    var compounds = ArrayListUnmanaged(CompoundSelector){};
    defer {
        for (compounds.items) |*compound| compound.deinit(allocator);
        compounds.deinit(allocator);
    }
    var combinators = ArrayListUnmanaged(Combinator){};
    defer combinators.deinit(allocator);

    {
        try compounds.ensureUnusedCapacity(allocator, 1);
        const compound = (try compoundSelector(context, it, allocator)) orelse return null;
        compounds.appendAssumeCapacity(compound[0]);
        it = compound[1];
    }

    while (true) {
        const com = combinator(context, it) orelse break;

        try compounds.ensureUnusedCapacity(allocator, 1);
        const compound = (try compoundSelector(context, com[1], allocator)) orelse break;

        compounds.appendAssumeCapacity(compound[0]);
        try combinators.append(allocator, com[0]);
        it = compound[1];
    }

    const combinators_owned = try combinators.toOwnedSlice(allocator);
    errdefer allocator.free(combinators_owned);
    const compounds_owned = try compounds.toOwnedSlice(allocator);
    return .{
        ComplexSelector{ .compounds = compounds_owned, .combinators = combinators_owned },
        it,
    };
}

const Combinator = enum { descendant, child, next_sibling, subsequent_sibling, column };

fn combinator(context: Context, it: Iterator) ?Pair(Combinator) {
    blk: {
        const component = context.next(it) orelse break :blk;
        if (component.tag != .token_delim) break :blk;

        var result: Combinator = undefined;
        var after_combinator: Iterator = undefined;
        switch (component.extra.codepoint()) {
            '>' => {
                result = .child;
                after_combinator = component.next_it;
            },
            '+' => {
                result = .next_sibling;
                after_combinator = component.next_it;
            },
            '~' => {
                result = .subsequent_sibling;
                after_combinator = component.next_it;
            },
            '|' => {
                const second_pipe = context.nextNoWhitespace(component.next_it) orelse break :blk;
                if (!(second_pipe.tag == .token_delim and second_pipe.extra.codepoint() == '|')) break :blk;
                result = .column;
                after_combinator = second_pipe.next_it;
            },
            else => break :blk,
        }

        return .{ result, after_combinator };
    }

    if (context.nextIsWhitespace(it)) {
        return .{ .descendant, context.consumeWhitespace(it) };
    } else {
        return null;
    }
}

const CompoundSelector = struct {
    type_selector: ?TypeSelector,
    subclasses: []SubclassSelector,
    pseudo_elements: []PseudoElement,

    fn deinit(compound: *CompoundSelector, allocator: Allocator) void {
        allocator.free(compound.subclasses);
        for (compound.pseudo_elements) |element| allocator.free(element.classes);
        allocator.free(compound.pseudo_elements);
    }
};

const PseudoElement = struct {
    name: ComponentTree.Size,
    classes: []ComponentTree.Size,
};

fn compoundSelector(context: Context, start: Iterator, allocator: Allocator) !?Pair(CompoundSelector) {
    var it = context.consumeWhitespace(start);

    var type_selector: ?TypeSelector = undefined;
    if (typeSelector(context, it)) |result| {
        type_selector = result[0];
        it = result[1];
    } else {
        type_selector = null;
    }

    var subclasses = ArrayListUnmanaged(SubclassSelector){};
    defer subclasses.deinit(allocator);
    while (true) {
        if (context.nextIsWhitespace(it)) break;
        const subclass_selector = subclassSelector(context, it) orelse break;
        try subclasses.append(allocator, subclass_selector[0]);
        it = subclass_selector[1];
    }

    var pseudo_elements = ArrayListUnmanaged(PseudoElement){};
    defer {
        for (pseudo_elements.items) |element| allocator.free(element.classes);
        pseudo_elements.deinit(allocator);
    }
    while (true) {
        const element_colon = context.nextNoWhitespace(it) orelse break;
        if (element_colon.tag != .token_colon) break;
        const element_colon_2 = context.nextNoWhitespace(element_colon.next_it) orelse break;
        if (element_colon_2.tag != .token_colon) break;
        const element = pseudoClassSelector(context, element_colon_2.next_it) orelse break;
        try pseudo_elements.ensureUnusedCapacity(allocator, 1);

        var pseudo_classes = ArrayListUnmanaged(ComponentTree.Size){};
        defer pseudo_classes.deinit(allocator);
        it = element[1];
        while (true) {
            const class_colon = context.nextNoWhitespace(it) orelse break;
            if (class_colon.tag != .token_colon) break;
            const class = pseudoClassSelector(context, class_colon.next_it) orelse break;
            try pseudo_classes.append(allocator, class[0]);
            it = class[1];
        }

        const pseudo_classes_owned = try pseudo_classes.toOwnedSlice(allocator);
        pseudo_elements.appendAssumeCapacity(.{ .name = element[0], .classes = pseudo_classes_owned });
    }

    if (type_selector == null and subclasses.items.len == 0 and pseudo_elements.items.len == 0) return null;

    const subclasses_owned = try subclasses.toOwnedSlice(allocator);
    errdefer allocator.free(subclasses_owned);
    const pseudo_elements_owned = try pseudo_elements.toOwnedSlice(allocator);
    return .{
        CompoundSelector{
            .type_selector = type_selector,
            .subclasses = subclasses_owned,
            .pseudo_elements = pseudo_elements_owned,
        },
        it,
    };
}

const TypeSelector = struct {
    const Namespace = union(enum) {
        none,
        default,
        any,
        identifier: ComponentTree.Size,
    };

    const Name = union(enum) {
        universal,
        identifier: ComponentTree.Size,
    };

    namespace: Namespace,
    name: Name,
};

fn typeSelector(context: Context, it: Iterator) ?Pair(TypeSelector) {
    var first_name_tag: enum { empty, asterisk, identifier } = undefined;

    const first_name = context.next(it) orelse return null;
    const after_first_name = blk: {
        switch (first_name.tag) {
            .token_ident => {
                first_name_tag = .identifier;
                break :blk first_name.next_it;
            },
            .token_delim => {
                switch (first_name.extra.codepoint()) {
                    '*' => {
                        first_name_tag = .asterisk;
                        break :blk first_name.next_it;
                    },
                    '|' => {
                        first_name_tag = .empty;
                        break :blk it;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    };

    if (typeSelectorSecondName(context, after_first_name)) |second_name| {
        const result = TypeSelector{
            .namespace = switch (first_name_tag) {
                .empty => .none,
                .asterisk => .any,
                .identifier => .{ .identifier = first_name.index },
            },
            .name = second_name[0],
        };
        return .{ result, second_name[1] };
    } else {
        const result = TypeSelector{
            .namespace = .default,
            .name = switch (first_name_tag) {
                .empty => return null,
                .asterisk => .universal,
                .identifier => .{ .identifier = first_name.index },
            },
        };
        return .{ result, first_name.next_it };
    }
}

fn typeSelectorSecondName(context: Context, it: Iterator) ?Pair(TypeSelector.Name) {
    const pipe = context.nextNoWhitespace(it) orelse return null;
    if (!(pipe.tag == .token_delim and pipe.extra.codepoint() == '|')) return null;

    const second_name = context.nextNoWhitespace(pipe.next_it) orelse return null;
    const result: TypeSelector.Name = switch (second_name.tag) {
        .token_ident => .{ .identifier = second_name.index },
        .token_delim => if (second_name.extra.codepoint() == '*') .universal else return null,
        else => return null,
    };

    return .{ result, second_name.next_it };
}

const SubclassSelector = union(enum) {
    id: ComponentTree.Size,
    class: ComponentTree.Size,
    pseudo: ComponentTree.Size,
    attribute: AttributeSelector,
};

fn subclassSelector(context: Context, it: Iterator) ?Pair(SubclassSelector) {
    const first_component = context.next(it) orelse return null;
    switch (first_component.tag) {
        .token_hash_id => return .{
            SubclassSelector{ .id = first_component.index },
            first_component.next_it,
        },
        .token_delim => {
            if (first_component.extra.codepoint() != '.') return null;
            const class_name = context.nextNoWhitespace(first_component.next_it) orelse return null;
            if (class_name.tag != .token_ident) return null;
            return .{
                SubclassSelector{ .class = class_name.index },
                class_name.next_it,
            };
        },
        .simple_block_bracket => {
            const end_of_block = context.slice.items(.next_sibling)[first_component.index];
            const new_it = Iterator.init(first_component.index + 1, end_of_block);
            const attribute_selector = attributeSelector(context, new_it) orelse return null;
            if (attribute_selector[1].index != end_of_block) return null;
            return .{
                SubclassSelector{ .attribute = attribute_selector[0] },
                Iterator.init(end_of_block, it.end),
            };
        },
        .token_colon => {
            const pseudo_class = pseudoClassSelector(context, first_component.next_it) orelse return null;
            return .{
                SubclassSelector{ .pseudo = pseudo_class[0] },
                pseudo_class[1],
            };
        },
        else => return null,
    }
}

const AttributeSelector = struct {
    namespace: Namespace,
    name: ComponentTree.Size,
    complex: ?Complex,

    const Namespace = union(enum) {
        none,
        any,
        identifier: ComponentTree.Size,
    };

    const Complex = struct {
        operator: Operator,
        /// The index of an <ident-token> or a <string-token>
        value: ComponentTree.Size,
        case: Case,
    };

    const Operator = enum { equals, list_contains, equals_or_prefix_dash, starts_with, ends_with, contains };

    const Case = enum { default, same_case, ignore_case };
};

fn attributeSelector(context: Context, it: Iterator) ?Pair(AttributeSelector) {
    // A fully qualified attribute name is equivalent to a <type-selector>, except that the local name cannot be '*' (the universal selector).
    const type_selector = typeSelector(context, it) orelse return null;
    var result = AttributeSelector{
        .namespace = switch (type_selector[0].namespace) {
            // Default namespaces do not apply to attributes
            .none, .default => .none,
            .any => .any,
            .identifier => |index| .{ .identifier = index },
        },
        .name = switch (type_selector[0].name) {
            .universal => return null,
            .identifier => |index| index,
        },
        .complex = undefined,
    };

    const attr_matcher = context.next(type_selector[1]) orelse {
        result.complex = null;
        return .{ result, type_selector[1] };
    };
    result.complex = @as(AttributeSelector.Complex, undefined);
    if (attr_matcher.tag != .token_delim) return null;
    const operator: AttributeSelector.Operator = switch (attr_matcher.extra.codepoint()) {
        '=' => .equals,
        '~' => .list_contains,
        '|' => .equals_or_prefix_dash,
        '^' => .starts_with,
        '$' => .ends_with,
        '*' => .contains,
        else => return null,
    };
    result.complex.?.operator = operator;
    const after_operator = blk: {
        if (operator != .equals) {
            const equal = context.nextNoWhitespace(attr_matcher.next_it) orelse return null;
            if (!(equal.tag == .token_delim and equal.extra.codepoint() == '=')) return null;
            break :blk equal.next_it;
        } else {
            break :blk attr_matcher.next_it;
        }
    };

    const value = context.next(after_operator) orelse return null;
    switch (value.tag) {
        .token_ident, .token_string => result.complex.?.value = value.index,
        else => return null,
    }

    const modifier = context.next(value.next_it) orelse {
        result.complex.?.case = .default;
        return .{ result, value.next_it };
    };
    if (modifier.tag != .token_ident) return null;
    if (context.matchKeyword(modifier.location, &.{'i'})) {
        result.complex.?.case = .ignore_case;
    } else if (context.matchKeyword(modifier.location, &.{'s'})) {
        result.complex.?.case = .same_case;
    } else {
        return null;
    }

    return .{ result, modifier.next_it };
}

// Assumes that a colon ':' has been seen already.
fn pseudoClassSelector(context: Context, it: Iterator) ?Pair(ComponentTree.Size) {
    const main_component = context.nextNoWhitespace(it) orelse return null;
    switch (main_component.tag) {
        .token_ident => return .{
            main_component.index,
            main_component.next_it,
        },
        .function => {
            if (anyValue(context, main_component.index)) {
                return .{
                    main_component.index,
                    main_component.next_it,
                };
            } else {
                return null;
            }
        },
        else => return null,
    }
}

// `start` must be the index of a function or a block
fn anyValue(context: Context, start: ComponentTree.Size) bool {
    const tags = context.slice.items(.tag);
    const next_siblings = context.slice.items(.next_sibling);

    var index = start + 1;
    const end = next_siblings[start];
    while (index < end) {
        const tag = tags[index];
        switch (tag) {
            .token_bad_string, .token_bad_url, .token_right_paren, .token_right_bracket, .token_right_curly => return false,
            else => index = next_siblings[index],
        }
    }

    return true;
}

const debug = struct {
    fn printSelectors(selectors: Selectors, writer: anytype) !void {
        for (selectors.list, 0..) |complex_selector, i| {
            try printComplexSelector(complex_selector, writer);
            if (i + 1 < selectors.list.len) try writer.writeAll(", ");
        }
    }

    fn printComplexSelector(complex: ComplexSelector, writer: anytype) !void {
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

    fn printCompoundSelector(c: CompoundSelector, writer: anytype) !void {
        if (c.type_selector) |ts| {
            if (ts.namespace == .identifier) {
                try writer.print("{}", .{ts.namespace.identifier});
            } else {
                try writer.print("{s}", .{@tagName(ts.namespace)});
            }
            if (ts.name == .identifier) {
                try writer.print("|{}", .{ts.name.identifier});
            } else {
                try writer.print("|{s}", .{@tagName(ts.name)});
            }
        }

        for (c.subclasses) |sub| {
            switch (sub) {
                .id => try writer.print("#{}", .{sub.id}),
                .class => try writer.print(".{}", .{sub.class}),
                .pseudo => try writer.print(":{}", .{sub.pseudo}),
                .attribute => |at| {
                    if (at.namespace == .identifier) {
                        try writer.print("[{}", .{at.namespace.identifier});
                    } else {
                        try writer.print("[{s}", .{@tagName(at.namespace)});
                    }
                    try writer.print("|{}", .{at.name});
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = zss.util.ascii8ToAscii7(
        \\p[abc="2" s][xyz]::after,  h1.one#two[three *= four] { declarations }
    );
    const source = ParserSource.init(try syntax.tokenize.Source.init(input));
    var stylesheet = try syntax.parse.parseStylesheet(source, allocator);
    defer stylesheet.deinit(allocator);

    const slice = stylesheet.components.slice();
    const start = @as(ComponentTree.Size, 2);
    const end = slice.items(.extra)[1].index();
    const context = Context{ .source = source, .slice = slice };
    const it = Iterator.init(start, end);

    var selectors = (try complexSelectorList(context, it, allocator)) orelse return error.Fail;
    defer selectors[0].deinit(allocator);

    if (!context.finishParsing(selectors[1])) return error.Fail;

    const stderr = std.io.getStdErr().writer();
    try ComponentTree.debug.print(stylesheet, allocator, stderr);
    try stderr.writeAll("\n");
    try debug.printSelectors(selectors[0], stderr);
    try stderr.writeAll("\n");
}
