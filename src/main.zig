const std = @import("std");
const net = std.net;

const PORT = 4221;
const HOST = "127.0.0.1";

var files_directory: []const u8 = undefined;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Parse command line arguments
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len >= 3 and std.mem.eql(u8, args[1], "--directory")) {
        files_directory = args[2];
        try stdout.print("Files directory: {s}\n", .{files_directory});
    } else {
        try stdout.print("No directory specified. File serving will be disabled.\n", .{});
    }

    const address = try net.Address.resolveIp(HOST, PORT);

    var listener = try address.listen(.{
        .reuse_address = true,
    });

    defer listener.deinit();

    while (true) {
        const client = try listener.accept();

        // Allocate memory for the client connection
        const client_ptr = try std.heap.page_allocator.create(net.Server.Connection);
        client_ptr.* = client;

        // Create a new thread to handle the client
        const thread = try std.heap.page_allocator.create(std.Thread);
        errdefer std.heap.page_allocator.destroy(thread);

        thread.* = try std.Thread.spawn(.{}, handleClientThread, .{client_ptr});
    }
}

fn handleClientThread(client_ptr: *net.Server.Connection) void {
    defer std.heap.page_allocator.destroy(client_ptr);

    handleClient(client_ptr.*) catch |err| {
        std.debug.print("Error handling client: {s}\n", .{@errorName(err)});
    };
    client_ptr.stream.close();
}

fn handleClient(client: net.Server.Connection) !void {
    // Create a buffer to store the client's request
    var buffer: [4096]u8 = undefined;

    // Read the client's request into the buffer
    const bytes_read = try client.stream.read(&buffer);

    // Get the client's request as a slice of bytes
    const request = buffer[0..bytes_read];

    var lines = std.mem.splitSequence(u8, request, "\r\n");

    // Get the first line of the request (the request method and URL)
    const first_line = lines.next() orelse return error.InvalidRequest;

    // Split the first line into parts (method, URL, and HTTP version)
    var parts = std.mem.splitSequence(u8, first_line, " ");

    // Request method
    const method = parts.next() orelse return error.InvalidRequest;

    // URL path
    const path = parts.next() orelse return error.InvalidRequest;

    // HTTP version
    _ = parts.next() orelse return error.InvalidRequest;

    var user_agent: ?[]const u8 = null;
    var content_length: ?usize = null;
    var accept_encoding: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "User-Agent: ")) {
            user_agent = line["User-Agent: ".len..];
        } else if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            const encoding_header = line["Accept-Encoding: ".len..];
            try std.io.getStdOut().writer().print("Accept-Encoding header: {s}\n", .{encoding_header});
            content_length = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, line, "Accept-Encoding: ")) {
            if (std.mem.indexOf(u8, line["Accept-Encoding: ".len..], "gzip") != null) {
                accept_encoding = "gzip";
            }
        }
    }

    // Read the request body if Content-Length is present
    var body: []u8 = &[_]u8{};
    if (content_length) |length| {
        // Find the end of the headers
        const headers_end = std.mem.indexOfPos(u8, request, 0, "\r\n\r\n") orelse return error.InvalidRequest;

        // Check if the entire body is present in the request
        if (headers_end + 4 + length <= request.len) {
            // Extract the body from the request
            // Start from the end of headers + 4 (for the double CRLF)
            // End at the calculated position based on Content-Length
            body = request[headers_end + 4 .. headers_end + 4 + length];
        }
    }

    // Handle the request based on the URL path
    if (std.mem.eql(u8, path, "/")) {
        try sendResponse(client, "200 OK", "text/plain", accept_encoding, "");
    } else if (std.mem.startsWith(u8, path, "/echo/")) {
        const echo_path = path[6..];
        try sendResponse(client, "200 OK", "text/plain", accept_encoding, echo_path);
    } else if (std.mem.eql(u8, path, "/user-agent")) {
        try sendResponse(client, "200 OK", "text/plain", accept_encoding, user_agent orelse "");
    } else if (std.mem.startsWith(u8, path, "/files/")) {
        if (files_directory.len > 0) {
            const filename = path[7..];
            if (std.mem.eql(u8, method, "GET")) {
                try handleFileRequest(client, files_directory, filename);
            } else if (std.mem.eql(u8, method, "POST")) {
                if (content_length != null and body.len > 0) {
                    try handleFileCreation(client, files_directory, filename, body);
                } else {
                    try sendErrorResponse(client, "400 Bad Request", "Missing or Invalid Content-Length Header");
                }
            } else {
                try sendErrorResponse(client, "405 Method Not Allowed", "");
            }
        } else {
            try sendErrorResponse(client, "404 Not Found", "");
        }
    } else {
        try sendResponse(client, "404 Not Found", "text/plain", accept_encoding, "");
    }
}

fn sendResponse(client: net.Server.Connection, status: []const u8, content_type: []const u8, content_encoding: ?[]const u8, content: []const u8) !void {
    var response: []u8 = undefined;

    if (content_encoding) |encoding| {
        if (std.mem.eql(u8, encoding, "gzip")) {
            var compressed = std.ArrayList(u8).init(std.heap.page_allocator);
            defer compressed.deinit();

            {
                var gzip = try std.compress.gzip.compressor(compressed.writer(), .{});
                const bytes_written = try gzip.write(content);
                if (bytes_written != content.len) {
                    return error.IncompleteWrite;
                }
                try gzip.finish();
            }

            const response_str = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Encoding: {s}\r\nContent-Length: {d}\r\n\r\n", .{ status, content_type, encoding, compressed.items.len });
            defer std.heap.page_allocator.free(response_str);

            try client.stream.writeAll(response_str);
            try client.stream.writeAll(compressed.items);
            return;
        }
    } else {
        response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ status, content_type, content.len });
    }
    defer std.heap.page_allocator.free(response);

    try client.stream.writeAll(response);
    try client.stream.writeAll(content);
}

fn sendErrorResponse(client: net.Server.Connection, status: []const u8, message: []const u8) !void {
    try sendResponse(client, status, "text/plain", null, message);
}

fn handleFileRequest(client: net.Server.Connection, dir: []const u8, filename: []const u8) !void {
    const full_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dir, filename });
    defer std.heap.page_allocator.free(full_path);

    try std.io.getStdOut().writer().print("File requested: {s}\n", .{full_path});

    const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            try sendErrorResponse(client, "404 Not Found", "");
            return;
        }
        return err;
    };

    defer file.close();

    const file_size = try file.getEndPos();
    var buffer = try std.heap.page_allocator.alloc(u8, file_size);
    defer std.heap.page_allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);

    const content_type = "application/octet-stream";
    const response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ content_type, bytes_read });
    defer std.heap.page_allocator.free(response);

    try client.stream.writeAll(response); // Send the HTTP headers
    try client.stream.writeAll(buffer[0..bytes_read]); // Send the file content separately
}

fn handleFileCreation(client: net.Server.Connection, dir: []const u8, filename: []const u8, content: []const u8) !void {
    const full_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dir, filename });
    defer std.heap.page_allocator.free(full_path);

    try std.io.getStdOut().writer().print("Creating file: {s}\n", .{full_path});

    const file = try std.fs.createFileAbsolute(full_path, .{ .read = true, .truncate = true });
    defer file.close();

    try file.writeAll(content);

    try sendResponse(client, "201 Created", "text/plain", null, "");
}
