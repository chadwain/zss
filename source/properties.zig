pub const aggregates = @import("properties/aggregates.zig");
pub const definitions = @import("properties/definitions.zig");
pub const parse = @import("properties/parse.zig");
pub const parsers = @import("properties/parsers.zig");

comptime {
    if (@import("builtin").is_test) {
        _ = parsers;
    }
}
