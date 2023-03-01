const std = @import("std");
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;

const http = @import("mango_pie");

const logger = std.log.scoped(.main);

var global_running = Atomic(bool).init(true);

pub const build_options = @import("build_options");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    const allocator = gpa.allocator();

    const listen_port: u16 = 3405;
    const max_server_threads: usize = 1;
    const max_ring_entries: u13 = 512;
    const max_buffer_size: usize = 4096;
    const max_connections: usize = 128;

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
    var servers: [max_server_threads]ServerContext = undefined;
    for (&servers, 0..) |*item, i| {
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
            handleRequest,
        );
    }
    defer for (&servers) |*item| item.server.deinit();

    for (&servers) |*item| {
        item.thread = try std.Thread.spawn(.{}, worker, .{&item.server});
    }
    for (&servers) |*item| item.thread.join();
}

const ServerContext = struct {
    id: usize,
    server: http.Server,
    thread: std.Thread,
};

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

fn worker(server: *http.Server) !void {
    return server.run(1 * std.time.ns_per_s);
}
