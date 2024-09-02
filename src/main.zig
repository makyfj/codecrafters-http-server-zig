const std = @import("std");
const net = std.net;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // You can use print statements as follows for debugging, they'll be visible when running tests.
    try stdout.print("Logs from your program will appear here!\n", .{});

    // Uncomment this block to pass the first stage
    const address = try net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const client = try listener.accept();

    // Create a buffer to read the client's request
    var buffer: [1024]u8 = undefined;

    const bytes_read = try client.stream.read(&buffer);
    const request = buffer[0..bytes_read];

    // Parse the request
    var lines = std.mem.splitSequence(u8, request, "\r\n");

    const first_line = lines.next() orelse return error.InvalidRequest;
    var parts = std.mem.split(u8, first_line, " ");
    _ = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;
    _ = parts.next() orelse return error.InvalidRequest;

    if (std.mem.eql(u8, path, "/abcdefg")) {
        try client.stream.writeAll("HTTP/1.1 404 Not Found\r\n\r\n");
    }

    if (std.mem.eql(u8, path, "/")) {
        try client.stream.writeAll("HTTP/1.1 200 OK\r\n\r\n");
    } else {
        try client.stream.writeAll("HTTP/1.1 400 Not Found\r\n\r\n");
    }

    // Send a response to the client
    // try client.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!");
}
