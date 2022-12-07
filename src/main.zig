const std = @import("std");
const os = std.os;

const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;

const httpserver = @import("lib.zig");

const logger = std.log.scoped(.main);

var global_running: Atomic(bool) = Atomic(bool).init(true);

fn addSignalHandlers() !void {
    // Ignore broken pipes
    {
        var act = os.Sigaction{
            .handler = .{
                .handler = os.SIG.IGN,
            },
            .mask = os.empty_sigset,
            .flags = 0,
        };
        try os.sigaction(os.SIG.PIPE, &act, null);
    }

    // Catch SIGINT/SIGTERM for proper shutdown
    {
        var act = os.Sigaction{
            .handler = .{
                .handler = struct {
                    fn wrapper(sig: c_int) callconv(.C) void {
                        logger.info("caught signal {d}", .{sig});

                        global_running.store(false, .SeqCst);
                    }
                }.wrapper,
            },
            .mask = os.empty_sigset,
            .flags = 0,
        };
        try os.sigaction(os.SIG.TERM, &act, null);
        try os.sigaction(os.SIG.INT, &act, null);
    }
}

const ServerContext = struct {
    const Self = @This();

    id: usize,
    server: httpserver.Server,
    thread: std.Thread,

    pub fn format(self: *const Self, comptime fmt_string: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (comptime !std.mem.eql(u8, "s", fmt_string)) @compileError("format string must be s");
        try writer.print("{d}", .{self.id});
    }

    fn handleRequest(per_request_allocator: std.mem.Allocator, peer: httpserver.Peer, req: httpserver.Request) anyerror!httpserver.Response {
        _ = per_request_allocator;

        logger.debug("IN HANDLER addr={} method: {s}, path: {s}, minor version: {d}, body: \"{?s}\"", .{ peer.addr, @tagName(req.method), req.path, req.minor_version, req.body });

        if (std.mem.startsWith(u8, req.path, "/static")) {
            return httpserver.Response{
                .send_file = .{
                    .status_code = .ok,
                    .headers = &[_]httpserver.Header{},
                    .path = req.path[1..],
                },
            };
        }
        return httpserver.Response{
            .response = .{
                .status_code = .ok,
                .headers = &[_]httpserver.Header{},
                .data = "Hello, World in handler!",
            },
        };
    }
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    var allocator = gpa.allocator();

    const listen_port: u16 = 3405;
    const max_server_threads: usize = 1;
    const max_ring_entries: u13 = 512;
    const max_buffer_size: usize = 4096;
    const max_connections: usize = 128;

    // NOTE(vincent): for debugging
    // var logging_allocator = std.heap.loggingAllocator(gpa.allocator());
    // var allocator = logging_allocator.allocator();

    try addSignalHandlers();

    // Create the server socket
    const server_fd = try httpserver.createSocket(listen_port);

    logger.info("listening on :{d}", .{listen_port});
    logger.info("max server threads: {d}, max ring entries: {d}, max buffer size: {d}, max connections: {d}", .{
        max_server_threads,
        max_ring_entries,
        max_buffer_size,
        max_connections,
    });

    // Create the servers

    var servers = try allocator.alloc(ServerContext, max_server_threads);
    for (servers) |*item, i| {
        item.id = i;
        try item.server.init(
            allocator,
            .{
                .max_ring_entries = max_ring_entries,
                .max_buffer_size = max_buffer_size,
                .max_connections = max_connections,
            },
            &global_running,
            server_fd,
            {},
            ServerContext.handleRequest,
        );
    }
    defer {
        for (servers) |*item| item.server.deinit();
        allocator.free(servers);
    }

    for (servers) |*item| {
        item.thread = try std.Thread.spawn(
            .{},
            struct {
                fn worker(server: *httpserver.Server) !void {
                    return server.run(1 * std.time.ns_per_s);
                }
            }.worker,
            .{&item.server},
        );
    }

    for (servers) |*item| item.thread.join();
}
