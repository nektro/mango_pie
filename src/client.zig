const std = @import("std");
const http = @import("./lib.zig");
const gimme = @import("gimme");

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
        /// status code and header are overwritable in the handler
        status_code: std.http.Status = .ok,
        headers: []http.Header = &[_]http.Header{},

        /// state used when we need to send a static file from the filesystem.
        file: File = .{},

        const File = struct {
            path: [:0]u8 = undefined,
            fd: ResponseStateFileDescriptor = undefined,
            statx_buf: std.os.linux.Statx = undefined,

            offset: usize = 0,
        };
    };

    gpa: std.mem.Allocator,

    /// peer information associated with this client
    peer: http.Peer,
    fd: std.os.socket_t,

    // Buffer and allocator used for small allocations (nul-terminated path, integer to int conversions etc).
    temp_buffer: [std.mem.page_size]u8 = undefined,
    temp_buffer_fba: std.heap.FixedBufferAllocator = undefined,

    // TODO(vincent): right now we always use clearRetainingCapacity() which may keep a lot of memory
    // allocated for no reason.
    // Implement some sort of statistics to determine if we should release memory, for example:
    //  * max size used by the last 100 requests for reads or writes
    //  * duration without any request before releasing everything
    buffer: std.ArrayListUnmanaged(u8),

    request_state: RequestState = .{},
    response_state: ResponseState = .{},

    pub fn init(self: *Client, allocator: std.mem.Allocator, peer_addr: std.net.Address, client_fd: std.os.socket_t, max_buffer_size: usize) !void {
        self.* = .{
            .gpa = allocator,
            .peer = .{ .addr = peer_addr },
            .fd = client_fd,
            .buffer = try std.ArrayListUnmanaged(u8).initCapacity(allocator, max_buffer_size),
        };
        self.temp_buffer_fba = std.heap.FixedBufferAllocator.init(&self.temp_buffer);
    }

    pub fn deinit(self: *Client) void {
        self.buffer.deinit(self.gpa);
    }

    pub fn refreshBody(self: *Client) void {
        const consumed = self.request_state.parse_result.consumed;
        if (consumed > 0) {
            self.request_state.body = self.buffer.items[consumed..];
        }
    }

    pub fn reset(self: *Client) void {
        self.request_state = .{};
        self.response_state = .{};
        self.buffer.clearRetainingCapacity();
    }

    pub fn startWritingResponse(self: *Client, content_length: ?usize) !void {
        var writer = self.buffer.writer(gimme.FailingAllocator.allocator());

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
