const std = @import("std");
const http = @import("./lib.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    storage: [http.RawRequest.max_headers]http.Header,
    view: []http.Header,

    pub fn create(req: http.RawRequest) Headers {
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
