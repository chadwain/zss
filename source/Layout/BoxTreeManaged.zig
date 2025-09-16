const BoxTreeManaged = @This();

const std = @import("std");
const zss = @import("../zss.zig");

const BoxTree = zss.BoxTree;
const BackgroundImage = BoxTree.BackgroundImage;
const BackgroundImages = BoxTree.BackgroundImages;
const BlockRef = BoxTree.BlockRef;
const GeneratedBox = BoxTree.GeneratedBox;
const Ifc = BoxTree.InlineFormattingContext;
const Subtree = BoxTree.Subtree;

ptr: *BoxTree,

pub fn setGeneratedBox(box_tree: BoxTreeManaged, node: zss.Environment.NodeId, generated_box: GeneratedBox) !void {
    try box_tree.ptr.node_to_generated_box.putNoClobber(box_tree.ptr.allocator, node, generated_box);
}

pub fn newSubtree(box_tree: BoxTreeManaged) !*Subtree {
    const all_subtrees = &box_tree.ptr.subtrees;
    const id_int = std.math.cast(std.meta.Tag(Subtree.Id), all_subtrees.items.len) orelse return error.SizeLimitExceeded;

    try all_subtrees.ensureUnusedCapacity(box_tree.ptr.allocator, 1);
    const subtree = try box_tree.ptr.allocator.create(Subtree);
    all_subtrees.appendAssumeCapacity(subtree);
    subtree.* = .{ .id = @enumFromInt(id_int), .parent = null };
    return subtree;
}

pub fn appendBlockBox(box_tree: BoxTreeManaged, subtree: *Subtree) !Subtree.Size {
    const new_len = std.math.add(Subtree.Size, @intCast(subtree.blocks.len), 1) catch return error.SizeLimitExceeded;
    try subtree.blocks.resize(box_tree.ptr.allocator, new_len);
    return new_len - 1;
}

pub fn newIfc(box_tree: BoxTreeManaged, parent_block: BlockRef) !*Ifc {
    const all_ifcs = &box_tree.ptr.ifcs;
    const id_int = std.math.cast(std.meta.Tag(Ifc.Id), all_ifcs.items.len) orelse return error.SizeLimitExceeded;

    try all_ifcs.ensureUnusedCapacity(box_tree.ptr.allocator, 1);
    const ifc = try box_tree.ptr.allocator.create(Ifc);
    all_ifcs.appendAssumeCapacity(ifc);
    ifc.* = .{ .id = @enumFromInt(id_int), .parent_block = parent_block };
    return ifc;
}

pub fn appendInlineBox(box_tree: BoxTreeManaged, ifc: *Ifc) !Ifc.Size {
    const new_len = std.math.add(Ifc.Size, @intCast(ifc.inline_boxes.len), 1) catch return error.SizeLimitExceeded;
    try ifc.inline_boxes.resize(box_tree.ptr.allocator, new_len);
    return new_len - 1;
}

pub fn appendGlyph(box_tree: BoxTreeManaged, ifc: *Ifc, glyph: Ifc.GlyphIndex) !void {
    try ifc.glyphs.append(box_tree.ptr.allocator, .{ .index = glyph, .metrics = undefined });
}

/// This enum is derived from `Ifc.Special.Kind`
pub const SpecialGlyph = union(enum(u16)) {
    ZeroGlyphIndex = 1,
    BoxStart: Ifc.Size,
    BoxEnd: Ifc.Size,
    InlineBlock: Subtree.Size,
    /// Represents a mandatory line break in the text.
    /// data has no meaning.
    LineBreak,
};

pub fn appendSpecialGlyph(
    box_tree: BoxTreeManaged,
    ifc: *Ifc,
    comptime tag: std.meta.Tag(SpecialGlyph),
    data: @TypeOf(@field(@as(SpecialGlyph, undefined), @tagName(tag))),
) !void {
    const special: Ifc.Special = .{
        .kind = zss.meta.coerceEnum(Ifc.Special.Kind, tag),
        .data = switch (tag) {
            .ZeroGlyphIndex, .LineBreak => undefined,
            .BoxStart, .BoxEnd, .InlineBlock => data,
        },
    };
    try ifc.glyphs.append(box_tree.ptr.allocator, .{ .index = 0, .metrics = undefined });
    try ifc.glyphs.append(box_tree.ptr.allocator, .{ .index = @bitCast(special), .metrics = undefined });
}

pub fn appendLineBox(box_tree: BoxTreeManaged, ifc: *Ifc, line_box: Ifc.LineBox) !void {
    try ifc.line_boxes.append(box_tree.ptr.allocator, line_box);
}

pub fn allocBackgroundImages(box_tree: BoxTreeManaged, count: BackgroundImages.Size) !struct { BackgroundImages.Handle, []BackgroundImage } {
    const bi = &box_tree.ptr.background_images;
    const handle_int = std.math.add(std.meta.Tag(BackgroundImages.Handle), @intCast(bi.slices.items.len), 1) catch return error.SizeLimitExceeded;
    const begin: BackgroundImages.Size = @intCast(bi.images.items.len);
    const end = std.math.add(BackgroundImages.Size, begin, count) catch return error.SizeLimitExceeded;

    try bi.slices.ensureUnusedCapacity(box_tree.ptr.allocator, 1);
    const images = try bi.images.addManyAsSlice(box_tree.ptr.allocator, count);
    bi.slices.appendAssumeCapacity(.{ .begin = begin, .end = end });

    return .{ @enumFromInt(handle_int), images };
}
