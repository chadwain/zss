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

const hb = @import("mach-harfbuzz").c;

const StyleComputer = @This();

pub const Stage = enum { box_gen, cosmetic };

const BoxGenComputedValueStack = struct {
    box_style: ArrayListUnmanaged(aggregates.BoxStyle) = .{},
    content_width: ArrayListUnmanaged(aggregates.ContentWidth) = .{},
    horizontal_edges: ArrayListUnmanaged(aggregates.HorizontalEdges) = .{},
    content_height: ArrayListUnmanaged(aggregates.ContentHeight) = .{},
    vertical_edges: ArrayListUnmanaged(aggregates.VerticalEdges) = .{},
    border_styles: ArrayListUnmanaged(aggregates.BorderStyles) = .{},
    z_index: ArrayListUnmanaged(aggregates.ZIndex) = .{},
    font: ArrayListUnmanaged(aggregates.Font) = .{},
};

const BoxGenCurrentValues = struct {
    box_style: aggregates.BoxStyle,
    content_width: aggregates.ContentWidth,
    horizontal_edges: aggregates.HorizontalEdges,
    content_height: aggregates.ContentHeight,
    vertical_edges: aggregates.VerticalEdges,
    border_styles: aggregates.BorderStyles,
    z_index: aggregates.ZIndex,
    font: aggregates.Font,
};

const BoxGenComptutedValueFlags = struct {
    box_style: bool = false,
    content_width: bool = false,
    horizontal_edges: bool = false,
    content_height: bool = false,
    vertical_edges: bool = false,
    border_styles: bool = false,
    z_index: bool = false,
    font: bool = false,
};

const CosmeticComputedValueStack = struct {
    box_style: ArrayListUnmanaged(aggregates.BoxStyle) = .{},
    border_colors: ArrayListUnmanaged(aggregates.BorderColors) = .{},
    border_styles: ArrayListUnmanaged(aggregates.BorderStyles) = .{},
    background1: ArrayListUnmanaged(aggregates.Background1) = .{},
    background2: ArrayListUnmanaged(aggregates.Background2) = .{},
    color: ArrayListUnmanaged(aggregates.Color) = .{},
    insets: ArrayListUnmanaged(aggregates.Insets) = .{},
};

const CosmeticCurrentValues = struct {
    box_style: aggregates.BoxStyle,
    border_colors: aggregates.BorderColors,
    border_styles: aggregates.BorderStyles,
    background1: aggregates.Background1,
    background2: aggregates.Background2,
    color: aggregates.Color,
    insets: aggregates.Insets,
};

const CosmeticComptutedValueFlags = struct {
    box_style: bool = false,
    border_colors: bool = false,
    border_styles: bool = false,
    background1: bool = false,
    background2: bool = false,
    color: bool = false,
    insets: bool = false,
};

const StackItem = struct {
    element: Element,
    cascaded_values: CascadedValues,
};

stack: Stack(StackItem) = .{},
element_tree_slice: ElementTree.Slice,
allocator: Allocator,

stage: union {
    box_gen: struct {
        current_values: BoxGenCurrentValues = undefined,
        current_flags: BoxGenComptutedValueFlags = .{},
        value_stack: BoxGenComputedValueStack = .{},
    },
    cosmetic: struct {
        current_values: CosmeticCurrentValues = undefined,
        current_flags: CosmeticComptutedValueFlags = .{},
        value_stack: CosmeticComputedValueStack = .{},
    },
},

root_font: struct {
    font: *hb.hb_font_t,
} = undefined,

// Does not do deinitStage.
pub fn deinit(self: *StyleComputer) void {
    self.stack.deinit(self.allocator);
}

pub fn assertEmptyStage(self: StyleComputer, comptime stage: Stage) void {
    assert(self.stack.rest.len == 0);
    const current_stage = &@field(self.stage, @tagName(stage));
    inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
        assert(@field(current_stage.value_stack, field_info.name).items.len == 0);
    }
}

pub fn deinitStage(self: *StyleComputer, comptime stage: Stage) void {
    self.stack.top = null;
    const current_stage = &@field(self.stage, @tagName(stage));
    inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
        @field(current_stage.value_stack, field_info.name).deinit(self.allocator);
    }
}

pub fn setRootElement(self: *StyleComputer, comptime stage: Stage, root_element: Element) void {
    assert(!root_element.eqlNull());
    assert(self.stack.top == null);
    self.stack.top = .{
        .element = root_element,
        .cascaded_values = self.element_tree_slice.get(.cascaded_values, root_element),
    };

    self.resetElement(stage);
}

pub fn getCurrentElement(self: StyleComputer) Element {
    return self.stack.top.?.element;
}

pub fn setComputedValue(self: *StyleComputer, comptime stage: Stage, comptime tag: aggregates.Tag, value: tag.Value()) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    const flag = &@field(current_stage.current_flags, @tagName(tag));
    assert(!flag.*);
    flag.* = true;
    @field(current_stage.current_values, @tagName(tag)) = value;
}

pub fn resetElement(self: *StyleComputer, comptime stage: Stage) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    current_stage.current_flags = .{};
    current_stage.current_values = undefined;
}

pub fn advanceElement(self: *StyleComputer, comptime stage: Stage) void {
    const sibling = self.element_tree_slice.nextSibling(self.stack.top.?.element);
    const cascaded_values = if (sibling.eqlNull()) CascadedValues{} else self.element_tree_slice.get(.cascaded_values, sibling);
    self.stack.top = .{
        .element = sibling,
        .cascaded_values = cascaded_values,
    };
    self.resetElement(stage);
}

pub fn pushElement(self: *StyleComputer, comptime stage: Stage) !void {
    const child = self.element_tree_slice.firstChild(self.stack.top.?.element);
    const cascaded_values = if (child.eqlNull()) CascadedValues{} else self.element_tree_slice.get(.cascaded_values, child);
    try self.stack.push(self.allocator, .{ .element = child, .cascaded_values = cascaded_values });

    const current_stage = &@field(self.stage, @tagName(stage));
    const values = current_stage.current_values;
    const flags = current_stage.current_flags;

    inline for (std.meta.fields(@TypeOf(flags))) |field_info| {
        const flag = @field(flags, field_info.name);
        assert(flag);
        const value = @field(values, field_info.name);
        try @field(current_stage.value_stack, field_info.name).append(self.allocator, value);
    }

    self.resetElement(stage);
}

pub fn popElement(self: *StyleComputer, comptime stage: Stage) void {
    _ = self.stack.pop();
    if (self.stack.top) |*item| {
        const sibling = self.element_tree_slice.nextSibling(item.element);
        const cascaded_values = if (sibling.eqlNull()) CascadedValues{} else self.element_tree_slice.get(.cascaded_values, sibling);
        item.* = .{
            .element = sibling,
            .cascaded_values = cascaded_values,
        };

        const current_stage = &@field(self.stage, @tagName(stage));
        inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
            _ = @field(current_stage.value_stack, field_info.name).pop();
        }

        self.resetElement(stage);
    }
}

pub fn getText(self: StyleComputer) zss.values.types.Text {
    return self.element_tree_slice.get(.text, self.stack.top.?.element) orelse "";
}

pub fn getSpecifiedValue(
    self: StyleComputer,
    comptime stage: Stage,
    comptime tag: aggregates.Tag,
) tag.Value() {
    const cascaded_values = self.stack.top.?.cascaded_values;
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
            const value_stack = @field(current_stage.value_stack, @tagName(tag));
            if (value_stack.items.len > 0) {
                self.value = value_stack.items[value_stack.items.len - 1];
            } else {
                self.value = Aggregate.initial_values;
            }
            return self.value.?;
        }
    };
}
