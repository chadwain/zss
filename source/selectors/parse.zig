const zss = @import("../../zss.zig");
const selectors = zss.selectors;
const Environment = zss.Environment;
const NamespaceId = Environment.NamespaceId;
const NameId = Environment.NameId;
const syntax = zss.syntax;
const Component = zss.syntax.Component;
const ComponentTree = zss.syntax.ComponentTree;
const ParserSource = syntax.parse.Source;

const std = @import("std");
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub const Context = struct {
    env: *Environment,
    source: ParserSource,
    slice: ComponentTree.List.Slice,
    end: ComponentTree.Size,
    unspecified_namespace: NamespaceId,

    pub fn init(env: *Environment, source: ParserSource, slice: ComponentTree.List.Slice, end: ComponentTree.Size) Context {
        return Context{
            .env = env,
            .source = source,
            .slice = slice,
            .end = end,
            .unspecified_namespace = env.default_namespace orelse NamespaceId.any,
        };
    }

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
        while (index < context.end) {
            const tag = tags[index];
            const next_index = next_siblings[index];
            switch (tag) {
                .token_whitespace => index = next_index,
                else => return .{
                    .index = index,
                    .tag = tag,
                    .location = context.slice.items(.location)[index],
                    .extra = context.slice.items(.extra)[index],
                    .next_it = .{ .index = next_index },
                },
            }
        }

        return null;
    }

    fn nextNoWhitespace(context: Context, it: Iterator) ?Next {
        if (it.index < context.end) {
            const tag = context.slice.items(.tag)[it.index];
            switch (tag) {
                .token_whitespace => return null,
                else => return .{
                    .index = it.index,
                    .tag = tag,
                    .location = context.slice.items(.location)[it.index],
                    .extra = context.slice.items(.extra)[it.index],
                    .next_it = .{ .index = context.slice.items(.next_sibling)[it.index] },
                },
            }
        }

        return null;
    }

    fn nextIsWhitespace(context: Context, it: Iterator) bool {
        if (it.index < context.end) {
            return context.slice.items(.tag)[it.index] == .token_whitespace;
        } else {
            return false;
        }
    }

    fn consumeWhitespace(context: Context, it: Iterator) Iterator {
        const tags = context.slice.items(.tag);
        const next_siblings = context.slice.items(.next_sibling);

        var index = it.index;
        while (index < context.end) {
            const tag = tags[index];
            if (tag == .token_whitespace) {
                index = next_siblings[index];
            } else {
                break;
            }
        }
        return Iterator.init(index);
    }

    pub fn finishParsing(context: Context, it: Iterator) bool {
        return context.next(it) == null;
    }

    fn matchKeyword(context: Context, location: ParserSource.Location, string: []const u21) bool {
        return context.source.matchKeyword(location, string);
    }
};

pub const Iterator = struct {
    index: ComponentTree.Size,

    pub fn init(start: ComponentTree.Size) Iterator {
        return .{ .index = start };
    }
};

fn Pair(comptime First: type) type {
    return std.meta.Tuple(&[2]type{ First, Iterator });
}

pub fn complexSelectorList(context: *Context, start: Iterator) !?Pair(selectors.ComplexSelectorList) {
    var list = ArrayListUnmanaged(selectors.ComplexSelector){};
    defer list.deinit(context.env.allocator);

    var it = start;
    var expecting_comma = false;
    while (true) {
        if (expecting_comma) {
            const comma = context.next(it) orelse break;
            if (comma.tag != .token_comma) break;
            it = comma.next_it;
            expecting_comma = false;
        } else {
            try list.ensureUnusedCapacity(context.env.allocator, 1);
            const complex_selector = (try complexSelector(context, it)) orelse break;
            list.appendAssumeCapacity(complex_selector[0]);
            it = complex_selector[1];
            expecting_comma = true;
        }
    }

    if (list.items.len == 0) {
        return null;
    } else {
        const owned = try list.toOwnedSlice(context.env.allocator);
        return .{ selectors.ComplexSelectorList{ .list = owned }, it };
    }
}

fn complexSelector(context: *Context, start: Iterator) !?Pair(selectors.ComplexSelector) {
    var it = start;

    var compounds = ArrayListUnmanaged(selectors.CompoundSelector){};
    defer {
        for (compounds.items) |*compound| compound.deinit(context.env.allocator);
        compounds.deinit(context.env.allocator);
    }
    var combinators = ArrayListUnmanaged(selectors.Combinator){};
    defer combinators.deinit(context.env.allocator);

    {
        try compounds.ensureUnusedCapacity(context.env.allocator, 1);
        const compound = (try compoundSelector(context, it)) orelse return null;
        compounds.appendAssumeCapacity(compound[0]);
        it = compound[1];
    }

    while (true) {
        const com = combinator(context, it) orelse break;

        try compounds.ensureUnusedCapacity(context.env.allocator, 1);
        const compound = (try compoundSelector(context, com[1])) orelse break;

        compounds.appendAssumeCapacity(compound[0]);
        try combinators.append(context.env.allocator, com[0]);
        it = compound[1];
    }

    const combinators_owned = try combinators.toOwnedSlice(context.env.allocator);
    errdefer context.env.allocator.free(combinators_owned);
    const compounds_owned = try compounds.toOwnedSlice(context.env.allocator);
    return .{
        selectors.ComplexSelector{ .compounds = compounds_owned, .combinators = combinators_owned },
        it,
    };
}

fn combinator(context: *Context, it: Iterator) ?Pair(selectors.Combinator) {
    blk: {
        const component = context.next(it) orelse break :blk;
        if (component.tag != .token_delim) break :blk;

        var result: selectors.Combinator = undefined;
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

fn compoundSelector(context: *Context, start: Iterator) !?Pair(selectors.CompoundSelector) {
    var it = context.consumeWhitespace(start);

    var type_selector: ?selectors.TypeSelector = undefined;
    if (try typeSelector(context, it)) |result| {
        type_selector = result[0];
        it = result[1];
    } else {
        type_selector = null;
    }

    var subclasses = ArrayListUnmanaged(selectors.SubclassSelector){};
    defer subclasses.deinit(context.env.allocator);
    while (true) {
        if (context.nextIsWhitespace(it)) break;
        const subclass_selector = (try subclassSelector(context, it)) orelse break;
        try subclasses.append(context.env.allocator, subclass_selector[0]);
        it = subclass_selector[1];
    }

    var pseudo_elements = ArrayListUnmanaged(selectors.PseudoElement){};
    defer {
        for (pseudo_elements.items) |element| context.env.allocator.free(element.classes);
        pseudo_elements.deinit(context.env.allocator);
    }
    while (true) {
        const element_colon = context.nextNoWhitespace(it) orelse break;
        if (element_colon.tag != .token_colon) break;
        const element_colon_2 = context.nextNoWhitespace(element_colon.next_it) orelse break;
        if (element_colon_2.tag != .token_colon) break;
        const element = pseudoSelector(context, element_colon_2.next_it) orelse break;
        try pseudo_elements.ensureUnusedCapacity(context.env.allocator, 1);

        var pseudo_classes = ArrayListUnmanaged(ComponentTree.Size){};
        defer pseudo_classes.deinit(context.env.allocator);
        it = element[1];
        while (true) {
            const class_colon = context.nextNoWhitespace(it) orelse break;
            if (class_colon.tag != .token_colon) break;
            const class = pseudoSelector(context, class_colon.next_it) orelse break;
            try pseudo_classes.append(context.env.allocator, class[0]);
            it = class[1];
        }

        const pseudo_classes_owned = try pseudo_classes.toOwnedSlice(context.env.allocator);
        pseudo_elements.appendAssumeCapacity(.{ .name = element[0], .classes = pseudo_classes_owned });
    }

    if (type_selector == null and subclasses.items.len == 0 and pseudo_elements.items.len == 0) return null;

    const subclasses_owned = try subclasses.toOwnedSlice(context.env.allocator);
    errdefer context.env.allocator.free(subclasses_owned);
    const pseudo_elements_owned = try pseudo_elements.toOwnedSlice(context.env.allocator);
    return .{
        selectors.CompoundSelector{
            .type_selector = type_selector,
            .subclasses = subclasses_owned,
            .pseudo_elements = pseudo_elements_owned,
        },
        it,
    };
}

fn typeSelector(context: *Context, it: Iterator) !?Pair(selectors.TypeSelector) {
    var result: selectors.TypeSelector = undefined;
    const element_type = elementType(context, it) orelse return null;
    if (element_type[0].second_name) |second_name| {
        switch (element_type[0].first_name) {
            .identifier => panic("TODO: Namespaces in type selectors", .{}),
            .empty => result.namespace = NamespaceId.none,
            .asterisk => result.namespace = NamespaceId.any,
        }

        switch (second_name) {
            .identifier => |identifier| result.name = try context.env.addTypeOrAttributeName(identifier, context.source),
            .asterisk => result.name = NameId.any,
        }
        return .{ result, element_type[1] };
    } else {
        result.namespace = context.unspecified_namespace;
        result.name = switch (element_type[0].first_name) {
            .empty => return null,
            .asterisk => NameId.any,
            .identifier => |identifier| try context.env.addTypeOrAttributeName(identifier, context.source),
        };

        return .{ result, element_type[1] };
    }
}

const ElementType = struct {
    first_name: FirstName,
    second_name: ?SecondName,

    const FirstName = union(enum) {
        identifier: ParserSource.Location,
        empty,
        asterisk,
    };
    const SecondName = union(enum) {
        identifier: ParserSource.Location,
        asterisk,
    };
};

fn elementType(context: *Context, it: Iterator) ?Pair(ElementType) {
    var result: ElementType = undefined;

    const first_name = context.next(it) orelse return null;
    const after_first_name = blk: {
        switch (first_name.tag) {
            .token_ident => {
                result.first_name = .{ .identifier = first_name.location };
                break :blk first_name.next_it;
            },
            .token_delim => {
                switch (first_name.extra.codepoint()) {
                    '*' => {
                        result.first_name = .asterisk;
                        break :blk first_name.next_it;
                    },
                    '|' => {
                        result.first_name = .empty;
                        break :blk it;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    };

    if (elementTypeSecondName(context, after_first_name)) |second_name| {
        result.second_name = second_name[0];
        return .{ result, second_name[1] };
    } else {
        result.second_name = null;
        return .{ result, first_name.next_it };
    }
}

fn elementTypeSecondName(context: *Context, it: Iterator) ?Pair(ElementType.SecondName) {
    const pipe = context.nextNoWhitespace(it) orelse return null;
    if (!(pipe.tag == .token_delim and pipe.extra.codepoint() == '|')) return null;

    const second_name = context.nextNoWhitespace(pipe.next_it) orelse return null;
    const result: ElementType.SecondName = switch (second_name.tag) {
        .token_ident => .{ .identifier = second_name.location },
        .token_delim => if (second_name.extra.codepoint() == '*') .asterisk else return null,
        else => return null,
    };

    return .{ result, second_name.next_it };
}

fn subclassSelector(context: *Context, it: Iterator) !?Pair(selectors.SubclassSelector) {
    const first_component = context.next(it) orelse return null;
    switch (first_component.tag) {
        .token_hash_id => return .{
            selectors.SubclassSelector{ .id = first_component.index },
            first_component.next_it,
        },
        .token_delim => {
            if (first_component.extra.codepoint() != '.') return null;
            const class_name = context.nextNoWhitespace(first_component.next_it) orelse return null;
            if (class_name.tag != .token_ident) return null;
            return .{
                selectors.SubclassSelector{ .class = class_name.index },
                class_name.next_it,
            };
        },
        .simple_block_bracket => {
            const old_end = context.end;
            const end_of_block = context.slice.items(.next_sibling)[first_component.index];
            context.end = end_of_block;
            defer context.end = old_end;
            const new_it = Iterator.init(first_component.index + 1);
            const attribute_selector = (try attributeSelector(context, new_it)) orelse return null;
            if (attribute_selector[1].index != end_of_block) return null;
            return .{
                selectors.SubclassSelector{ .attribute = attribute_selector[0] },
                Iterator.init(end_of_block),
            };
        },
        .token_colon => {
            const pseudo_class = pseudoSelector(context, first_component.next_it) orelse return null;
            return .{
                selectors.SubclassSelector{ .pseudo = pseudo_class[0] },
                pseudo_class[1],
            };
        },
        else => return null,
    }
}

fn attributeSelector(context: *Context, it: Iterator) !?Pair(selectors.AttributeSelector) {
    var result: selectors.AttributeSelector = undefined;
    const element_type = elementType(context, it) orelse return null;
    if (element_type[0].second_name) |second_name| {
        switch (element_type[0].first_name) {
            .identifier => panic("TODO: Namespaces in type selectors", .{}),
            .empty => result.namespace = NamespaceId.none,
            .asterisk => result.namespace = NamespaceId.any,
        }

        switch (second_name) {
            .identifier => |identifier| result.name = try context.env.addTypeOrAttributeName(identifier, context.source),
            // The local name must be an identifier
            .asterisk => return null,
        }
    } else {
        // An unspecified namespace resolves to no namespace
        result.namespace = NamespaceId.none;
        result.name = switch (element_type[0].first_name) {
            .identifier => |identifier| try context.env.addTypeOrAttributeName(identifier, context.source),
            // The local name must be an identifier
            .empty, .asterisk => return null,
        };
    }

    const attr_matcher = context.next(element_type[1]) orelse {
        result.complex = null;
        return .{ result, element_type[1] };
    };
    result.complex = @as(selectors.AttributeSelector.Complex, undefined);
    if (attr_matcher.tag != .token_delim) return null;
    const operator: selectors.AttributeSelector.Operator = switch (attr_matcher.extra.codepoint()) {
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
fn pseudoSelector(context: *Context, it: Iterator) ?Pair(ComponentTree.Size) {
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
fn anyValue(context: *Context, start: ComponentTree.Size) bool {
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
