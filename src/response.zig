const std = @import("std");
const http = @import("./lib.zig");

pub const Response = union(enum) {
    /// The response is a simple buffer.
    response: struct {
        status_code: std.http.Status,
        headers: []http.Header,
        data: []const u8,
    },
    /// The response is a static file that will be read from the filesystem.
    send_file: struct {
        status_code: std.http.Status,
        headers: []http.Header,
        path: []const u8,
    },
};
