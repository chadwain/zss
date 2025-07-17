const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const null_element = Element.null_element;
const CascadedValues = zss.CascadedValues;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Stack = zss.Stack;

const aggregates = zss.property.aggregates;
const SpecifiedValues = aggregates.Tag.SpecifiedValues;
const ComputedValues = aggregates.Tag.ComputedValues;

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
    box_style: ?ComputedValues(.box_style) = null,
    content_width: ?ComputedValues(.content_width) = null,
    horizontal_edges: ?ComputedValues(.horizontal_edges) = null,
    content_height: ?ComputedValues(.content_height) = null,
    vertical_edges: ?ComputedValues(.vertical_edges) = null,
    border_styles: ?ComputedValues(.border_styles) = null,
    insets: ?ComputedValues(.insets) = null,
    z_index: ?ComputedValues(.z_index) = null,
    font: ?ComputedValues(.font) = null,
};

const CosmeticComputedValues = struct {
    box_style: ?ComputedValues(.box_style) = null,
    border_colors: ?ComputedValues(.border_colors) = null,
    border_styles: ?ComputedValues(.border_styles) = null,
    background_color: ?ComputedValues(.background_color) = null,
    background_clip: ?ComputedValues(.background_clip) = null,
    background: ?ComputedValues(.background) = null,
    color: ?ComputedValues(.color) = null,
    insets: ?ComputedValues(.insets) = null,
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
        // TODO: Use ElementHashMap
        map: std.AutoHashMapUnmanaged(Element, BoxGenComputedValues) = .{},
        current_computed: BoxGenComputedValues = undefined,
    },
    cosmetic: struct {
        // TODO: Use ElementHashMap
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

pub fn getTextFont(self: StyleComputer, comptime stage: Stage) ComputedValues(.font) {
    const element = self.current.element;
    assert(self.elementCategory(element) == .text);
    var inherited_value = InheritedValue(.font){ .element = element };
    return inherited_value.get(self, stage);
}

pub fn setComputedValue(self: *StyleComputer, comptime stage: Stage, comptime tag: aggregates.Tag, value: ComputedValues(tag)) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    const field = &@field(current_stage.current_computed, @tagName(tag));
    assert(field.* == null);
    field.* = value;
}

pub fn getSpecifiedValue(self: StyleComputer, comptime stage: Stage, comptime tag: aggregates.Tag) SpecifiedValues(tag) {
    return self.getSpecifiedValueForElement(stage, tag, self.current.element, self.current.cascaded_values);
}

fn getSpecifiedValueForElement(
    self: StyleComputer,
    comptime stage: Stage,
    comptime tag: aggregates.Tag,
    element: Element,
    cascaded_values: CascadedValues,
) SpecifiedValues(tag) {
    assert(self.elementCategory(element) == .normal);
    const cascaded_value = cascaded_values.getPtr(tag);

    const inheritance_type = comptime tag.inheritanceType();
    const default: enum { inherit, initial } = default: {
        // Use the value of the 'all' property.
        //
        // TODO: Handle 'direction', 'unicode-bidi', and custom properties specially here.
        // CSS-CASCADE-4§3.2: The all property is a shorthand that resets all CSS properties except direction and unicode-bidi.
        //                    [...] It does not reset custom properties.
        if (cascaded_values.all) |all| switch (all) {
            .initial => break :default .initial,
            .inherit => break :default .inherit,
            .unset => {},
        };

        // Just use the inheritance type.
        switch (inheritance_type) {
            .inherited => break :default .inherit,
            .not_inherited => break :default .initial,
        }
    };

    const initial_value = tag.initialValues();
    if (cascaded_value == null and default == .initial) {
        return initial_value;
    }

    var inherited_value = InheritedValue(tag){ .element = element };
    if (cascaded_value == null and default == .inherit) {
        return inherited_value.get(self, stage);
    }

    var specified: SpecifiedValues(tag) = undefined;
    inline for (tag.fields()) |field| {
        const cascaded_property = @field(cascaded_value.?, field.name);
        const specified_property = &@field(specified, field.name);
        specified_property.* = switch (cascaded_property) {
            .inherit => @field(inherited_value.get(self, stage), field.name),
            .initial => @field(initial_value, field.name),
            .unset => switch (inheritance_type) {
                .inherited => @field(inherited_value.get(self, stage), field.name),
                .not_inherited => @field(initial_value, field.name),
            },
            .undeclared => switch (default) {
                .inherit => @field(inherited_value.get(self, stage), field.name),
                .initial => @field(initial_value, field.name),
            },
            .declared => |declared| declared,
        };
    }

    return specified;
}

fn InheritedValue(comptime tag: aggregates.Tag) type {
    return struct {
        value: ?ComputedValues(tag) = null,
        element: Element,

        fn get(self: *@This(), computer: StyleComputer, comptime stage: Stage) ComputedValues(tag) {
            if (self.value) |value| return value;

            const current_stage = @field(computer.stage, @tagName(stage));
            const parent = computer.element_tree_slice.parent(self.element);
            self.value = if (parent.eqlNull())
                tag.initialValues()
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

/// Given a specified value, returns a computed value.
fn specifiedToComputed(comptime tag: aggregates.Tag, specified: SpecifiedValues(tag), computer: StyleComputer, element: Element) ComputedValues(tag) {
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
                .color = specified.color,
            };
        },
        else => std.debug.panic("TODO: specifiedToComputed for aggregate '{s}'", .{@tagName(tag)}),
    }
}
