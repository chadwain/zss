const zss = @import("../../zss.zig");
const types = zss.types;
const CSSUnit = types.CSSUnit;
const BoxOffsets = types.BoxOffsets;
const Percentage = types.Percentage;

/// Contains the used value of the 'width' and 'height' properties.
pub const Dimension = struct {
    width: CSSUnit = 0,
    height: CSSUnit = 0,
};

/// Contains the used values of the properties 'border-top-width',
/// 'border-right-width', 'border-bottom-width', and 'border-left-width'.
pub const Borders = struct {
    top: CSSUnit = 0,
    right: CSSUnit = 0,
    bottom: CSSUnit = 0,
    left: CSSUnit = 0,
};

/// Contains the used values of the properties 'padding-top',
/// 'padding-right', 'padding-bottom', and 'padding-left'.
pub const Padding = struct {
    top: CSSUnit = 0,
    right: CSSUnit = 0,
    bottom: CSSUnit = 0,
    left: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-left', and
/// 'margin-right'.
pub const MarginLeftRight = struct {
    left: CSSUnit = 0,
    right: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-top', and
/// 'margin-bottom'.
pub const MarginTopBottom = struct {
    top: CSSUnit = 0,
    bottom: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-left',
/// 'margin-right', 'border-left-width', 'border-right-width',
/// 'padding-left', and 'padding-right'.
pub const MarginBorderPaddingLeftRight = struct {
    margin_left: CSSUnit = 0,
    margin_right: CSSUnit = 0,
    border_left: CSSUnit = 0,
    border_right: CSSUnit = 0,
    padding_left: CSSUnit = 0,
    padding_right: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-top',
/// 'margin-bottom', 'border-top-width', 'border-bottom-width',
/// 'padding-top', and 'padding-bottom'.
pub const MarginBorderPaddingTopBottom = struct {
    margin_top: CSSUnit = 0,
    margin_bottom: CSSUnit = 0,
    border_top: CSSUnit = 0,
    border_bottom: CSSUnit = 0,
    padding_top: CSSUnit = 0,
    padding_bottom: CSSUnit = 0,
};

/// Contains the used values of the properties 'border-top-color',
/// 'border-right-color', 'border-bottom-color', and 'border-left-color'.
pub const BorderColor = struct {
    top_rgba: u32 = 0,
    right_rgba: u32 = 0,
    bottom_rgba: u32 = 0,
    left_rgba: u32 = 0,
};

/// Contains the used value of the 'background-color' property.
pub const BackgroundColor = struct {
    rgba: u32 = 0,
};

pub const BackgroundImage = struct {
    pub const Data = *opaque {};
    pub const Repeat = enum { None, Repeat, Space };

    image: ?Data = null,
    origin: enum { Padding, Border, Content } = .Padding,
    clip: enum { Padding, Border, Content } = .Border,
    position: struct { horizontal: Percentage = 0, vertical: Percentage = 0 } = .{},
    size: struct { width: Percentage = 1.0, height: Percentage = 1.0 } = .{},
    repeat: struct { x: Repeat = .None, y: Repeat = .None } = .{},
};

/// Contains the used value of the properties 'overflow' and 'visibility'.
pub const VisualEffect = struct {
    overflow: enum { Visible, Hidden } = .Visible,
    visibility: enum { Visible, Hidden } = .Visible,
};

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BlockRenderingData = struct {
    pub const InlineData = struct {
        data: *InlineRenderingData,
        id_of_containing_block: u16,
    };

    pdfs_flat_tree: []u16,
    box_offsets: []BoxOffsets,
    borders: []Borders,
    border_colors: []BorderColor,
    background_color: []BackgroundColor,
    background_image: []BackgroundImage,
    visual_effect: []VisualEffect,
    inline_data: []InlineData,

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.pdfs_flat_tree);
        allocator.free(self.box_offsets);
        allocator.free(self.borders);
        allocator.free(self.border_colors);
        allocator.free(self.background_color);
        allocator.free(self.background_image);
        allocator.free(self.visual_effect);
        for (self.inline_data) |*inl| {
            inl.data.deinit(allocator);
            allocator.destroy(inl.data);
        }
        allocator.free(self.inline_data);
    }
};

pub const InlineRenderingData = struct {
    const hb = @import("harfbuzz");

    pub const BoxMeasures = struct {
        border: CSSUnit = 0,
        padding: CSSUnit = 0,
        border_color_rgba: u32 = 0,
    };

    pub const Heights = struct {
        above_baseline: CSSUnit,
        below_baseline: CSSUnit,
    };

    pub const LineBox = struct {
        baseline: CSSUnit,
        elements: [2]usize,
    };

    pub const special_index = 0xFFFF;
    pub const SpecialMeaning = enum { BoxStart, BoxEnd, Literal_FFFF };

    // NOTE may need to make sure this is never a valid glyph index when bitcasted
    pub const Special = struct {
        meaning: SpecialMeaning,
        id: u16,
    };

    pub fn encodeSpecial(comptime meaning: SpecialMeaning, id: u16) hb.hb_codepoint_t {
        const result = Special{ .meaning = meaning, .id = id };
        return @bitCast(hb.hb_codepoint_t, result);
    }

    pub fn decodeSpecial(glyph_index: hb.hb_codepoint_t) Special {
        return @bitCast(Special, glyph_index);
    }

    pub const Position = struct {
        // NOTE It seems that offset is 0 almost all the time, maybe no need to record it.
        offset: CSSUnit,
        advance: CSSUnit,
        width: CSSUnit,
    };

    // TODO add data to keep track of which boxes are positioned boxes.
    // positioned boxes must be rendered after all other boxes

    glyph_indeces: []hb.hb_codepoint_t,
    positions: []Position,
    line_boxes: []LineBox,
    // TODO one global font for the entire context. should be removed at some point.
    font: *hb.hb_font_t,

    // per inline element
    measures_top: []BoxMeasures,
    measures_right: []BoxMeasures,
    measures_bottom: []BoxMeasures,
    measures_left: []BoxMeasures,
    heights: []Heights,
    background_color: []BackgroundColor,
    // TODO
    // background_image: []BackgroundImage,

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.glyph_indeces);
        allocator.free(self.positions);
        allocator.free(self.line_boxes);
        allocator.free(self.measures_top);
        allocator.free(self.measures_right);
        allocator.free(self.measures_bottom);
        allocator.free(self.measures_left);
        allocator.free(self.heights);
        allocator.free(self.background_color);
    }

    pub fn dump(self: *const @This()) void {
        const p = std.debug.print;
        p("\n", .{});
        p("glyphs\n", .{});
        var i: usize = 0;
        while (i < self.glyph_indeces.len) : (i += 1) {
            const gi = self.glyph_indeces[i];
            if (gi == special_index) {
                i += 1;
                p("{}\n", .{decodeSpecial(self.glyph_indeces[i])});
            } else {
                p("{x}\n", .{gi});
            }
        }
        p("\n", .{});
        p("positions\n", .{});
        i = 0;
        while (i < self.positions.len) : (i += 1) {
            const pos = self.positions[i];
            p("{}\n", .{pos});
            if (self.glyph_indeces[i] == special_index) {
                i += 1;
            }
        }
        p("\n", .{});
        p("line boxes\n", .{});
        for (self.line_boxes) |l| {
            p("{}\n", .{l});
        }
    }
};
