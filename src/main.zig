// Import the standard library and its networking module
const std = @import("std");
const net = std.net;

const PORT = 4221;
const HOST = "127.0.0.1";

// The main entry point of the program
pub fn main() !void {
    // Get a writer for the standard output stream
    const stdout = std.io.getStdOut().writer();

    // Print a message to the standard output stream
    try stdout.print("Logs from your program will appear here!\n", .{});

    // Resolve the IP address and port number for the server
    const address = try net.Address.resolveIp(HOST, PORT);

    // Create a network listener for incoming connections
    var listener = try address.listen(.{
        // Reuse the address if it's already in use
        .reuse_address = true,
    });

    // Deinitialize the listener when the function returns
    defer listener.deinit();

    // Continuously listen for incoming connections
    while (true) {
        // Accept an incoming connection
        const client = try listener.accept();

        // Close the client's stream when the function returns
        defer client.stream.close();

        // Handle the client's request
        try handleClient(client);
    }
}

// Handle a client's request
fn handleClient(client: net.Server.Connection) !void {
    // Get a writer for the standard output stream
    const stdout = std.io.getStdOut().writer();

    // Create a buffer to store the client's request
    var buffer: [1024]u8 = undefined;

    // Read the client's request into the buffer
    const bytes_read = try client.stream.read(&buffer);

    // Get the client's request as a slice of bytes
    const request = buffer[0..bytes_read];

    // Split the request into lines
    var lines = std.mem.splitSequence(u8, request, "\r\n");

    // Get the first line of the request (the request method and URL)
    const first_line = lines.next() orelse return error.InvalidRequest;

    // Split the first line into parts (method, URL, and HTTP version)
    var parts = std.mem.splitSequence(u8, first_line, " ");

    // Get the request method
    _ = parts.next() orelse return error.InvalidRequest;

    // Get the URL path
    const path = parts.next() orelse return error.InvalidRequest;

    // Get the HTTP version
    _ = parts.next() orelse return error.InvalidRequest;

    // Initialize the User-Agent header value to null
    var user_agent: ?[]const u8 = null;

    // Iterate over the remaining lines of the request
    while (lines.next()) |line| {
        // Print the line to the standard output stream
        try stdout.print("{s}\n", .{line});

        // Check if the line is the User-Agent header
        if (std.mem.startsWith(u8, line, "User-Agent: ")) {
            // Extract the User-Agent value
            user_agent = line["User-Agent: ".len..];
            // Break out of the loop since we've found the User-Agent header
            break;
        }
    }

    // Handle the request based on the URL path
    if (std.mem.eql(u8, path, "/")) {
        // Handle the root URL
        try sendResponse(client, "200 OK", "text/plain", "");
    } else if (std.mem.startsWith(u8, path, "/echo/")) {
        // Handle the /echo/ URL
        const echo_path = path[6..];
        try sendResponse(client, "200 OK", "text/plain", echo_path);
    } else if (std.mem.eql(u8, path, "/user-agent")) {
        // Handle the /user-agent URL
        try sendResponse(client, "200 OK", "text/plain", user_agent orelse "");
    } else {
        // Handle unknown URLs
        try sendResponse(client, "404 Not Found", "text/plain", "");
    }
}

// Send a response to the client
fn sendResponse(client: net.Server.Connection, status: []const u8, content_type: []const u8, content: []const u8) !void {
    // Create a response string
    const response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, content_type, content.len, content });

    // Deallocate the response string when it's no longer needed
    defer std.heap.page_allocator.free(response);

    // Write the response to the client's stream
    try client.stream.writeAll(response);
}
