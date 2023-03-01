const std = @import("std");
const http = @import("./lib.zig");

pub const Request = struct {
    method: std.http.Method,
    path: []const u8,
    headers: http.Headers,
    body: ?[]const u8,
};

pub const RequestHandler = *const fn (std.mem.Allocator, http.Peer, http.ResponseWriter, Request) anyerror!http.Response;
