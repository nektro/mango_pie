const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

pub const createSocket = @import("io.zig").createSocket;

comptime {
    assert(builtin.target.os.tag == .linux);
}

pub usingnamespace @import("./peer.zig");
pub usingnamespace @import("./response.zig");
pub usingnamespace @import("./header.zig");
pub usingnamespace @import("./protocol.zig");
pub usingnamespace @import("./server.zig");
pub usingnamespace @import("./client.zig");
pub usingnamespace @import("./request.zig");
