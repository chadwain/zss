const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../zss.zig");
const CascadedValues = zss.CascadedValues;
const Environment = zss.Environment;
const NodeId = Environment.NodeId;
const Stack = zss.Stack;

const groups = zss.values.groups;
const SpecifiedValues = groups.Tag.SpecifiedValues;
const ComputedValues = groups.Tag.ComputedValues;

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
    node: NodeId,
    cascaded_values: CascadedValues,
};

env: *const Environment,
current: Current,
allocator: Allocator,
stage: union {
    box_gen: struct {
        map: std.AutoHashMapUnmanaged(NodeId, BoxGenComputedValues) = .{},
        current_computed: BoxGenComputedValues = undefined,
    },
    cosmetic: struct {
        map: std.AutoHashMapUnmanaged(NodeId, CosmeticComputedValues) = .{},
        current_computed: CosmeticComputedValues = undefined,
    },
},

pub fn init(env: *const Environment, allocator: Allocator) StyleComputer {
    return .{
        .env = env,
        .allocator = allocator,
        .current = undefined,
        .stage = undefined,
    };
}

pub fn deinit(self: *StyleComputer) void {
    _ = self;
}

pub fn deinitStage(sc: *StyleComputer, comptime stage: Stage) void {
    const current_stage = &@field(sc.stage, @tagName(stage));
    current_stage.map.deinit(sc.allocator);
}

// TODO: Setting the current node should not require allocating
pub fn setCurrentNode(sc: *StyleComputer, comptime stage: Stage, node: NodeId) !void {
    const cascaded_values = switch (sc.env.getNodeProperty(.category, node)) {
        .element => sc.env.getNodeProperty(.cascaded_values, node),
        .text => undefined,
    };
    sc.current = .{
        .node = node,
        .cascaded_values = cascaded_values,
    };

    const current_stage = &@field(sc.stage, @tagName(stage));
    const gop_result = try current_stage.map.getOrPut(sc.allocator, node);
    if (!gop_result.found_existing) {
        gop_result.value_ptr.* = .{};
    }
    current_stage.current_computed = gop_result.value_ptr.*;
}

pub fn commitNode(sc: *StyleComputer, comptime stage: Stage) void {
    const node = sc.current.node;
    const current_stage = &@field(sc.stage, @tagName(stage));
    current_stage.map.putAssumeCapacity(node, current_stage.current_computed);
}

pub fn getText(sc: StyleComputer) []const u8 {
    const node = sc.current.node;
    assert(sc.env.getNodeProperty(.category, node) == .text);
    const id = sc.env.getNodeProperty(.text, node);
    return sc.env.getText(id);
}

pub fn getTextFont(sc: StyleComputer, comptime stage: Stage) ComputedValues(.font) {
    const node = sc.current.node;
    assert(sc.env.getNodeProperty(.category, node) == .text);
    var inherited_value = InheritedValue(.font){ .node = node };
    return inherited_value.get(sc, stage);
}

pub fn setComputedValue(sc: *StyleComputer, comptime stage: Stage, comptime group: groups.Tag, value: ComputedValues(group)) void {
    const current_stage = &@field(sc.stage, @tagName(stage));
    const field = &@field(current_stage.current_computed, @tagName(group));
    assert(field.* == null);
    field.* = value;
}

pub fn getSpecifiedValue(sc: StyleComputer, comptime stage: Stage, comptime group: groups.Tag) SpecifiedValues(group) {
    return sc.getSpecifiedValueForElement(stage, group, sc.current.node, sc.current.cascaded_values);
}

fn getSpecifiedValueForElement(
    self: StyleComputer,
    comptime stage: Stage,
    comptime group: groups.Tag,
    node: NodeId,
    cascaded_values: CascadedValues,
) SpecifiedValues(group) {
    assert(self.env.getNodeProperty(.category, node) == .element);
    const cascaded_value = cascaded_values.getPtr(group);

    const inheritance_type = comptime group.inheritanceType();
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

    const initial_value = group.initialValues();
    if (cascaded_value == null and default == .initial) {
        return initial_value;
    }

    var inherited_value = InheritedValue(group){ .node = node };
    if (cascaded_value == null and default == .inherit) {
        return inherited_value.get(self, stage);
    }

    var specified: SpecifiedValues(group) = undefined;
    inline for (group.fields()) |field| {
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

fn InheritedValue(comptime group: groups.Tag) type {
    return struct {
        value: ?ComputedValues(group) = null,
        node: NodeId,

        fn get(self: *@This(), sc: StyleComputer, comptime stage: Stage) ComputedValues(group) {
            if (self.value) |value| return value;

            const current_stage = @field(sc.stage, @tagName(stage));
            self.value = if (self.node.parent(sc.env)) |parent| blk: { // TODO: Should check for equality with the root node instead
                if (current_stage.map.get(parent)) |parent_computed_values| {
                    if (@field(parent_computed_values, @tagName(group))) |inherited_value| {
                        break :blk inherited_value;
                    }
                }
                // TODO: Cache the parent's computed value for faster access in future calls.

                const cascaded_values = sc.env.getNodeProperty(.cascaded_values, parent);
                // TODO: Recursive call here
                const specified_value = sc.getSpecifiedValueForElement(stage, group, parent, cascaded_values);
                break :blk specifiedToComputed(group, specified_value, sc, parent);
            } else group.initialValues();
            return self.value.?;
        }
    };
}

/// Given a specified value, returns a computed value.
fn specifiedToComputed(comptime group: groups.Tag, specified: SpecifiedValues(group), sc: StyleComputer, node: NodeId) ComputedValues(group) {
    switch (group) {
        .box_style => {
            const parent = node.parent(sc.env);
            const computed_value, _ = if (parent == null) // TODO: Should check for equality with the root node instead
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
        else => std.debug.panic("TODO: specifiedToComputed for aggregate '{s}'", .{@tagName(group)}),
    }
}
