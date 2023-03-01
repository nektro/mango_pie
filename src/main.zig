const std = @import("std");
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;

const http = @import("mango_pie");

const logger = std.log.scoped(.main);

var global_running = Atomic(bool).init(true);

pub const build_options = @import("build_options");

fn addSignalHandlers() !void {
    // Ignore broken pipes
    {
        var act = std.os.Sigaction{
            .handler = .{
                .handler = std.os.SIG.IGN,
            },
            .mask = std.os.empty_sigset,
            .flags = 0,
        };
        try std.os.sigaction(std.os.SIG.PIPE, &act, null);
    }

    // Catch SIGINT/SIGTERM for proper shutdown
    {
        var act = std.os.Sigaction{
            .handler = .{
                .handler = struct {
                    fn wrapper(sig: c_int) callconv(.C) void {
                        logger.info("caught signal {d}", .{sig});

                        global_running.store(false, .SeqCst);
                    }
                }.wrapper,
            },
            .mask = std.os.empty_sigset,
            .flags = 0,
        };
        try std.os.sigaction(std.os.SIG.TERM, &act, null);
        try std.os.sigaction(std.os.SIG.INT, &act, null);
    }
}

const ServerContext = struct {
    const Self = @This();

    id: usize,
    server: http.Server,
    thread: std.Thread,

    pub fn format(self: *const Self, comptime fmt_string: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (comptime !std.mem.eql(u8, "s", fmt_string)) @compileError("format string must be s");
        try writer.print("{d}", .{self.id});
    }

    fn handleRequest(per_request_allocator: std.mem.Allocator, peer: http.Peer, req: http.Request) anyerror!http.Response {
        _ = per_request_allocator;

        logger.debug("IN HANDLER addr={} method: {s}, path: {s}, minor version: {d}, body: \"{?s}\"", .{ peer.addr, @tagName(req.method), req.path, req.minor_version, req.body });

        if (std.mem.startsWith(u8, req.path, "/static")) {
            return http.Response{
                .send_file = .{
                    .status_code = .ok,
                    .headers = &.{},
                    .path = req.path[1..],
                },
            };
        }
        return http.Response{
            .response = .{
                .status_code = .ok,
                .headers = &.{},
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
    const server_fd = try http.createSocket(listen_port);

    logger.info("listening on :{d}", .{listen_port});
    logger.info("max server threads: {d}, max ring entries: {d}, max buffer size: {d}, max connections: {d}", .{
        max_server_threads,
        max_ring_entries,
        max_buffer_size,
        max_connections,
    });

    // Create the servers

    var servers = try allocator.alloc(ServerContext, max_server_threads);
    for (servers, 0..) |*item, i| {
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
            ServerContext.handleRequest,
        );
    }
    defer {
        for (servers) |*item| item.server.deinit();
        allocator.free(servers);
    }

    for (servers) |*item| {
        item.thread = try std.Thread.spawn(.{}, worker, .{&item.server});
    }

    for (servers) |*item| item.thread.join();
}

fn worker(server: *http.Server) !void {
    return server.run(1 * std.time.ns_per_s);
}
