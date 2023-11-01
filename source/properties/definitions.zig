const AggregateTag = @import("./aggregates.zig").Tag;

pub const Property = union(enum) {
    all,
    simple: SimpleProperty,
};

pub const SimpleProperty = struct {
    aggregate_tag: AggregateTag,
    field: @Type(.EnumLiteral),
};

fn simpleProperty(comptime aggregate_tag: AggregateTag, comptime field: @Type(.EnumLiteral)) SimpleProperty {
    return SimpleProperty{ .aggregate_tag = aggregate_tag, .field = field };
}

pub const PropertyName = enum {
    all,
    display,
    position,
    float,
    @"z-index",
    width,
    @"min-width",
    @"max-width",
    height,
    @"min-height",
    @"max-height",
    @"padding-left",
    @"padding-right",
    @"padding-top",
    @"padding-bottom",
    @"border-left-width",
    @"border-right-width",
    @"border-top-width",
    @"border-bottom-width",
    @"margin-left",
    @"margin-right",
    @"margin-top",
    @"margin-bottom",
    left,
    right,
    top,
    bottom,

    pub fn definition(comptime property_name: PropertyName) Property {
        return comptime switch (property_name) {
            .all => .all,
            .display => .{ .simple = display },
            .position => .{ .simple = position },
            .float => .{ .simple = float },
            .@"z-index" => .{ .simple = z_index },
            .width => .{ .simple = width },
            .@"min-width" => .{ .simple = min_width },
            .@"max-width" => .{ .simple = max_width },
            .height => .{ .simple = height },
            .@"min-height" => .{ .simple = min_height },
            .@"max-height" => .{ .simple = max_height },
            .@"padding-left" => .{ .simple = padding_left },
            .@"padding-right" => .{ .simple = padding_right },
            .@"padding-top" => .{ .simple = padding_top },
            .@"padding-bottom" => .{ .simple = padding_bottom },
            .@"border-left-width" => .{ .simple = border_left_width },
            .@"border-right-width" => .{ .simple = border_right_width },
            .@"border-top-width" => .{ .simple = border_top_width },
            .@"border-bottom-width" => .{ .simple = border_bottom_width },
            .@"margin-left" => .{ .simple = margin_left },
            .@"margin-right" => .{ .simple = margin_right },
            .@"margin-top" => .{ .simple = margin_top },
            .@"margin-bottom" => .{ .simple = margin_bottom },
            .left => .{ .simple = left },
            .right => .{ .simple = right },
            .top => .{ .simple = top },
            .bottom => .{ .simple = bottom },
        };
    }
};

// zig fmt: off
pub const display =             simpleProperty(.box_style       , .display       );
pub const position =            simpleProperty(.box_style       , .position      );
pub const float =               simpleProperty(.box_style       , .float         );
pub const z_index =             simpleProperty(.z_index         , .z_index       );
pub const width =               simpleProperty(.content_width   , .width         );
pub const min_width =           simpleProperty(.content_width   , .min_width     );
pub const max_width =           simpleProperty(.content_width   , .max_width     );
pub const height =              simpleProperty(.content_height  , .height        );
pub const min_height =          simpleProperty(.content_height  , .min_height    );
pub const max_height =          simpleProperty(.content_height  , .max_height    );
pub const padding_left =        simpleProperty(.horizontal_edges, .padding_left  );
pub const padding_right =       simpleProperty(.horizontal_edges, .padding_right );
pub const padding_top =         simpleProperty(.vertical_edges  , .padding_top   );
pub const padding_bottom =      simpleProperty(.vertical_edges  , .padding_bottom);
pub const border_left_width =   simpleProperty(.horizontal_edges, .border_left   );
pub const border_right_width =  simpleProperty(.horizontal_edges, .border_right  );
pub const border_top_width =    simpleProperty(.vertical_edges  , .border_top    );
pub const border_bottom_width = simpleProperty(.vertical_edges  , .border_bottom );
pub const margin_left =         simpleProperty(.horizontal_edges, .margin_left   );
pub const margin_right =        simpleProperty(.horizontal_edges, .margin_right  );
pub const margin_top =          simpleProperty(.vertical_edges  , .margin_top    );
pub const margin_bottom =       simpleProperty(.vertical_edges  , .margin_bottom );
pub const left =                simpleProperty(.insets          , .left          );
pub const right =               simpleProperty(.insets          , .right         );
pub const top =                 simpleProperty(.insets          , .top           );
pub const bottom =              simpleProperty(.insets          , .bottom        );
