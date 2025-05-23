const zss = @import("zss");
const parse = zss.syntax.parse;
const TokenSource = zss.syntax.TokenSource;

const std = @import("std");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 2) return 1;

    var stdout = std.io.getStdOut().writer().any();

    const string = try std.io.getStdIn().reader().readAllAlloc(allocator, 1_000_000);
    defer allocator.free(string);

    if (args.len == 1 or std.mem.eql(u8, args[1], "stylesheet")) {
        const source = try TokenSource.init(string);
        var tree = try parse.parseCssStylesheet(source, allocator);
        defer tree.deinit(allocator);
        try tree.debug.print(allocator, stdout);
    } else if (std.mem.eql(u8, args[1], "zml")) {
        const source = try TokenSource.init(string);
        var parser = zss.zml.Parser.init(source, allocator);
        defer parser.deinit();

        var ast = parser.parse(allocator) catch |err| {
            switch (err) {
                error.ParseError => {
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("error at location {}: {s}\n", .{ @intFromEnum(parser.failure.location), parser.failure.cause.debugErrMsg() });
                },
                else => {},
            }
            return err;
        };
        defer ast.deinit(allocator);
        try ast.debug.print(allocator, stdout);
    } else if (std.mem.eql(u8, args[1], "components")) {
        const source = try TokenSource.init(string);
        var tree = try parse.parseListOfComponentValues(source, allocator);
        defer tree.deinit(allocator);
        try tree.debug.print(allocator, stdout);
    } else if (std.mem.eql(u8, args[1], "tokens")) {
        const source = try TokenSource.init(string);

        var location: TokenSource.Location = @enumFromInt(0);
        var i: usize = 0;
        while (true) {
            const token = try source.next(&location);
            try stdout.print("{}: {s}\n", .{ i, @tagName(token) });
            i += 1;
            if (token == .token_eof) break;
        }
    } else {
        return 1;
    }

    return 0;
}
