const std = @import("std");
const root = @import("root");
const build_options = root.build_options;
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;
const extras = @import("extras");
const builtin = @import("builtin");
const http = @This();

const IO_Uring = std.os.linux.IO_Uring;
const io_uring_cqe = std.os.linux.io_uring_cqe;
const io_uring_sqe = std.os.linux.io_uring_sqe;

pub const createSocket = @import("io.zig").createSocket;

const logger = std.log.scoped(.main);

comptime {
    assert(builtin.target.os.tag == .linux);
}

pub usingnamespace @import("./peer.zig");
pub usingnamespace @import("./response.zig");
pub usingnamespace @import("./header.zig");
pub usingnamespace @import("./protocol.zig");
pub usingnamespace @import("./server.zig");
pub usingnamespace @import("./client.zig");

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

pub const ParseRequestResult = struct {
    raw_request: RawRequest,
    consumed: usize,
};

pub fn parseRequest(previous_buffer_len: usize, raw_buffer: []const u8) !?ParseRequestResult {
    var fbs = std.io.fixedBufferStream(raw_buffer);
    const r = fbs.reader();

    var method_temp: [8]u8 = undefined;
    const method = std.meta.stringToEnum(std.http.Method, r.readUntilDelimiter(&method_temp, ' ') catch return null) orelse return error.InvalidRequest;

    const path_start = fbs.pos;
    r.skipUntilDelimiterOrEof(' ') catch return null;
    const path = raw_buffer[path_start .. fbs.pos - 1];
    if (path.len == 0) return null;
    if (path[0] != '/') return error.InvalidRequest;

    const protocol = http.Protocol.fromString(extras.readBytes(r, 8) catch return null) orelse return error.InvalidRequest;
    _ = protocol;

    if (!(extras.readExpected(r, "\r\n") catch return null)) return error.InvalidRequest;

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
