const std = @import("std");

const zss = @import("../../zss.zig");
const BlockRenderingContext = @import("BlockRenderingContext.zig");
const InlineFormattingContext = @import("InlineFormattingContext.zig");

pub const StackingContext = struct {
    midpoint: usize,
    offset: zss.types.Offset,
    clip_rect: zss.types.CSSRect,
    inner_context: union(enum) {
        block: *const BlockRenderingContext,
        inl: struct {
            context: *const InlineFormattingContext,
        },
    },
};

pub const StackingContextId = []const StackingContextIdPart;
pub const StackingContextIdPart = u16;
const PrefixTreeMapUnmanaged = @import("prefix-tree-map").PrefixTreeMapUnmanaged;
fn idCmpFn(lhs: StackingContextIdPart, rhs: StackingContextIdPart) std.math.Order {
    return std.math.order(lhs, rhs);
}
pub const StackingContextTree = PrefixTreeMapUnmanaged(StackingContextIdPart, StackingContext, idCmpFn);
