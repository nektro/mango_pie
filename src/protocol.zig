const std = @import("std");

pub const Protocol = enum {
    http_0_9,
    http_1_0,
    http_1_1,
    http_2_0,

    pub fn fromString(protocol: [8]u8) ?Protocol {
        if (std.mem.eql(u8, &protocol, "HTTP/1.1")) return .http_1_1;
        if (std.mem.eql(u8, &protocol, "HTTP/2.0")) return .http_2_0;
        if (std.mem.eql(u8, &protocol, "HTTP/1.0")) return .http_1_0;
        if (std.mem.eql(u8, &protocol, "HTTP/0.9")) return .http_0_9;
        return null;
    }
};
