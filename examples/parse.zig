const zss = @import("zss");
const tokenize = zss.syntax.tokenize;
const parse = zss.syntax.parse;

const std = @import("std");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 2) return 1;

    var stdout = std.io.getStdOut().writer();

    const input = try std.io.getStdIn().reader().readAllAlloc(allocator, 1_000_000);
    defer allocator.free(input);

    if (args.len == 1 or std.mem.eql(u8, args[1], "stylesheet")) {
        const source = parse.Source.init(try tokenize.Source.init(input));
        var tree = try parse.parseCssStylesheet(source, allocator);
        defer tree.deinit(allocator);
        try zss.syntax.ComponentTree.debug.print(tree, allocator, stdout);
    } else if (std.mem.eql(u8, args[1], "tokenize")) {
        const source = try tokenize.Source.init(input);

        var location = tokenize.Source.Location{};
        var i: usize = 0;
        while (true) {
            const next = zss.syntax.tokenize.nextToken(source, location);
            location = next.next_location;
            i += 1;
            try stdout.print("{}: {s}\n", .{ i, @tagName(next.tag) });
            if (next.tag == .token_eof) break;
        }
    } else {
        return 1;
    }

    return 0;
}
