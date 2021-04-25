pub const Test = struct {
    name: []const u8,
    root: []const u8,
};

pub const tests = [_]Test{
    //Test{ .name = "block_format", .root = "block_formatting.zig" },
    Test{ .name = "inline_format", .root = "inline_formatting.zig" },
};
