const std = @import("std");
const json = std.json;

const Client = @import("curl.zig").Client;
const App = @import("app.zig");

pub var app: ?App = null;

fn handler_fn(_: c_int) callconv(.C) void {
    app.?.stop();
}

fn setupSigIntHandler() void {
    const handler = std.os.Sigaction{
        .handler = .{
            .handler = handler_fn,
        },
        .mask = std.os.empty_sigset,
        .flags = std.os.SA.RESETHAND,
    };

    if (std.os.linux.sigaction(std.os.SIG.INT, &handler, null) == -1) {
        std.os.linux.perror("Failed to set signal");
    }
}

pub fn main() anyerror!void {
    setupSigIntHandler();

    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

    var allocator = general_purpose_allocator.allocator();

    app = try App.init(allocator);

    app.?.run() catch |e| {
        std.log.err("Error while running app: {}", .{e});
    };

    const stdout = std.io.getStdOut().writer();
    stdout.print("stopping ...", .{}) catch {};

    _ = app.?.deinit() catch |e| {
        std.log.err("Failed to deinit app: {}", .{e});
    };

    try Client.cleanup();
    if (general_purpose_allocator.deinit()) {
        std.log.err("leaked bytes", .{});
    }
}
