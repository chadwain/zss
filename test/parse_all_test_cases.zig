const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const zss = @import("zss");

pub fn main() !void {
    @setRuntimeSafety(true);

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    const cwd = std.fs.cwd();
    const input_dir = try cwd.openDir(args[1], .{ .iterate = true });
    const output_dir = try cwd.openDir(args[2], .{});

    var walker = try input_dir.walk(std.heap.page_allocator);
    defer walker.deinit();

    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zml")) continue;
        errdefer std.debug.print("Error while parsing zml file: {s}\n", .{entry.path});
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        const in_text = try input_dir.readFileAlloc(allocator, entry.path, 100_000);
        const out_text = try parseZml(in_text, &arena);

        var comp_iter = try std.fs.path.componentIterator(entry.path);
        _ = comp_iter.last().?;
        if (comp_iter.previous()) |parent| {
            try output_dir.makePath(parent.path);
        }
        const out_file_name = try std.mem.concat(allocator, u8, &.{ entry.path, "-ast" });
        const out_file = try output_dir.createFile(out_file_name, .{});
        defer out_file.close();
        try out_file.writeAll(out_text);
    }
}

fn parseZml(text: []const u8, arena: *ArenaAllocator) ![]u8 {
    const allocator = arena.allocator();
    var ast = zss.syntax.Ast{};

    const token_source = try zss.syntax.tokenize.Source.init(.{ .data = text });
    var parser = zss.zml.Parser.init(token_source, allocator);
    try parser.parse(&ast, allocator);

    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer().any();
    try zss.syntax.Ast.debug.serialize(ast, writer);
    try writer.writeAll(text);
    return buffer.toOwnedSlice();
}
