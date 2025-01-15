const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const aggregates = zss.properties.aggregates;
const null_element = Element.null_element;
const CascadedValues = zss.CascadedValues;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.Stack;

const solve = @import("./solve.zig");

const StyleComputer = @This();

pub const Stage = enum {
    box_gen,
    cosmetic,

    fn ComputedValues(comptime stage: Stage) type {
        return switch (stage) {
            .box_gen => BoxGenComputedValues,
            .cosmetic => CosmeticComputedValues,
        };
    }
};

const BoxGenComputedValues = struct {
    box_style: ?aggregates.BoxStyle = null,
    content_width: ?aggregates.ContentWidth = null,
    horizontal_edges: ?aggregates.HorizontalEdges = null,
    content_height: ?aggregates.ContentHeight = null,
    vertical_edges: ?aggregates.VerticalEdges = null,
    border_styles: ?aggregates.BorderStyles = null,
    insets: ?aggregates.Insets = null,
    z_index: ?aggregates.ZIndex = null,
    font: ?aggregates.Font = null,
};

const CosmeticComputedValues = struct {
    box_style: ?aggregates.BoxStyle = null,
    border_colors: ?aggregates.BorderColors = null,
    border_styles: ?aggregates.BorderStyles = null,
    background1: ?aggregates.Background1 = null,
    background2: ?aggregates.Background2 = null,
    color: ?aggregates.Color = null,
    insets: ?aggregates.Insets = null,
};

const Current = struct {
    element: Element,
    cascaded_values: CascadedValues,
};

element_tree_slice: ElementTree.Slice,
root_element: Element,
current: Current,
allocator: Allocator,
stage: union {
    box_gen: struct {
        map: std.AutoHashMapUnmanaged(Element, BoxGenComputedValues) = .{},
        current_computed: BoxGenComputedValues = undefined,
    },
    cosmetic: struct {
        map: std.AutoHashMapUnmanaged(Element, CosmeticComputedValues) = .{},
        current_computed: CosmeticComputedValues = undefined,
    },
},

pub fn init(element_tree_slice: ElementTree.Slice, allocator: Allocator) StyleComputer {
    return .{
        .element_tree_slice = element_tree_slice,
        .allocator = allocator,
        .root_element = undefined,
        .current = undefined,
        .stage = undefined,
    };
}

pub fn deinit(self: *StyleComputer) void {
    _ = self;
}

pub fn deinitStage(self: *StyleComputer, comptime stage: Stage) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    current_stage.map.deinit(self.allocator);
}

pub fn elementCategory(self: StyleComputer, element: Element) ElementTree.Category {
    return self.element_tree_slice.category(element);
}

// TODO: Setting the current element should not require allocating
pub fn setCurrentElement(self: *StyleComputer, comptime stage: Stage, element: Element) !void {
    assert(!element.eqlNull());
    const cascaded_values = switch (self.elementCategory(element)) {
        .normal => self.element_tree_slice.get(.cascaded_values, element),
        .text => undefined,
    };
    self.current = .{
        .element = element,
        .cascaded_values = cascaded_values,
    };

    const current_stage = &@field(self.stage, @tagName(stage));
    const gop_result = try current_stage.map.getOrPut(self.allocator, element);
    if (!gop_result.found_existing) {
        gop_result.value_ptr.* = .{};
    }
    current_stage.current_computed = gop_result.value_ptr.*;
}

pub fn commitElement(self: *StyleComputer, comptime stage: Stage) void {
    const element = self.current.element;
    const current_stage = &@field(self.stage, @tagName(stage));
    current_stage.map.putAssumeCapacity(element, current_stage.current_computed);
}

pub fn getText(self: StyleComputer) zss.values.types.Text {
    const element = self.current.element;
    assert(self.elementCategory(element) == .text);
    return self.element_tree_slice.get(.text, element) orelse "";
}

pub fn getTextFont(self: StyleComputer, comptime stage: Stage) aggregates.Font {
    const element = self.current.element;
    assert(self.elementCategory(element) == .text);
    var inherited_value = InheritedValue(.font){ .element = element };
    return inherited_value.get(self, stage);
}

pub fn setComputedValue(self: *StyleComputer, comptime stage: Stage, comptime tag: aggregates.Tag, value: tag.Value()) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    const field = &@field(current_stage.current_computed, @tagName(tag));
    assert(field.* == null);
    field.* = value;
}

pub fn getSpecifiedValue(self: StyleComputer, comptime stage: Stage, comptime tag: aggregates.Tag) tag.Value() {
    return self.getSpecifiedValueForElement(stage, tag, self.current.element, self.current.cascaded_values);
}

fn getSpecifiedValueForElement(
    self: StyleComputer,
    comptime stage: Stage,
    comptime tag: aggregates.Tag,
    element: Element,
    cascaded_values: CascadedValues,
) tag.Value() {
    assert(self.elementCategory(element) == .normal);
    var cascaded_value = cascaded_values.get(tag);

    const inheritance_type = comptime tag.inheritanceType();
    const default: enum { inherit, initial } = default: {
        // Use the value of the 'all' property.
        // CSS-CASCADE-4§3.2: The all property is a shorthand that resets all CSS properties except direction and unicode-bidi.
        //                    [...] It does not reset custom properties.
        if (tag != .direction and tag != .unicode_bidi and tag != .custom) {
            if (cascaded_values.all) |all| switch (all) {
                .initial => break :default .initial,
                .inherit => break :default .inherit,
                .unset => {},
            };
        }

        // Just use the inheritance type.
        switch (inheritance_type) {
            .inherited => break :default .inherit,
            .not_inherited => break :default .initial,
        }
    };

    const Aggregate = tag.Value();
    const initial_value = Aggregate.initial_values;
    if (cascaded_value == null and default == .initial) {
        return initial_value;
    }

    var inherited_value = InheritedValue(tag){ .element = element };
    if (cascaded_value == null and default == .inherit) {
        return inherited_value.get(self, stage);
    }

    const cv = &cascaded_value.?;
    inline for (std.meta.fields(Aggregate)) |field_info| {
        const property = &@field(cv, field_info.name);
        switch (property.*) {
            .inherit => property.* = @field(inherited_value.get(self, stage), field_info.name),
            .initial => property.* = @field(initial_value, field_info.name),
            .unset => switch (inheritance_type) {
                .inherited => property.* = @field(inherited_value.get(self, stage), field_info.name),
                .not_inherited => property.* = @field(initial_value, field_info.name),
            },
            .undeclared => switch (default) {
                .inherit => property.* = @field(inherited_value.get(self, stage), field_info.name),
                .initial => property.* = @field(initial_value, field_info.name),
            },
            else => {},
        }
    }

    return cv.*;
}

fn InheritedValue(comptime tag: aggregates.Tag) type {
    const Aggregate = tag.Value();
    return struct {
        value: ?Aggregate = null,
        element: Element,

        fn get(self: *@This(), computer: StyleComputer, comptime stage: Stage) Aggregate {
            if (self.value) |value| return value;

            const current_stage = @field(computer.stage, @tagName(stage));
            const parent = computer.element_tree_slice.parent(self.element);
            self.value = if (parent.eqlNull())
                Aggregate.initial_values
            else blk: {
                if (current_stage.map.get(parent)) |parent_computed_values| {
                    if (@field(parent_computed_values, @tagName(tag))) |inherited_value| {
                        break :blk inherited_value;
                    }
                }
                // TODO: Cache the parent's computed value for faster access in future calls.

                const cascaded_values = computer.element_tree_slice.get(.cascaded_values, parent);
                // TODO: Recursive call here
                const specified_value = computer.getSpecifiedValueForElement(stage, tag, parent, cascaded_values);
                break :blk specifiedToComputed(tag, specified_value, computer, parent);
            };
            return self.value.?;
        }
    };
}

fn specifiedToComputed(comptime tag: aggregates.Tag, specified: tag.Value(), computer: StyleComputer, element: Element) tag.Value() {
    switch (tag) {
        .box_style => {
            const parent = computer.element_tree_slice.parent(element);
            const computed_value, _ = if (parent.eqlNull())
                solve.boxStyle(specified, .Root)
            else
                solve.boxStyle(specified, .NonRoot);
            return computed_value;
        },
        .font => {
            // TODO: This is not the correct computed value for fonts.
            return specified;
        },
        .color => {
            return .{
                .color = switch (specified.color) {
                    .rgba, .transparent, .current_color => specified.color,
                    .initial, .inherit, .unset, .undeclared => unreachable,
                },
            };
        },
        else => std.debug.panic("TODO: specifiedToComputed for aggregate '{s}'", .{@tagName(tag)}),
    }
}
