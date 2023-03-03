const std = @import("std");
const http = @import("./lib.zig");

pub const Client = struct {
    const RequestState = struct {
        parse_result: http.ParseRequestResult = .{
            .request = undefined,
            .consumed = 0,
        },
        content_length: ?usize = null,
        /// this is a view into the client buffer
        body: ?[]const u8 = null,
    };

    /// Holds state used to send a response to the client.
    const ResponseState = struct {
        status_code: std.http.Status = .ok,
        headers: []http.Header = &[_]http.Header{},

        /// state used when we need to send a static file from the filesystem.
        file: File = .{},

        const File = struct {
            path: [:0]const u8 = "",
            fd: ResponseStateFileDescriptor = undefined,
            statx_buf: std.os.linux.Statx = undefined,

            offset: usize = 0,
        };
    };

    gpa: std.mem.Allocator,

    /// peer information associated with this client
    peer: http.Peer,
    fd: std.os.socket_t,

    read_buffer: [std.mem.page_size]u8 = undefined,
    write_buffer: std.ArrayList(u8),

    request_state: RequestState = .{},
    response_state: ResponseState = .{},

    pub fn init(self: *Client, allocator: std.mem.Allocator, peer_addr: std.net.Address, client_fd: std.os.socket_t, max_buffer_size: usize) !void {
        self.* = .{
            .gpa = allocator,
            .peer = .{ .addr = peer_addr },
            .fd = client_fd,
            .write_buffer = try std.ArrayList(u8).initCapacity(allocator, max_buffer_size),
        };
    }

    pub fn deinit(self: *Client) void {
        self.reset();
        self.write_buffer.deinit();
    }

    pub fn refreshBody(self: *Client) void {
        const consumed = self.request_state.parse_result.consumed;
        if (consumed > 0) {
            self.request_state.body = self.write_buffer.items[consumed..];
        }
    }

    pub fn reset(self: *Client) void {
        if (self.response_state.file.path.len > 0) self.gpa.free(self.response_state.file.path);

        self.request_state = .{};
        self.response_state = .{};
        self.write_buffer.clearRetainingCapacity();
    }

    pub fn startWritingResponse(self: *Client, content_length: ?usize) !void {
        var writer = self.write_buffer.writer();

        try writer.print("HTTP/1.1 {d} {s}\n", .{ @enumToInt(self.response_state.status_code), self.response_state.status_code.phrase().? });
        try writer.writeAll("Connection: close\n");

        for (self.response_state.headers) |header| {
            try writer.print("{s}: {s}\n", .{ header.name, header.value });
        }
        if (content_length) |n| {
            try writer.print("Content-Length: {d}\n", .{n});
        }
        try writer.print("\n", .{});
    }
};

const ResponseStateFileDescriptor = union(enum) {
    direct: std.os.fd_t,
    registered: std.os.fd_t,

    pub fn format(self: ResponseStateFileDescriptor, comptime fmt_string: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (comptime !std.mem.eql(u8, "s", fmt_string)) @compileError("format string must be s");
        switch (self) {
            .direct => |fd| try writer.print("(direct fd={d})", .{fd}),
            .registered => |fd| try writer.print("(registered fd={d})", .{fd}),
        }
    }
};
