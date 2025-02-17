const std = @import("std");
const http = @import("./lib.zig");

pub const Response = union(enum) {
    /// The response is a simple buffer.
    response: struct {
        status_code: std.http.Status,
        headers: http.Headers,
    },
    /// The response is a static file that will be read from the filesystem.
    send_file: struct {
        status_code: std.http.Status,
        headers: http.Headers,
        path: []const u8,
    },
};

pub const ResponseWriter = std.ArrayListUnmanaged(u8).Writer;
