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
pub usingnamespace @import("./request.zig");
