const zss = @import("zss");
const Ast = zss.syntax.Ast;
const Parser = zss.syntax.Parser;
const TokenSource = zss.syntax.TokenSource;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 2) return 1;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const input = blk: {
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
        break :blk try stdin_reader.interface.allocRemaining(allocator, .limited(1_000_000));
    };
    defer allocator.free(input);
    const source = try TokenSource.init(input);

    if (args.len == 1 or std.mem.eql(u8, args[1], "stylesheet")) {
        try runParser(Parser.parseCssStylesheet, source, allocator, stdout, stderr);
    } else if (std.mem.eql(u8, args[1], "zml")) {
        try runParser(Parser.parseZmlDocument, source, allocator, stdout, stderr);
    } else if (std.mem.eql(u8, args[1], "components")) {
        try runParser(Parser.parseListOfComponentValues, source, allocator, stdout, stderr);
    } else if (std.mem.eql(u8, args[1], "tokens")) {
        var location: TokenSource.Location = @enumFromInt(0);
        var i: usize = 0;
        while (true) {
            const token = try source.next(&location);
            try stdout.print("{}: {s}\n", .{ i, @tagName(token) });
            i += 1;
            if (token == .token_eof) break;
        }
        try stdout.flush();
    } else {
        return 1;
    }

    return 0;
}

fn runParser(
    parse_fn: *const fn (*Parser, Allocator) Parser.Error!struct { Ast, Ast.Index },
    source: TokenSource,
    allocator: Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var parser = zss.syntax.Parser.init(source, allocator);
    defer parser.deinit();

    var ast, _ = parse_fn(&parser, allocator) catch |err| {
        switch (err) {
            error.ParseError => {
                try stderr.print("error at location {}: {s}\n", .{ @intFromEnum(parser.failure.location), parser.failure.cause.debugErrMsg() });
                try stderr.flush();
            },
            else => {},
        }
        return err;
    };
    defer ast.deinit(allocator);

    try ast.debug.print(allocator, stdout);
    try stdout.flush();
}
