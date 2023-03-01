const std = @import("std");
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;

const http = @import("mango_pie");
const signal = @import("signal");

var global_running = Atomic(bool).init(true);

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

    std.log.info("listening on :{d}", .{listen_port});
    std.log.info("max server threads: {d}, max ring entries: {d}, max buffer size: {d}, max connections: {d}", .{ max_server_threads, max_ring_entries, max_buffer_size, max_connections });

    signal.listenFor(std.os.linux.SIG.INT, handle_sig);
    signal.listenFor(std.os.linux.SIG.TERM, handle_sig);

    // Create the server
    var server: http.Server = undefined;
    try server.init(
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
    defer server.deinit();

    try server.run(1 * std.time.ns_per_s);
}

fn handle_sig() void {
    std.log.info("exiting safely...", .{});
    global_running.store(false, .SeqCst);
}

fn handleRequest(per_request_allocator: std.mem.Allocator, peer: http.Peer, res_writer: http.ResponseWriter, req: http.Request) anyerror!http.Response {
    _ = per_request_allocator;

    std.log.debug("IN HANDLER addr={} method: {s}, path: {s}, body: \"{?s}\"", .{ peer.addr, @tagName(req.method), req.path, req.body });

    if (std.mem.startsWith(u8, req.path, "/static")) {
        return http.Response{
            .send_file = .{
                .status_code = .ok,
                .headers = &.{},
                .path = req.path[1..],
            },
        };
    }

    try res_writer.writeAll("Hello, World in handler!\n");
    return http.Response{
        .response = .{
            .status_code = .ok,
            .headers = &.{},
        },
    };
}
