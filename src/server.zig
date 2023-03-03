const std = @import("std");
const assert = std.debug.assert;
const IO_Uring = std.os.linux.IO_Uring;
const io_uring_cqe = std.os.linux.io_uring_cqe;
const io_uring_sqe = std.os.linux.io_uring_sqe;

const http = @import("./lib.zig");
const Callback = @import("callback.zig").Callback;
const RegisteredFile = @import("io.zig").RegisteredFile;
const RegisteredFileDescriptors = @import("io.zig").RegisteredFileDescriptors;
const extras = @import("extras");

pub const ServerOptions = struct {
    max_ring_entries: u13 = 512,
    max_buffer_size: usize = 4096,
    max_connections: usize = 128,
};

/// The HTTP server.
///
/// This struct does nothing by itself, the caller must drive it to achieve anything.
/// After initialization the caller must, in a loop:
/// * call maybeAccept
/// * call submit
/// * call processCompletions
///
/// Then the server will accept connections and process requests.
///
/// NOTE: this is _not_ thread safe ! You must create on Server object per thread.
pub const Server = struct {
    /// allocator used to allocate each client state
    root_allocator: std.mem.Allocator,

    /// uring dedicated to this server object.
    ring: IO_Uring,

    /// options controlling the behaviour of the server.
    options: ServerOptions,

    /// indicates if the server should continue running.
    /// This is _not_ owned by the server but by the caller.
    running: *std.atomic.Atomic(bool),

    /// This field lets us keep track of the number of pending operations which is necessary to implement drain() properly.
    ///
    /// Note that this is different than the number of SQEs pending in the submission queue or CQEs pending in the completion queue.
    /// For example an accept operation which has been consumed by the kernel but hasn't accepted any connection yet must be considered
    /// pending for us but it's not pending in either the submission or completion queue.
    /// Another example is a timeout: once accepted and until expired it won't be available in the completion queue.
    pending: usize = 0,

    /// Listener state
    listener: struct {
        /// server file descriptor used for accept(2) operation.
        /// Must have had bind(2) and listen(2) called on it before being passed to `init()`.
        server_fd: std.os.socket_t,

        /// indicates if an accept operation is pending.
        accept_waiting: bool = false,

        /// the timeout data for the link_timeout operation linked to the previous accept.
        ///
        /// Each accept operation has a following timeout linked to it; this works in such a way
        /// that if the timeout has expired the accept operation is cancelled and if the accept has finished
        /// before the timeout then the timeout operation is cancelled.
        ///
        /// This is useful to run the main loop for a bounded duration.
        timeout: std.os.linux.kernel_timespec = .{
            .tv_sec = 0,
            .tv_nsec = 0,
        },

        // Next peer we're accepting.
        // Will be valid after a successful CQE for an accept operation.
        peer_addr: std.net.Address = .{
            .any = undefined,
        },
        peer_addr_size: u32 = @sizeOf(std.os.sockaddr),
    },

    /// CQEs storage
    cqes: [512]io_uring_cqe = undefined,

    /// List of client states.
    /// A new state is created for each socket accepted and destroyed when the socket is closed for any reason.
    clients: std.ArrayListUnmanaged(*http.Client),

    /// Free list of callback objects necessary for working with the uring.
    /// See the documentation of Callback.Pool.
    callbacks: Callback.Pool,

    /// Set of registered file descriptors for use with the uring.
    ///
    /// TODO(vincent): make use of this somehow ? right now it crashes the kernel.
    registered_fds: RegisteredFileDescriptors,
    registered_files: std.StringHashMapUnmanaged(RegisteredFile),

    handler: http.RequestHandler,

    /// initializes a Server object.
    pub fn init(
        self: *http.Server,
        /// General purpose allocator which will:
        /// * allocate all client states (including request/response bodies).
        /// * allocate the callback pool
        /// Depending on the workload the allocator can be hit quite often (for example if all clients close their connection).
        allocator: std.mem.Allocator,
        /// controls the behaviour of the server (max number of connections, max buffer size, etc).
        options: ServerOptions,
        /// owned by the caller and indicates if the server should shutdown properly.
        running: *std.atomic.Atomic(bool),
        /// must be a socket properly initialized with listen(2) and bind(2) which will be used for accept(2) operations.
        server_fd: std.os.socket_t,
        /// user provied request handler.
        handler: http.RequestHandler,
    ) !void {
        // TODO(vincent): probe for available features for io_uring ?
        self.* = .{
            .root_allocator = allocator,
            .ring = try std.os.linux.IO_Uring.init(options.max_ring_entries, 0),
            .options = options,
            .running = running,
            .listener = .{
                .server_fd = server_fd,
            },
            .clients = try std.ArrayListUnmanaged(*http.Client).initCapacity(allocator, options.max_connections),
            .callbacks = undefined,
            .registered_fds = .{},
            .registered_files = .{},
            .handler = handler,
        };
        self.callbacks = try Callback.Pool.init(allocator, self, options.max_ring_entries);
        try self.registered_fds.register(&self.ring);
    }

    pub fn deinit(self: *http.Server) void {
        var registered_files_iterator = self.registered_files.iterator();
        while (registered_files_iterator.next()) |entry| {
            self.root_allocator.free(entry.key_ptr.*);
        }
        self.registered_files.deinit(self.root_allocator);

        for (self.clients.items) |client| {
            client.deinit();
            self.root_allocator.destroy(client);
        }
        self.clients.deinit(self.root_allocator);

        self.callbacks.deinit();
        self.ring.deinit();
    }

    /// Runs the main loop until the `running` boolean is false.
    //
    ///
    /// `accept_timeout` controls how much time the loop can wait for an accept operation to finish.
    /// This duration is the lower bound duration before the main loop can stop when `running` is false;
    pub fn run(self: *http.Server, accept_timeout: u63) !void {
        // TODO(vincent): we don't properly shutdown the peer sockets; we should do that.
        // This can be done using standard close(2) calls I think.

        while (self.running.load(.SeqCst)) {
            // first step: (maybe) submit and accept with a link_timeout linked to it.
            //
            // Nothing is submitted if:
            // * a previous accept operation is already waiting.
            // * the number of connected clients reached the predefined limit.
            try self.maybeAccept(accept_timeout);

            // second step: submit to the kernel all previous queued SQE.
            //
            // SQEs might be queued by the maybeAccept call above or by the processCompletions call below, but
            // obviously in that case its SQEs queued from the _previous iteration_ that are submitted to the kernel.
            //
            // Additionally we wait for at least 1 CQE to be available, if none is available the thread will be put to sleep by the kernel.
            // Note that this doesn't work if the uring is setup with busy-waiting.
            const submitted = try self.submitAndWaitForAtLeast(1);

            // third step: process all available CQEs.
            //
            // This asks the kernel to wait for at least `submitted` CQE to be available.
            // Since we successfully submitted that many SQEs it is guaranteed we will _at some point_
            // get that many CQEs but there's no guarantee they will be available instantly; if the
            // kernel lags in processing the SQEs we can have a delay in getting the CQEs.
            // This is further accentuated by the number of pending SQEs we can have.
            //
            // One example would be submitting a lot of fdatasync operations on slow devices.
            _ = try self.processCompletions(submitted);
        }
        try self.drain();
    }

    fn maybeAccept(self: *http.Server, timeout: u63) !void {
        if (self.listener.accept_waiting or self.clients.items.len >= self.options.max_connections) {
            return;
        }

        // Queue an accept and link it to a timeout.
        var sqe = try self.submit(.accept, {}, onAccept);
        sqe.flags |= std.os.linux.IOSQE_IO_LINK;

        self.listener.timeout.tv_sec = 0;
        self.listener.timeout.tv_nsec = timeout;

        _ = try self.submit(.accept_link_timeout, {}, onAcceptLinkTimeout);

        self.listener.accept_waiting = true;
    }

    /// Continuously submit SQEs and process completions until there are
    /// no more pending operations.
    ///
    /// This must be called when shutting down.
    fn drain(self: *http.Server) !void {
        // This call is only useful if pending > 0.
        //
        // It is currently impossible to have pending == 0 after an iteration of the main loop because:
        // * if no accept waiting maybeAccept `pending` will increase by 2.
        // * if an accept is waiting but we didn't get a connection, `pending` must still be >= 1.
        // * if an accept is waiting and we got a connection, the previous processCompletions call
        //   increased `pending` while doing request processing.
        // * if no accept waiting and too many connections, the previous processCompletions call
        //   increased `pending` while doing request processing.
        //
        // But to be extra sure we do this submit call outside the drain loop to ensure we have flushed all queued SQEs
        // submitted in the last processCompletions call in the main loop.

        _ = try self.submitAndWaitForAtLeast(0);

        while (self.pending > 0) {
            _ = try self.submitAndWaitForAtLeast(0);
            _ = try self.processCompletions(self.pending);
        }
    }

    /// Submits all pending SQE to the kernel, if any.
    /// Waits for `nr` events to be completed before returning (0 means don't wait).
    ///
    /// This also increments `pending` by the number of events submitted.
    ///
    /// Returns the number of events submitted.
    fn submitAndWaitForAtLeast(self: *http.Server, nr: u32) !usize {
        const n = try self.ring.submit_and_wait(nr);
        self.pending += n;
        return n;
    }

    /// Process all ready CQEs, if any.
    /// Waits for `nr` events to be completed before processing begins (0 means don't wait).
    ///
    /// This also decrements `pending` by the number of events processed.
    ///
    /// Returnsd the number of events processed.
    fn processCompletions(self: *http.Server, nr: usize) !usize {
        // TODO(vincent): how should we handle EAGAIN and EINTR ? right now they will shutdown the server.
        const cqe_count = try self.ring.copy_cqes(self.cqes[0..], @intCast(u32, nr));

        for (self.cqes[0..cqe_count]) |cqe| {
            assert(cqe.user_data != 0);

            // We know that a SQE/CQE is _always_ associated with a pointer of type Callback.

            var cb = @intToPtr(*Callback, cqe.user_data);
            defer self.callbacks.put(cb);

            // Call the provided function with the proper context.
            //
            // Note that while the callback function signature can return an error we don't bubble them up
            // simply because we can't shutdown the server due to a processing error.

            cb.call(cb.server, cb.client_context, cqe) catch |err| {
                self.handleCallbackError(cb.client_context, err);
            };
        }
        self.pending -= cqe_count;
        return cqe_count;
    }

    fn handleCallbackError(self: *http.Server, client_opt: ?*http.Client, err: anyerror) void {
        if (err == error.Canceled) return;

        if (client_opt) |client| {
            switch (err) {
                error.ConnectionResetByPeer,
                error.UnexpectedEOF,
                => {
                    return;
                },
                else => {
                    std.log.err("unexpected error {}", .{err});
                },
            }
            _ = self.submit(.close, .{ client, client.fd }, onCloseClient) catch {};
        } else {
            std.log.err("unexpected error {}", .{err});
        }
    }

    fn onAccept(self: *http.Server, cqe: std.os.linux.io_uring_cqe) !void {
        defer self.listener.accept_waiting = false;

        switch (cqe.err()) {
            .SUCCESS => {},
            .INTR => {
                return error.Canceled;
            },
            .CANCELED => {
                return error.Canceled;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }

        const client_fd = @intCast(std.os.socket_t, cqe.res);

        var client = try self.root_allocator.create(http.Client);
        errdefer self.root_allocator.destroy(client);

        try client.init(
            self.root_allocator,
            self.listener.peer_addr,
            client_fd,
            self.options.max_buffer_size,
        );
        errdefer client.deinit();

        try self.clients.append(self.root_allocator, client);
        _ = try self.submit(.read, .{ client, client_fd, 0 }, onReadRequest);
    }

    fn onAcceptLinkTimeout(self: *http.Server, cqe: std.os.linux.io_uring_cqe) !void {
        _ = self;
        switch (cqe.err()) {
            .CANCELED, .ALREADY, .TIME => {},
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    fn onCloseClient(self: *http.Server, client: *http.Client, cqe: std.os.linux.io_uring_cqe) !void {
        // Cleanup resources
        client.deinit();
        self.root_allocator.destroy(client);

        // Remove client from list
        const maybe_pos: ?usize = for (self.clients.items, 0..) |item, i| {
            if (item == client) {
                break i;
            }
        } else blk: {
            break :blk null;
        };
        if (maybe_pos) |pos| _ = self.clients.orderedRemove(pos);

        switch (cqe.err()) {
            .SUCCESS => {},
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    fn onClose(self: *http.Server, cqe: std.os.linux.io_uring_cqe) !void {
        _ = self;
        switch (cqe.err()) {
            .SUCCESS => {},
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    fn onReadRequest(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        switch (cqe.err()) {
            .SUCCESS => {},
            .PIPE => {
                return error.BrokenPipe;
            },
            .CONNRESET => {
                return error.ConnectionResetByPeer;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
        if (cqe.res <= 0) {
            return error.UnexpectedEOF;
        }

        const read = @intCast(usize, cqe.res);

        try client.write_buffer.appendSlice(client.read_buffer[0..read]);

        if (try parseRequest(client.write_buffer.items)) |result| {
            client.request_state.parse_result = result;
            try processRequest(self, client);
        } else {
            // Not enough data, read more.
            _ = try self.submit(.read, .{ client, client.fd, 0 }, onReadRequest);
        }
    }

    fn onWriteResponseBuffer(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        switch (cqe.err()) {
            .SUCCESS => {},
            .PIPE => {
                return error.BrokenPipe;
            },
            .CONNRESET => {
                return error.ConnectionResetByPeer;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }

        const written = @intCast(usize, cqe.res);

        if (written < client.write_buffer.items.len) {
            // Short write, write the remaining data

            // Remove the already written data
            try client.write_buffer.replaceRange(0, written, &[0]u8{});
            _ = try self.submit(.write, .{ client, client.fd, 0 }, onWriteResponseBuffer);
            return;
        }

        // Response written, read the next request
        client.request_state = .{};
        client.write_buffer.clearRetainingCapacity();
        _ = try self.submit(.read, .{ client, client.fd, 0 }, onReadRequest);
    }

    fn onCloseResponseFile(self: *http.Server, client: *http.Client, cqe: std.os.linux.io_uring_cqe) !void {
        _ = self;
        _ = client;
        switch (cqe.err()) {
            .SUCCESS => {},
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    fn onWriteResponseFile(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        assert(client.write_buffer.items.len > 0);

        switch (cqe.err()) {
            .SUCCESS => {},
            .PIPE => {
                return error.BrokenPipe;
            },
            .CONNRESET => {
                return error.ConnectionResetByPeer;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
        if (cqe.res <= 0) {
            return error.UnexpectedEOF;
        }

        const written = @intCast(usize, cqe.res);
        if (written < client.write_buffer.items.len) {
            // Short write, write the remaining data

            // Remove the already written data
            try client.write_buffer.replaceRange(0, written, &[0]u8{});

            _ = try self.submit(.write, .{ client, client.fd, 0 }, onWriteResponseFile);
            return;
        }

        if (client.response_state.file.offset < client.response_state.file.statx_buf.size) {
            // More data to read from the file, submit another read

            client.write_buffer.clearRetainingCapacity();

            const offset = client.response_state.file.offset;

            switch (client.response_state.file.fd) {
                .direct => |fd| {
                    _ = try self.submit(.read, .{ client, fd, offset }, onReadResponseFile);
                },
                .registered => |fd| {
                    var sqe = try self.submit(.read, .{ client, fd, offset }, onReadResponseFile);
                    sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
                },
            }
            return;
        }

        // Response file written, read the next request

        // Close the response file descriptor
        switch (client.response_state.file.fd) {
            .direct => |fd| {
                _ = try self.submit(.close, .{ client, fd }, onCloseResponseFile);
                client.response_state.file.fd = .{ .direct = -1 };
            },
            .registered => {},
        }

        // Reset the client state
        client.reset();
        _ = try self.submit(.read, .{ client, client.fd, 0 }, onReadRequest);
    }

    fn onReadResponseFile(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        switch (cqe.err()) {
            .SUCCESS => {},
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
        if (cqe.res <= 0) {
            return error.UnexpectedEOF;
        }

        const read = @intCast(usize, cqe.res);
        client.response_state.file.offset += read;

        try client.write_buffer.appendSlice(client.read_buffer[0..read]);
        _ = try self.submit(.write, .{ client, client.fd, 0 }, onWriteResponseFile);
    }

    fn onStatxResponseFile(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        switch (cqe.err()) {
            .SUCCESS => {
                assert(client.write_buffer.items.len == 0);
            },
            .CANCELED => {
                return error.Canceled;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }

        // Prepare the preambule + headers.
        // This will be written to the socket on the next write operation following
        // the first read operation for this file.
        client.response_state.status_code = .ok;
        try client.startWritingResponse(client.response_state.file.statx_buf.size);

        // If the file has already been registered, use its registered file descriptor.
        if (self.registered_files.get(client.response_state.file.path)) |entry| {
            var sqe = try self.submit(.read, .{ client, entry.fd, 0 }, onReadResponseFile);
            sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
            return;
        }

        // The file has not yet been registered, try to do it

        // Assert the file descriptor is of type .direct, if it isn't it's a bug.
        assert(client.response_state.file.fd == .direct);
        const fd = client.response_state.file.fd.direct;

        if (self.registered_fds.acquire(fd)) |registered_fd| {
            // We were able to acquire a registered file descriptor, make use of it.
            client.response_state.file.fd = .{ .registered = registered_fd };

            try self.registered_fds.update(&self.ring);

            var entry = try self.registered_files.getOrPut(self.root_allocator, client.response_state.file.path);
            if (!entry.found_existing) {
                entry.key_ptr.* = try self.root_allocator.dupeZ(u8, client.response_state.file.path);
                entry.value_ptr.* = RegisteredFile{
                    .fd = registered_fd,
                    .size = client.response_state.file.statx_buf.size,
                };
            }

            var sqe = try self.submit(.read, .{ client, registered_fd, 0 }, onReadResponseFile);
            sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
            return;
        }

        // The file isn't registered and we weren't able to register it, do a standard read.
        _ = try self.submit(.read, .{ client, fd, 0 }, onReadResponseFile);
    }

    fn onReadBody(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        assert(client.request_state.content_length != null);
        assert(client.request_state.body != null);

        switch (cqe.err()) {
            .SUCCESS => {},
            .PIPE => {
                return error.BrokenPipe;
            },
            .CONNRESET => {
                return error.ConnectionResetByPeer;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }
        if (cqe.res <= 0) {
            return error.UnexpectedEOF;
        }

        const read = @intCast(usize, cqe.res);

        try client.write_buffer.appendSlice(client.read_buffer[0..read]);
        client.refreshBody();

        const content_length = client.request_state.content_length.?;
        const body = client.request_state.body.?;

        if (body.len < content_length) {
            // Not enough data, read more.
            _ = try self.submit(.read, .{ client, client.fd, 0 }, onReadBody);
            return;
        }

        // Request is complete: call handler
        try self.callHandler(client);
    }

    fn onOpenResponseFile(self: *http.Server, client: *http.Client, cqe: io_uring_cqe) !void {
        assert(client.write_buffer.items.len == 0);

        switch (cqe.err()) {
            .SUCCESS => {},
            .NOENT => {
                try self.submitWriteNotFound(client);
                return;
            },
            else => |err| {
                std.log.err("unexpected error: {}", .{err});
                return error.Unexpected;
            },
        }

        client.response_state.file.fd = .{ .direct = @intCast(std.os.fd_t, cqe.res) };
    }

    fn callHandler(self: *http.Server, client: *http.Client) !void {
        // Create a request for the handler.
        // This doesn't own any data and it only lives for the duration of this function call.
        var req = client.request_state.parse_result.request;
        req.body = client.request_state.body;

        // Call the user provided handler to get a response.
        var arena = std.heap.ArenaAllocator.init(client.gpa);
        defer arena.deinit();

        var data = std.ArrayListUnmanaged(u8){};
        errdefer data.deinit(arena.allocator());

        const response = try self.handler(
            arena.allocator(),
            client.peer,
            data.writer(arena.allocator()),
            req,
        );
        errdefer client.reset();

        // At this point the request data is no longer needed so we can clear the buffer.
        client.write_buffer.clearRetainingCapacity();

        // Process the response:
        // * `response` contains a simple buffer that we can write to the socket straight away.
        // * `send_file` contains a file path that we need to open and statx before we can read/write it to the socket.

        switch (response) {
            .response => |res| {
                client.response_state.status_code = res.status_code;
                client.response_state.headers = res.headers;

                try client.startWritingResponse(data.items.len);
                try client.write_buffer.appendSlice(data.items);

                _ = try self.submit(.write, .{ client, client.fd, 0 }, onWriteResponseBuffer);
            },
            .send_file => |res| {
                client.response_state.status_code = res.status_code;
                client.response_state.headers = res.headers;
                client.response_state.file.path = try client.gpa.dupeZ(u8, res.path);

                if (self.registered_files.get(client.response_state.file.path)) |registered_file| {
                    client.response_state.file.fd = .{ .registered = registered_file.fd };

                    // Prepare the preambule + headers.
                    // This will be written to the socket on the next write operation following
                    // the first read operation for this file.
                    client.response_state.status_code = .ok;
                    try client.startWritingResponse(registered_file.size);

                    // Now read the response file
                    var sqe = try self.submit(.read, .{ client, registered_file.fd, 0 }, onReadResponseFile);
                    sqe.flags |= std.os.linux.IOSQE_FIXED_FILE;
                } else {
                    var sqe = try self.submit(.open, .{ client, client.response_state.file.path, std.os.linux.O.RDONLY | std.os.linux.O.NOFOLLOW, 0o644 }, onOpenResponseFile);
                    sqe.flags |= std.os.linux.IOSQE_IO_LINK;

                    _ = try self.submit(.statx, .{ client, client.response_state.file.path, std.os.linux.AT.SYMLINK_NOFOLLOW, std.os.linux.STATX_SIZE, &client.response_state.file.statx_buf }, onStatxResponseFile);
                }
            },
        }
    }

    fn submitWriteNotFound(self: *http.Server, client: *http.Client) !void {
        const static_response = "Not Found";

        client.response_state.status_code = .not_found;
        try client.startWritingResponse(static_response.len);
        try client.write_buffer.appendSlice(static_response);

        _ = try self.submit(.write, .{ client, client.fd, 0 }, onWriteResponseBuffer);
    }

    fn processRequest(self: *http.Server, client: *http.Client) !void {
        // Try to find the content length. If there's one we switch to reading the body.
        const content_length = client.request_state.parse_result.request.headers.get_int("content-length", usize, 10);
        if (content_length) |n| {
            client.request_state.content_length = n;
            client.refreshBody();

            if (client.request_state.body) |_| {
                _ = try self.submit(.read, .{ client, client.fd, 0 }, onReadBody);
                return;
            }

            // Request is complete: call handler
            try self.callHandler(client);
            return;
        }

        // Otherwise it's a simple call to the handler.
        try self.callHandler(client);
    }

    fn submit(self: *http.Server, comptime tag: std.meta.FieldEnum(Submission), data: extras.FieldType(Submission, tag), comptime cb: anytype) !*io_uring_sqe {
        switch (tag) {
            .accept => {
                comptime assert(cb == onAccept);
                var tmp = try self.callbacks.get(cb, .{});
                return try self.ring.accept(@ptrToInt(tmp), self.listener.server_fd, &self.listener.peer_addr.any, &self.listener.peer_addr_size, 0);
            },
            .accept_link_timeout => {
                comptime assert(cb == onAcceptLinkTimeout);
                var tmp = try self.callbacks.get(cb, .{});
                return self.ring.link_timeout(@ptrToInt(tmp), &self.listener.timeout, 0);
            },
            .read => {
                var tmp = try self.callbacks.get(cb, .{data[0]});
                return self.ring.read(@ptrToInt(tmp), data[1], .{ .buffer = &data[0].read_buffer }, data[2]);
            },
            .write => {
                var tmp = try self.callbacks.get(cb, .{data[0]});
                return self.ring.write(@ptrToInt(tmp), data[1], data[0].write_buffer.items, data[2]);
            },
            .open => {
                var tmp = try self.callbacks.get(cb, .{data[0]});
                return try self.ring.openat(@ptrToInt(tmp), std.os.linux.AT.FDCWD, @ptrCast([:0]const u8, data[1]), data[2], data[3]);
            },
            .statx => {
                var tmp = try self.callbacks.get(cb, .{data[0]});
                return self.ring.statx(@ptrToInt(tmp), std.os.linux.AT.FDCWD, @ptrCast([:0]const u8, data[1]), data[2], data[3], data[4]);
            },
            .close => {
                var tmp = try self.callbacks.get(cb, .{data[0]});
                return self.ring.close(@ptrToInt(tmp), data[1]);
            },
        }
    }

    const Submission = union(enum) {
        accept: void,
        accept_link_timeout: void,
        read: struct { *http.Client, std.os.socket_t, u64 },
        write: struct { *http.Client, std.os.fd_t, u64 },
        open: struct { *http.Client, []const u8, u32, std.os.mode_t },
        statx: struct { *http.Client, []const u8, u32, u32, *std.os.linux.Statx },
        close: struct { *http.Client, std.os.fd_t },
    };
};

pub const ParseRequestResult = struct {
    request: http.Request,
    consumed: usize,
};

fn parseRequest(raw_buffer: []const u8) !?ParseRequestResult {
    var fbs = std.io.fixedBufferStream(raw_buffer);
    const r = fbs.reader();

    var method_temp: [8]u8 = undefined;
    const method = std.meta.stringToEnum(std.http.Method, r.readUntilDelimiter(&method_temp, ' ') catch return null) orelse return error.BadRequest;

    const path_start = fbs.pos;
    r.skipUntilDelimiterOrEof(' ') catch return null;
    const path = raw_buffer[path_start .. fbs.pos - 1];
    if (path.len == 0) return null;
    if (path[0] != '/') return error.BadRequest;

    const protocol = http.Protocol.fromString(extras.readBytes(r, 8) catch return null) orelse return error.BadRequest;
    _ = protocol;

    if (!(extras.readExpected(r, "\r\n") catch return null)) return error.BadRequest;

    var headers: [http.Headers.max]http.Header = undefined;
    var num_headers: usize = 0;

    while (true) {
        var hdr_temp: [1024]u8 = undefined;
        const hdr_opt = r.readUntilDelimiterOrEof(&hdr_temp, '\r') catch return error.BadRequest1;
        if ((r.readByte() catch return null) != '\n') return error.BadRequest2;
        const hdr = std.mem.trimRight(u8, hdr_opt orelse return null, "\r");
        if (hdr.len == 0) break;
        if (std.mem.indexOfScalar(u8, hdr, ':') == null) return error.BadRequest3;
        var iter = std.mem.split(u8, hdr, ": ");
        headers[num_headers] = .{
            .name = iter.first(),
            .value = iter.rest(),
        };
        num_headers += 1;
        if (num_headers == http.Headers.max) break;
    }

    return ParseRequestResult{
        .request = .{
            .method = method,
            .path = path,
            .headers = http.Headers.create(headers, num_headers),
            .body = null,
        },
        .consumed = @intCast(usize, fbs.pos),
    };
}
