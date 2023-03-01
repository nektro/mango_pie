# mango_pie

Experiment writing a sort of working HTTP server using:
* [io\_uring](https://unixism.net/loti/what_is_io_uring.html)
* [Zig](https://ziglang.org)

# Requirements

* Linux 5.11 minimum
* [Zig master](https://ziglang.org/download/)

# Building

Just run this:
```
zig build run
```

The binary will be at `zig-out/bin/httpserver`.
