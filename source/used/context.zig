const std = @import("std");

pub const ContextSpecificBoxId = []const ContextSpecificBoxIdPart;
pub const ContextSpecificBoxIdPart = u16;

pub fn cmpPart(lhs: ContextSpecificBoxIdPart, rhs: ContextSpecificBoxIdPart) std.math.Order {
    return std.math.order(lhs, rhs);
}
