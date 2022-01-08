const std = @import("std");
const json = std.json;

const twitch = @import("twitch.zig");
const Client = @import("client.zig").Client;
const webhook = @import("webhook.zig");
const sqlite = @import("sqlite.zig");

const Config = struct {
    token: []const u8,
    client_id: []const u8,
    user_logins: []const User,
    webhook_url: []const u8,

    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) anyerror!@This() {
        var file = try std.fs.cwd().openFile(path, .{
            .read = true,
            .write = false,
        });

        var stat = try file.stat();
        const file_buffer = try allocator.alloc(u8, stat.size);
        _ = try file.readAll(file_buffer);

        var stream = json.TokenStream.init(file_buffer);

        return json.parse(@This(), &stream, .{ .allocator = allocator });
    }
};

const User = struct {
    user_login: []u8,
    user_icon: []u8,
};

pub fn main() anyerror!void {
    var db = try sqlite.Database.open("a.db");
    defer {
        _ = db.close() catch |e| {
            std.log.err("Failed to close db : {}", .{e});
        };
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();

    var config = try Config.fromFile(allocator, "config.json");

    try Client.globalInit();

    var client = try Client.init(&allocator) orelse error.FailedInitClient;

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("Authorization", config.token);
    try headers.put("Client-Id", config.client_id);

    try updateAlert(allocator, &client, &config, &headers);

    client.deinit();

    try Client.cleanup();
    arena.deinit();
}

pub fn updateAlert(allocator: std.mem.Allocator, client: *Client, config: *Config, headers: *std.StringHashMap([]const u8)) anyerror!void {
    var request = std.ArrayList(u8).init(allocator);

    try request.appendSlice("https://api.twitch.tv/helix/streams?");

    {
        var i: u8 = 0;
        while (i < config.user_logins.len) : (i += 1) {
            if (i != 0)
                try request.append('&');
            try request.appendSlice("user_login=");
            try request.appendSlice(config.user_logins[i].user_login);
        }
    }

    try request.append(0);

    const streams: twitch.TwitchRes([]const twitch.Stream) = try client.getJSON(twitch.TwitchRes([]const twitch.Stream), @ptrCast([*:0]const u8, request.items), headers);

    request.deinit();

    std.log.info("{s}", .{streams});

    if (streams.data.len > 0) {
        var embeds = try allocator.alloc(webhook.Embed, streams.data.len);

        for (streams.data) |s, i| {
            var viewer = std.ArrayList(u8).init(allocator);
            try std.fmt.format(viewer.writer(), "{}", .{s.viewer_count});
            var fields = [_]webhook.Field{
                .{
                    .name = "Viewer count",
                    .value = viewer.items,
                    .@"inline" = true,
                },
                .{
                    .name = "Game name",
                    .value = s.game_name,
                    .@"inline" = true,
                },
            };

            var thumbnail = try std.mem.replaceOwned(u8, allocator, s.thumbnail_url, "{width}", "1920");
            thumbnail = try std.mem.replaceOwned(u8, allocator, thumbnail, "{height}", "1080");

            var stream_url = std.ArrayList(u8).init(allocator);
            _ = try stream_url.appendSlice("https://twitch.tv/");
            _ = try stream_url.appendSlice(s.user_login);

            var icon_url: []u8 = "";
            for (config.user_logins) |u| {
                if (std.mem.eql(u8, u.user_login, s.user_login)) {
                    icon_url = u.user_icon;
                    break;
                }
            }

            embeds[i] = .{
                .title = s.title,
                .image = .{
                    .url = thumbnail,
                },
                .author = .{
                    .name = s.user_name,
                    .url = stream_url.items,
                    .icon_url = icon_url,
                },
                .color = 0xa970ff,
                .fields = fields[0..],
            };
        }

        _ = try client.postJSON(config.webhook_url, webhook.Webhook{
            .username = "Twitch",
            .content = "Live alert",
            .embeds = embeds,
        }, null);
    }
}
