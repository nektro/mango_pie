const std = @import("std");
const root = @import("root");
const build_options = root.build_options;
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;
const extras = @import("extras");
const http = @This();

const IO_Uring = std.os.linux.IO_Uring;
const io_uring_cqe = std.os.linux.io_uring_cqe;
const io_uring_sqe = std.os.linux.io_uring_sqe;

pub const createSocket = @import("io.zig").createSocket;

const logger = std.log.scoped(.main);

pub usingnamespace @import("./peer.zig");
pub usingnamespace @import("./response.zig");
pub usingnamespace @import("./header.zig");
pub usingnamespace @import("./protocol.zig");
pub usingnamespace @import("./server.zig");

/// HTTP types and stuff
const c = @cImport({
    @cInclude("picohttpparser.h");
});

pub const Headers = struct {
    storage: [RawRequest.max_headers]http.Header,
    view: []http.Header,

    fn create(req: RawRequest) !Headers {
        assert(req.num_headers < RawRequest.max_headers);

        var res = Headers{
            .storage = undefined,
            .view = undefined,
        };
        const num_headers = req.copyHeaders(&res.storage);
        res.view = res.storage[0..num_headers];
        return res;
    }

    pub fn get(self: Headers, name: []const u8) ?http.Header {
        for (self.view) |item| {
            if (std.ascii.eqlIgnoreCase(name, item.name)) {
                return item;
            }
        }
        return null;
    }
};

/// Request type contains fields populated by picohttpparser and provides
/// helpers methods for easier use with Zig.
const RawRequest = struct {
    const max_headers = 100;

    method: std.http.Method,
    path: []const u8,
    headers: [max_headers]c.phr_header,
    num_headers: usize,

    fn copyHeaders(self: RawRequest, headers: []http.Header) usize {
        assert(headers.len >= self.num_headers);

        var i: usize = 0;
        while (i < self.num_headers) : (i += 1) {
            const hdr = self.headers[i];

            const name = hdr.name[0..hdr.name_len];
            const value = hdr.value[0..hdr.value_len];

            headers[i].name = name;
            headers[i].value = value;
        }

        return self.num_headers;
    }

    pub fn getContentLength(self: RawRequest) !?usize {
        var i: usize = 0;
        while (i < self.num_headers) : (i += 1) {
            const hdr = self.headers[i];

            const name = hdr.name[0..hdr.name_len];
            const value = hdr.value[0..hdr.value_len];

            if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                continue;
            }
            return try std.fmt.parseInt(usize, value, 10);
        }
        return null;
    }
};

const ParseRequestResult = struct {
    raw_request: RawRequest,
    consumed: usize,
};

pub fn parseRequest(previous_buffer_len: usize, raw_buffer: []const u8) !?ParseRequestResult {
    var fbs = std.io.fixedBufferStream(raw_buffer);
    const r = fbs.reader();

    var method_temp: [8]u8 = undefined;
    const method = std.meta.stringToEnum(std.http.Method, try r.readUntilDelimiter(&method_temp, ' ')) orelse return error.InvalidRequest;

    const path_start = fbs.pos;
    try r.skipUntilDelimiterOrEof(' ');
    const path = raw_buffer[path_start .. fbs.pos - 1];
    if (path.len == 0) return error.InvalidRequest;
    if (path[0] != '/') return error.InvalidRequest;

    const protocol = http.Protocol.fromString(try extras.readBytes(r, 8)) orelse return error.InvalidRequest;
    _ = protocol;

    if (!try extras.readExpected(r, "\r\n")) return error.InvalidRequest;

    var headers: [RawRequest.max_headers]c.phr_header = undefined;
    var num_headers: usize = undefined;

    const buffer = fbs.buffer[fbs.pos..];
    const res = c.phr_parse_headers(
        buffer.ptr,
        buffer.len,
        &headers,
        &num_headers,
        previous_buffer_len,
    );
    if (res == -1) {
        // TODO(vincent): don't panic, proper cleanup instead
        std.debug.panic("parse error\n", .{});
    }
    if (res == -2) {
        return null;
    }

    return ParseRequestResult{
        .raw_request = .{
            .method = method,
            .path = path,
            .headers = headers,
            .num_headers = num_headers,
        },
        .consumed = @intCast(usize, res),
    };
}

/// Contains request data.
/// This is what the handler will receive.
pub const Request = struct {
    method: std.http.Method,
    path: []const u8,
    headers: Headers,
    body: ?[]const u8,

    pub fn create(req: RawRequest, body: ?[]const u8) !Request {
        return Request{
            .method = req.method,
            .path = req.path,
            .headers = try Headers.create(req),
            .body = body,
        };
    }
};

pub const RequestHandler = *const fn (std.mem.Allocator, http.Peer, http.ResponseWriter, Request) anyerror!http.Response;

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

pub const Client = struct {
    const RequestState = struct {
        parse_result: ParseRequestResult = .{
            .raw_request = undefined,
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

    // TODO(vincent): prevent going over the max_buffer_size somehow ("limiting" allocator ?)
    // TODO(vincent): right now we always use clearRetainingCapacity() which may keep a lot of memory
    // allocated for no reason.
    // Implement some sort of statistics to determine if we should release memory, for example:
    //  * max size used by the last 100 requests for reads or writes
    //  * duration without any request before releasing everything
    buffer: std.ArrayList(u8),

    request_state: RequestState = .{},
    response_state: ResponseState = .{},

    pub fn init(self: *Client, allocator: std.mem.Allocator, peer_addr: std.net.Address, client_fd: std.os.socket_t, max_buffer_size: usize) !void {
        self.* = .{
            .gpa = allocator,
            .peer = .{ .addr = peer_addr },
            .fd = client_fd,
            .buffer = undefined,
        };
        self.temp_buffer_fba = std.heap.FixedBufferAllocator.init(&self.temp_buffer);
        self.buffer = try std.ArrayList(u8).initCapacity(self.gpa, max_buffer_size);
    }

    pub fn deinit(self: *Client) void {
        self.buffer.deinit();
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
        var writer = self.buffer.writer();

        try writer.print("HTTP/1.1 {d} {s}\n", .{ @enumToInt(self.response_state.status_code), self.response_state.status_code.phrase().? });
        for (self.response_state.headers) |header| {
            try writer.print("{s}: {s}\n", .{ header.name, header.value });
        }
        if (content_length) |n| {
            try writer.print("Content-Length: {d}\n", .{n});
        }
        try writer.print("\n", .{});
    }
};
