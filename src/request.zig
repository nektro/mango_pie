const std = @import("std");
const http = @import("./lib.zig");
const c = @import("./c.zig");

pub const Request = struct {
    method: std.http.Method,
    path: []const u8,
    headers: http.Headers,
    body: ?[]const u8,
};

pub const RequestHandler = *const fn (std.mem.Allocator, http.Peer, http.ResponseWriter, Request) anyerror!http.Response;

pub const RawRequest = struct {
    pub const max_headers = 100;

    method: std.http.Method,
    path: []const u8,
    headers: [max_headers]c.phr_header,
    num_headers: usize,

    pub fn copyHeaders(self: RawRequest, headers: []http.Header) usize {
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
