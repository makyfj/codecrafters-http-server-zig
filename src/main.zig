const std = @import("std");
const net = std.net;

const PORT = 4221;
const HOST = "127.0.0.1";

var files_directory: []const u8 = undefined;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Logs from your program will appear here!\n", .{});

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
    var buffer: [1024]u8 = undefined;

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

    while (lines.next()) |line| {
        try std.io.getStdOut().writer().print("Line: {s}\n", .{line});
    }

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "User-Agent: ")) {
            user_agent = line["User-Agent: ".len..];
        } else if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            content_length = try std.fmt.parseInt(usize, line["Content-Length: ".len..], 10);
        }
    }

    // Handle the request based on the URL path
    if (std.mem.eql(u8, path, "/")) {
        try sendResponse(client, "200 OK", "text/plain", "");
    } else if (std.mem.startsWith(u8, path, "/echo/")) {
        const echo_path = path[6..];
        try sendResponse(client, "200 OK", "text/plain", echo_path);
    } else if (std.mem.eql(u8, path, "/user-agent")) {
        try sendResponse(client, "200 OK", "text/plain", user_agent orelse "");
    } else if (std.mem.startsWith(u8, path, "/files/")) {
        if (files_directory.len > 0) {
            const filename = path[7..];
            if (std.mem.eql(u8, method, "GET")) {
                try handleFileRequest(client, files_directory, filename);
            } else if (std.mem.eql(u8, method, "POST")) {
                var body_buffer = try std.heap.page_allocator.alloc(u8, content_length orelse return error.MissingContentLength);
                defer std.heap.page_allocator.free(body_buffer);
                _ = try client.stream.read(body_buffer);
                try handleFileCreation(client, files_directory, filename, body_buffer[0 .. content_length orelse return error.MissingContentLength]);
            } else {
                try sendResponse(client, "405 Method Not Allowed", "text/plain", "");
            }
        } else {
            try sendResponse(client, "404 Not Found", "text/plain", "");
        }
    } else {
        try sendResponse(client, "404 Not Found", "text/plain", "");
    }
}

fn sendResponse(client: net.Server.Connection, status: []const u8, content_type: []const u8, content: []const u8) !void {
    const response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, content_type, content.len, content });

    defer std.heap.page_allocator.free(response);

    try client.stream.writeAll(response);
}

fn handleFileRequest(client: net.Server.Connection, dir: []const u8, filename: []const u8) !void {
    const full_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dir, filename });
    defer std.heap.page_allocator.free(full_path);

    try std.io.getStdOut().writer().print("File requested: {s}\n", .{full_path});

    const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            try sendResponse(client, "404 Not Found", "application/octet-stream", "");
            return;
        }
        return err;
    };

    defer file.close();

    const file_size = try file.getEndPos();
    try std.io.getStdOut().writer().print("File size: {d}\n", .{file_size});
    var buffer = try std.heap.page_allocator.alloc(u8, file_size + 1);
    defer std.heap.page_allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);

    const content_type = "application/octet-stream";
    const response = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ content_type, bytes_read });
    defer std.heap.page_allocator.free(response);

    try client.stream.writeAll(response);
    try client.stream.writeAll(buffer[0..bytes_read]);
}

fn handleFileCreation(client: net.Server.Connection, dir: []const u8, filename: []const u8, content: []const u8) !void {
    const full_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dir, filename });
    defer std.heap.page_allocator.free(full_path);

    try std.io.getStdOut().writer().print("Creating file: {s}\n", .{full_path});

    const file = try std.fs.createFileAbsolute(full_path, .{ .read = true, .truncate = true });
    defer file.close();

    try file.writeAll(content);

    try sendResponse(client, "201 Created", "text/plain", "");
}
