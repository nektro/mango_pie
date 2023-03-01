const std = @import("std");
const http = @import("./lib.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    storage: [max]http.Header,
    view: []const http.Header,

    pub const max = 128;

    pub fn create(storage: [max]http.Header, len: usize) Headers {
        return .{
            .storage = storage,
            .view = storage[0..len],
        };
    }

    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.view) |item| {
            if (std.ascii.eqlIgnoreCase(name, item.name)) {
                return item.value;
            }
        }
        return null;
    }

    pub fn get_int(self: Headers, name: []const u8, comptime T: type, radix: u8) ?T {
        const hdr = self.get(name) orelse return null;
        return std.fmt.parseInt(T, hdr, radix) catch return null;
    }
};
