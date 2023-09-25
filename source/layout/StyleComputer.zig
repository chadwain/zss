const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const aggregates = zss.properties.aggregates;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const null_element = Element.null_element;
const CascadedValueStore = zss.CascadedValueStore;
const ViewportSize = zss.layout.ViewportSize;

const ElementIndex = undefined;
const root_element = undefined;

const hb = @import("harfbuzz");

const Self = @This();

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

const ThisElement = struct {
    element: Element,
    all: zss.values.All,
};

root_element: Element,
element_tree_slice: ElementTree.Slice,
cascaded_values: *const CascadedValueStore,
viewport_size: ViewportSize,
allocator: Allocator,

this_element: ThisElement = undefined,
element_stack: ArrayListUnmanaged(ThisElement) = .{},
child_stack: ArrayListUnmanaged(Element) = .{},

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
pub fn deinit(self: *Self) void {
    self.element_stack.deinit(self.allocator);
    self.child_stack.deinit(self.allocator);
}

pub fn assertEmptyStage(self: Self, comptime stage: Stage) void {
    assert(self.element_stack.items.len == 0);
    assert(self.child_stack.items.len == 0);
    const current_stage = &@field(self.stage, @tagName(stage));
    inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
        assert(@field(current_stage.value_stack, field_info.name).items.len == 0);
    }
}

pub fn deinitStage(self: *Self, comptime stage: Stage) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
        @field(current_stage.value_stack, field_info.name).deinit(self.allocator);
    }
}

pub fn setElementDirectChild(self: *Self, comptime stage: Stage, child: Element) void {
    assert(self.element_stack.items.len == 0 or
        self.element_tree_slice.parent(child).eql(self.element_stack.items[self.element_stack.items.len - 1].element));

    self.this_element = .{
        .element = child,
        .all = if (self.cascaded_values.all.get(child)) |value| value.all else .undeclared,
    };

    const current_stage = &@field(self.stage, @tagName(stage));
    current_stage.current_flags = .{};
    current_stage.current_values = undefined;
}

// pub fn setElementAny(self: *Self, comptime stage: Stage, child: ElementIndex) !void {
//     const parent = parent: {
//         while (self.element_stack.items.len > 0) {
//             const element = self.element_stack.items[self.element_stack.items.len - 1].index;
//             if (child >= element + 1 and child < element + self.element_tree_skips[element]) {
//                 break :parent element;
//             } else {
//                 self.popElement(stage);
//             }
//         } else {
//             break :parent root_element;
//         }
//     };
//
//     var iterator = zss.SkipTreeIterator(ElementIndex).init(parent, self.element_tree_skips);
//     while (iterator.index != child) : (iterator = iterator.firstChild(self.element_tree_skips).nextParent(child, self.element_tree_skips)) {
//         assert(!iterator.empty());
//         self.setElementDirectChild(stage, iterator.index);
//         try self.computeAndPushElement(stage);
//     }
//
//     assert(iterator.index == child);
//     self.setElementDirectChild(stage, child);
// }

pub fn setComputedValue(self: *Self, comptime stage: Stage, comptime tag: aggregates.Tag, value: tag.Value()) void {
    const current_stage = &@field(self.stage, @tagName(stage));
    const flag = &@field(current_stage.current_flags, @tagName(tag));
    assert(!flag.*);
    flag.* = true;
    @field(current_stage.current_values, @tagName(tag)) = value;
}

pub fn pushElement(self: *Self, comptime stage: Stage) !void {
    try self.element_stack.append(self.allocator, self.this_element);
    try self.child_stack.append(self.allocator, self.element_tree_slice.firstChild(self.this_element.element));

    const current_stage = &@field(self.stage, @tagName(stage));
    const values = current_stage.current_values;
    const flags = current_stage.current_flags;

    inline for (std.meta.fields(@TypeOf(flags))) |field_info| {
        const flag = @field(flags, field_info.name);
        assert(flag);
        const value = @field(values, field_info.name);
        try @field(current_stage.value_stack, field_info.name).append(self.allocator, value);
    }
}

pub fn computeAndPushElement(self: *Self, comptime stage: Stage) !void {
    const current_stage = &@field(self.stage, @tagName(stage));
    inline for (std.meta.fields(@TypeOf(current_stage.current_values))) |field_info| {
        @setEvalBranchQuota(10000);
        const tag = comptime std.meta.stringToEnum(aggregates.Tag, field_info.name).?;
        const specified = self.getSpecifiedValue(stage, tag);
        const computed = try self.compute(stage, tag, specified);
        self.setComputedValue(stage, tag, computed);
    }
    try self.pushElement(stage);
}

pub fn popElement(self: *Self, comptime stage: Stage) void {
    _ = self.element_stack.pop();
    _ = self.child_stack.pop();

    const current_stage = &@field(self.stage, @tagName(stage));

    inline for (std.meta.fields(@TypeOf(current_stage.value_stack))) |field_info| {
        _ = @field(current_stage.value_stack, field_info.name).pop();
    }
}

pub fn getText(self: Self) zss.values.Text {
    return if (self.cascaded_values.text.get(self.this_element.element)) |value| value.text else "";
}

pub fn getSpecifiedValue(
    self: Self,
    comptime stage: Stage,
    comptime tag: aggregates.Tag,
) tag.Value() {
    const Value = tag.Value();
    const inheritance_type = comptime tag.inheritanceType();

    // Find the value using the cascaded value tree.
    // TODO: This always uses a binary search to look for values. There might be more efficient/complicated ways to do this.
    const store = @field(self.cascaded_values, @tagName(tag));
    var cascaded_value = store.get(self.this_element.element);
    if (cascaded_value) |*value| {
        if (tag == .color) {
            // CSS-COLOR-3§4.4: If the ‘currentColor’ keyword is set on the ‘color’ property itself, it is treated as ‘color: inherit’.
            if (value.color == .current_color) {
                value.color = .inherit;
            }
        }
    }

    const default: enum { inherit, initial } = default: {
        // Use the value of the 'all' property.
        // CSS-CASCADE-4§3.2: The all property is a shorthand that resets all CSS properties except direction and unicode-bidi.
        //                    [...] It does not reset custom properties.
        // TODO: The 'all' property should not be used in this way.
        if (tag != .direction and tag != .unicode_bidi and tag != .custom) {
            switch (self.this_element.all) {
                .initial => break :default .initial,
                .inherit => break :default .inherit,
                .unset, .undeclared => {},
            }
        }

        // Just use the inheritance type.
        switch (inheritance_type) {
            .inherited => break :default .inherit,
            .not_inherited => break :default .initial,
        }
    };

    const initial_value = Value.initial_values;
    if (cascaded_value == null and default == .initial) {
        return initial_value;
    }

    const inherited_value = inherited_value: {
        const current_stage = @field(self.stage, @tagName(stage));
        const value_stack = @field(current_stage.value_stack, @tagName(tag));
        if (value_stack.items.len > 0) {
            break :inherited_value value_stack.items[value_stack.items.len - 1];
        } else {
            break :inherited_value initial_value;
        }
    };
    if (cascaded_value == null and default == .inherit) {
        return inherited_value;
    }

    inline for (std.meta.fields(Value)) |field_info| {
        const sub_property = &@field(cascaded_value.?, field_info.name);
        switch (sub_property.*) {
            .inherit => sub_property.* = @field(inherited_value, field_info.name),
            .initial => sub_property.* = @field(initial_value, field_info.name),
            .unset => switch (inheritance_type) {
                .inherited => sub_property.* = @field(inherited_value, field_info.name),
                .not_inherited => sub_property.* = @field(initial_value, field_info.name),
            },
            // TODO: Make this a switch statement
            .undeclared => if (default == .inherit) {
                sub_property.* = @field(inherited_value, field_info.name);
            } else {
                sub_property.* = @field(initial_value, field_info.name);
            },
            else => {},
        }
    }

    return cascaded_value.?;
}

fn compute(self: Self, comptime stage: Stage, comptime tag: aggregates.Tag, specified: tag.Value()) !tag.Value() {
    {
        const current_stage = @field(self.stage, @tagName(stage));
        if (@field(current_stage.current_flags, @tagName(tag))) {
            return @field(current_stage.current_values, @tagName(tag));
        }
    }

    const solve = @import("./solve.zig");

    switch (tag) {
        .box_style => if (self.this_element.index == root_element) {
            return solve.boxStyle(specified, .Root);
        } else {
            return solve.boxStyle(specified, .NonRoot);
        },
        .content_width, .content_height => return aggregates.ContentSize{
            .size = switch (specified.size) {
                .px => |value| .{ .px = value },
                .percentage => |value| .{ .percentage = value },
                .auto => .auto,
                .initial, .inherit, .unset, .undeclared => unreachable,
            },
            .min_size = switch (specified.min_size) {
                .px => |value| .{ .px = value },
                .percentage => |value| .{ .percentage = value },
                .initial, .inherit, .unset, .undeclared => unreachable,
            },
            .max_size = switch (specified.max_size) {
                .px => |value| .{ .px = value },
                .percentage => |value| .{ .percentage = value },
                .none => .none,
                .initial, .inherit, .unset, .undeclared => unreachable,
            },
        },
        .horizontal_edges, .vertical_edges => {
            const border_styles = try self.compute(stage, .border_styles, self.getSpecifiedValue(stage, .border_styles));
            return aggregates.BoxEdges{
                .padding_start = switch (specified.padding_start) {
                    .px => |value| .{ .px = value },
                    .percentage => |value| .{ .percentage = value },
                    .initial, .inherit, .unset, .undeclared => unreachable,
                },
                .padding_end = switch (specified.padding_end) {
                    .px => |value| .{ .px = value },
                    .percentage => |value| .{ .percentage = value },
                    .initial, .inherit, .unset, .undeclared => unreachable,
                },
                .border_start = blk: {
                    const multiplier = solve.borderWidthMultiplier(if (tag == .horizontal_edges) border_styles.left else border_styles.top);
                    break :blk @as(zss.values.BorderWidth, switch (specified.border_start) {
                        .px => |value| .{ .px = value },
                        .thin => .{ .px = solve.borderWidth(.thin) * multiplier },
                        .medium => .{ .px = solve.borderWidth(.medium) * multiplier },
                        .thick => .{ .px = solve.borderWidth(.thick) * multiplier },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    });
                },
                .border_end = blk: {
                    const multiplier = solve.borderWidthMultiplier(if (tag == .horizontal_edges) border_styles.right else border_styles.bottom);
                    break :blk @as(zss.values.BorderWidth, switch (specified.border_end) {
                        .px => |value| .{ .px = value },
                        .thin => .{ .px = solve.borderWidth(.thin) * multiplier },
                        .medium => .{ .px = solve.borderWidth(.medium) * multiplier },
                        .thick => .{ .px = solve.borderWidth(.thick) * multiplier },
                        .initial, .inherit, .unset, .undeclared => unreachable,
                    });
                },
                .margin_start = switch (specified.margin_start) {
                    .px => |value| .{ .px = value },
                    .percentage => |value| .{ .percentage = value },
                    .auto => .auto,
                    .initial, .inherit, .unset, .undeclared => unreachable,
                },
                .margin_end = switch (specified.margin_end) {
                    .px => |value| .{ .px = value },
                    .percentage => |value| .{ .percentage = value },
                    .auto => .auto,
                    .initial, .inherit, .unset, .undeclared => unreachable,
                },
            };
        },
        .border_styles => return specified,
        .z_index => return aggregates.ZIndex{
            .z_index = switch (specified.z_index) {
                .integer => |value| .{ .integer = value },
                .auto => .auto,
                .initial, .inherit, .unset, .undeclared => unreachable,
            },
        },
        .font => return aggregates.Font{
            .font = switch (specified.font) {
                .font => |font| .{ .font = font },
                .zss_default => .zss_default,
                .initial, .inherit, .unset, .undeclared => unreachable,
            },
        },
        .border_colors,
        .background1,
        .background2,
        .color,
        .insets,
        .direction,
        .unicode_bidi,
        .custom,
        => @compileError("TODO: compute(" ++ @typeName(tag.Value()) ++ ")"),
    }
}
