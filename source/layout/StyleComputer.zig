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
const Stack = zss.util.Stack;

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

// Does not do deinitStage.
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

pub fn setCurrentElement(self: *StyleComputer, comptime stage: Stage, element: Element) void {
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
    current_stage.current_computed = .{};
}

pub fn commitElement(self: *StyleComputer, comptime stage: Stage) !void {
    const element = self.current.element;
    const current_stage = &@field(self.stage, @tagName(stage));
    inline for (std.meta.fields(stage.ComputedValues())) |field_info| {
        const field = @field(current_stage.current_computed, field_info.name);
        assert(field != null);
    }
    try current_stage.map.putNoClobber(self.allocator, element, current_stage.current_computed);
}

pub fn getText(self: StyleComputer) zss.values.types.Text {
    const element = self.current.element;
    assert(self.elementCategory(element) == .text);
    return self.element_tree_slice.get(.text, element) orelse "";
}

pub fn getTextFont(self: StyleComputer, comptime stage: Stage) aggregates.Font {
    const element = self.current.element;
    assert(self.elementCategory(element) == .text);
    var inherited_value = OptionalInheritedValue(.font){};
    return inherited_value.get(self, stage);
}

pub fn setComputedValue(self: *StyleComputer, comptime stage: Stage, comptime tag: aggregates.Tag, value: tag.Value()) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    const field = &@field(current_stage.current_computed, @tagName(tag));
    assert(field.* == null);
    field.* = value;
}

pub fn getSpecifiedValue(
    self: StyleComputer,
    comptime stage: Stage,
    comptime tag: aggregates.Tag,
) tag.Value() {
    const element = self.current.element;
    assert(self.elementCategory(element) == .normal);

    const cascaded_values = self.current.cascaded_values;
    var cascaded_value = cascaded_values.get(tag);

    // CSS-COLOR-3§4.4: If the 'currentColor' keyword is set on the 'color' property itself, it is treated as 'color: inherit'.
    if (tag == .color) {
        if (cascaded_value) |*value| {
            if (value.color == .current_color) {
                value.color = .inherit;
            }
        }
    }

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

    var inherited_value = OptionalInheritedValue(tag){};
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

fn OptionalInheritedValue(comptime tag: aggregates.Tag) type {
    const Aggregate = tag.Value();
    return struct {
        value: ?Aggregate = null,

        fn get(self: *@This(), computer: StyleComputer, comptime stage: Stage) Aggregate {
            if (self.value) |value| return value;

            const current_stage = @field(computer.stage, @tagName(stage));
            const parent = computer.element_tree_slice.parent(computer.current.element);
            self.value = if (parent.eqlNull())
                Aggregate.initial_values
            else if (current_stage.map.get(parent)) |parent_computed_value|
                @field(parent_computed_value, @tagName(tag))
            else
                std.debug.panic("TODO: parent computed value not found", .{});
            return self.value.?;
        }
    };
}

// fn getComputedBoxStyle(
//     computer: StyleComputer,
//     comptime stage: Stage,
//     element: Element,
// ) aggregates.BoxStyle {
//     const current_stage = @field(computer.stage, @tagName(stage));
//     if (current_stage.map.get(element)) |computed_value| return computed_value;
//
//     const Inherited = struct {
//         value: ?aggregates.BoxStyle = null,
//
//         fn get(self: *@This(), computer: StyleComputer, parent: Element) aggregates.BoxStyle {
//             if (self.value) |value| return value;
//             if (parent.eqlNull()) {
//                 self.value = aggregates.BoxStyle.initial_values;
//             } else {
//                 // TODO: Recursive call here
//                 self.value = getComputedBoxStyle(computer, stage, parent);
//             }
//             return self.value;
//         }
//     };
//
//     const parent = computer.element_tree_slice.parent(e);
//     const initial_value = aggregates.BoxStyle.initial_values;
//     var inherited_value = Inherited{};
//     const cascaded_values = computer.element_tree_slice.get(.cascaded_values, element);
//     var box_style = cascaded_values.get(box_style) orelse return initial_value;
//
//     inline for (std.meta.fields(aggregates.BoxStyle)) |field_info| {
//         const property = &@field(box_style, field_info.name);
//         switch (property.*) {
//             .inherit => property.* = @field(inherited_value.get(computer, element), field_info.name),
//             .initial => property.* = @field(initial_value, field_info.name),
//             .unset => property.* = @field(initial_value, field_info.name),
//             .undeclared => property.* = @field(initial_value, field_info.name),
//             else => {},
//         }
//     }
//
//     const computed_value, _ = solve.boxStyle(box_style, parent.eqlNull());
//     return computed_value;
// }
