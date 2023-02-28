const std = @import("std");

/// Contains peer information for a request.
pub const Peer = struct {
    addr: std.net.Address,
};
