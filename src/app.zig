const std = @import("std");
const mem = std.mem;
const json = std.json;

const sqlite = @import("sqlite.zig");
const twitch = @import("twitch.zig");
const curl = @import("curl.zig");
const webhook = @import("webhook.zig");

const Client = curl.Client;

const Config = struct {
    token: []const u8,
    client_id: []const u8,
    refresh_rate: u64,
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
        file.close();

        var stream = json.TokenStream.init(file_buffer);

        const res = json.parse(@This(), &stream, .{ .allocator = allocator });
        allocator.free(file_buffer);

        return res;
    }

    pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.client_id);

        for (self.user_logins) |user| {
            allocator.free(user.user_login);
        }

        allocator.free(self.user_logins);

        allocator.free(self.webhook_url);

        self.* = undefined;
    }
};

const User = struct { user_login: []u8 };

const DATABASE_VERSION_CODE = 2;

const CREATE_TABLES =
    \\ CREATE TABLE VERSION
    \\ (
    \\     versionCode INTEGER
    \\ );
    \\ 
    \\ INSERT INTO VERSION(versionCode)
    \\ VALUES (2);
    \\ 
    \\ CREATE TABLE STREAMER
    \\ (
    \\     idStreamer       TEXT PRIMARY KEY NOT NULL,
    \\     loginStreamer    TEXT             NOT NULL,
    \\     nameStreamer     TEXT             NOT NULL,
    \\     imageUrlStreamer TEXT
    \\ );
    \\ 
    \\ CREATE TABLE STREAM
    \\ (
    \\     idStream       TEXT PRIMARY KEY NOT NULL,
    \\     idStreamer     TEXT             NOT NULL,
    \\     isMatureStream BOOLEAN          NOT NULL DEFAULT 'F',
    \\     CONSTRAINT FK_STREAM_STREAMER_ID FOREIGN KEY (idStreamer) REFERENCES STREAMER (idStreamer)
    \\ );
    \\ 
    \\ CREATE TABLE VIEWER_COUNT_STREAM
    \\ (
    \\     viewerCount     INTEGER NOT NULL,
    \\     dateViewerCount DATE    NOT NULL,
    \\     idStream        TEXT    NOT NULL,
    \\     PRIMARY KEY (dateViewerCount, idStream),
    \\     CONSTRAINT FK_VIEWER_COUNT_STREAM_ID FOREIGN KEY (idStream) REFERENCES STREAM (idStream)
    \\ );
    \\ 
    \\ CREATE TABLE NAME_STREAM
    \\ (
    \\     nameStream     TEXT NOT NULL,
    \\     dateNameStream DATE NOT NULL,
    \\     idStream       TEXT NOT NULL,
    \\     PRIMARY KEY (dateNameStream, idStream),
    \\     CONSTRAINT FK_NAME_STREAM_STREAM_ID FOREIGN KEY (idStream) REFERENCES STREAM (idStream)
    \\ );
    \\ 
    \\ CREATE TABLE GAME
    \\ (
    \\     gameId   TEXT NOT NULL PRIMARY KEY,
    \\     gameName TEXT
    \\ );
    \\ 
    \\ CREATE TABLE IS_STREAMING_GAME
    \\ (
    \\     gameId         TEXT NOT NULL,
    \\     streamId       TEXT NOT NULL,
    \\     dateGameStream DATE NOT NULL,
    \\     PRIMARY KEY (gameId, streamId, dateGameStream),
    \\     CONSTRAINT FK_GAME_STREAM_GAME_ID FOREIGN KEY (gameId) REFERENCES GAME (gameId),
    \\     CONSTRAINT FK_GAME_STREAM_STREAM_ID FOREIGN KEY (streamId) REFERENCES STREAM (idStream)
    \\ );
;

const DROP_TABLES =
    \\ DROP TABLE IF EXISTS VERSION;
    \\ DROP TABLE IF EXISTS NAME_STREAM;
    \\ DROP TABLE IF EXISTS VIEWER_COUNT_STREAM;
    \\ DROP TABLE IF EXISTS IS_STREAMING_GAME;
    \\ DROP TABLE IF EXISTS STREAM;
    \\ DROP TABLE IF EXISTS STREAMER;
    \\ DROP TABLE IF EXISTS GAME;
;

allocator: mem.Allocator,
db: sqlite.Database,
headers: std.StringHashMap([]const u8),
wait_event: std.Thread.StaticResetEvent = std.Thread.StaticResetEvent{},
config: Config,

pub fn init(allocator: mem.Allocator) anyerror!@This() {
    var db = try sqlite.Database.open("data.db");

    try createTables(&db);

    var config = try Config.fromFile(allocator, "config.json");

    try Client.globalInit();

    var client = try Client.init(allocator);

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("Authorization", config.token);
    try headers.put("Client-Id", config.client_id);

    try insertOrReplaceStreamers(allocator, &db, &client, &config, &headers);

    client.deinit();

    return @This(){
        .allocator = allocator,
        .db = db,
        .headers = headers,
        .config = config,
    };
}

pub fn deinit(self: *@This()) anyerror!void {
    std.log.debug("deinit app", .{});
    self.config.deinit(self.allocator);

    self.headers.deinit();
    try self.db.close();
    self.* = undefined;
}

pub fn run(self: *@This()) anyerror!void {
    var loop = true;
    while (loop) {
        var alertAllocator = std.heap.ArenaAllocator.init(self.allocator);
        var allocator = alertAllocator.allocator();

        var client = try Client.init(allocator);
        try updateAlert(allocator, &client, &self.config, &self.db, &self.headers);
        alertAllocator.deinit();
        client.deinit(); // TODO Maybe don't recreate client every loop, just change allocator

        std.log.debug("sleeping for {} ns", .{self.config.refresh_rate * std.time.ns_per_ms});
        const res = self.wait_event.timedWait(self.config.refresh_rate * std.time.ns_per_ms);
        loop = res == .timed_out;
    }
}

pub fn stop(self: *@This()) void {
    self.wait_event.set();
}

fn createTables(db: *sqlite.Database) anyerror!void {
    var stm = db.prepare("SELECT versionCode FROM VERSION ORDER BY versionCode DESC") catch {
        std.log.debug("Creating database", .{});

        try db.exec(CREATE_TABLES);
        return;
    };

    if (stm.next()) {
        var code: isize = 0;

        try stm.fetch(.{&code});
        stm.finalize();

        if (DATABASE_VERSION_CODE == code) {
            std.log.debug("Database already created", .{});
            return;
        } else {
            try db.exec(DROP_TABLES);
            std.log.debug("Creating database", .{});

            try db.exec(CREATE_TABLES);
        }
    }
    stm.finalize();
}

fn updateAlert(
    allocator: std.mem.Allocator,
    client: *Client,
    config: *Config,
    database: *sqlite.Database,
    headers: *std.StringHashMap([]const u8),
) anyerror!void {
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

    var result: curl.Result(twitch.TwitchRes([]const twitch.Stream)) = try client.getJSON(
        twitch.TwitchRes([]const twitch.Stream),
        @ptrCast([*:0]const u8, request.items),
        headers,
    );

    request.deinit();

    switch (result) {
        .ok => |*streams| {
            if (streams.data.len > 0) {
                var embeds = std.ArrayList(webhook.Embed).init(allocator);

                for (streams.data) |s| {
                    if (try appendEmbed(allocator, &s, database)) |e| {
                        std.log.debug("sending {s}", .{s.title});
                        try embeds.append(e);
                    }
                }

                if (embeds.items.len > 0) {
                    var res = try client.postJSON(config.webhook_url, webhook.Webhook{
                        .username = "Twitch",
                        .content = "Live alert",
                        .embeds = embeds.items,
                    }, null);

                    client.allocator.free(res);
                }
                embeds.deinit();
            }

            streams.deinit(allocator);
        },
        .errorCode => |errorCode| {
            std.log.err("Failed to get streams : error code {}\n", .{errorCode});
            return error.CurlFailed;
        },
    }
}

fn appendEmbed(allocator: std.mem.Allocator, stream: *const twitch.Stream, db: *sqlite.Database) anyerror!?webhook.Embed {
    if (!try streamExist(db, stream.id)) {
        try insertStream(db, stream);
        try insertMetadatas(db, stream);

        var fields = std.ArrayList(webhook.Field).init(allocator); // TODO BETTER WAY
        var viewer = std.ArrayList(u8).init(allocator);
        try std.fmt.format(viewer.writer(), "{}", .{stream.viewer_count});

        try fields.append(.{
            .name = "Viewer count",
            .value = viewer.toOwnedSlice(),
            .@"inline" = true,
        });

        try fields.append(.{
            .name = "Game name",
            .value = stream.game_name,
            .@"inline" = true,
        });

        var thumbnail = try std.mem.replaceOwned(u8, allocator, stream.thumbnail_url, "{width}", "1920");
        thumbnail = try std.mem.replaceOwned(u8, allocator, thumbnail, "{height}", "1080");

        var stream_url = std.ArrayList(u8).init(allocator);
        _ = try stream_url.appendSlice("https://twitch.tv/");
        _ = try stream_url.appendSlice(stream.user_login);

        var icon_url: ?[]u8 = undefined;
        var stm = try db.prepare("SELECT imageUrlStreamer FROM STREAMER WHERE idStreamer = ?");
        try stm.bind(1, sqlite.U8Array.text(stream.user_id));
        if (stm.next()) {
            var res = sqlite.U8Array.text(undefined);
            try stm.fetch(.{&res});

            icon_url = try allocator.alloc(u8, res.text.len);
            std.mem.copy(u8, icon_url.?, res.text);
            stm.finalize();
        } else {
            icon_url = null;
        }

        return webhook.Embed{
            .title = stream.title,
            .image = .{
                .url = thumbnail,
            },
            .author = .{
                .name = stream.user_name,
                .url = stream_url.items,
                .icon_url = icon_url,
            },
            .color = 0xa970ff,
            .fields = fields.toOwnedSlice(),
        };
    } else {
        try insertMetadatas(db, stream);
        return null;
    }
}

fn streamExist(db: *sqlite.Database, streamId: []const u8) anyerror!bool {
    var stm = try db.prepare("SELECT \"foo\" FROM STREAM WHERE idStream = ?");
    try stm.bind(1, sqlite.U8Array.text(streamId));

    const res = stm.next();
    stm.finalize();

    return res;
}

fn insertStream(db: *sqlite.Database, stream: *const twitch.Stream) anyerror!void {
    var stm = try db.prepare(
        "INSERT INTO STREAM(idStream, idStreamer, isMatureStream) VALUES(?, ?, ?)",
    );

    try stm.bind(1, sqlite.U8Array.text(stream.id));
    try stm.bind(2, sqlite.U8Array.text(stream.user_id));
    try stm.bind(3, @boolToInt(stream.is_mature));

    try stm.exec();
    stm.finalize();
}

pub fn insertMetadatas(db: *sqlite.Database, stream: *const twitch.Stream) anyerror!void {
    var stm = try db.prepare(
        "INSERT INTO VIEWER_COUNT_STREAM(viewerCount, dateViewerCount, idStream) VALUES(?, datetime(\"now\"), ?)",
    );

    try stm.bind(1, stream.viewer_count);
    try stm.bind(2, sqlite.U8Array.text(stream.id));

    try stm.exec();
    stm.finalize();

    if (try mustInsertName(db, stream)) {
        std.log.debug("inserting name : {s} ({s})", .{ stream.title, stream.id });
        stm = try db.prepare(
            "INSERT INTO NAME_STREAM(nameStream, dateNameStream, idStream) VALUES(?, datetime(\"now\"), ?)",
        );

        try stm.bind(1, sqlite.U8Array.text(stream.title));
        try stm.bind(2, sqlite.U8Array.text(stream.id));

        try stm.exec();
        stm.finalize();
    }

    stm = try db.prepare(
        "INSERT OR IGNORE INTO GAME(gameId, gameName) VALUES(?, ?)",
    );

    try stm.bind(1, sqlite.U8Array.text(stream.game_id));
    try stm.bind(2, sqlite.U8Array.text(stream.game_name));

    try stm.exec();
    stm.finalize();

    stm = try db.prepare(
        "INSERT INTO IS_STREAMING_GAME(gameId, streamId, dateGameStream) VALUES(?, ?, datetime(\"now\"))",
    );

    try stm.bind(1, sqlite.U8Array.text(stream.game_id));
    try stm.bind(2, sqlite.U8Array.text(stream.id));

    try stm.exec();
    stm.finalize();
}

fn mustInsertName(db: *sqlite.Database, stream: *const twitch.Stream) anyerror!bool {
    var stm = try db.prepare(
        "SELECT nameStream  != ? FROM NAME_STREAM WHERE idStream = ? ORDER BY dateNameStream DESC LIMIT 1",
    );

    try stm.bind(1, sqlite.U8Array.text(stream.title));
    try stm.bind(2, sqlite.U8Array.text(stream.id));

    var res: c_int = 1;
    if (stm.next()) {
        try stm.fetch(.{&res});
    }
    stm.finalize();
    return res == 1;
}

fn insertOrReplaceStreamers(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    client: *Client,
    config: *const Config,
    headers: *std.StringHashMap([]const u8),
) anyerror!void {
    var request = std.ArrayList(u8).init(allocator);

    try request.appendSlice("https://api.twitch.tv/helix/users?");
    defer {
        request.deinit();
    }

    {
        var i: u8 = 0;
        while (i < config.user_logins.len) : (i += 1) {
            if (i != 0)
                try request.append('&');
            try request.appendSlice("login=");
            try request.appendSlice(config.user_logins[i].user_login);
        }
    }

    try request.append(0);

    var result: curl.Result(twitch.TwitchRes([]const twitch.User)) = try client.getJSON(
        twitch.TwitchRes([]const twitch.User),
        @ptrCast([*:0]const u8, request.items),
        headers,
    );

    switch (result) {
        .ok => |*streamers| {
            for (streamers.data) |streamer| {
                var stm = try db.prepare("INSERT OR REPLACE INTO STREAMER(idStreamer, loginStreamer, nameStreamer, imageUrlStreamer) VALUES(?, ?, ?, ?)");
                try stm.bind(1, sqlite.U8Array.text(streamer.id));
                try stm.bind(2, sqlite.U8Array.text(streamer.login));
                try stm.bind(3, sqlite.U8Array.text(streamer.display_name));
                try stm.bind(4, sqlite.U8Array.text(streamer.profile_image_url));

                try stm.exec();
                stm.finalize();
            }

            streamers.deinit(allocator);
        },
        .errorCode => |errorCode| {
            std.log.err("Failed to get streamers : error code {}\n", .{errorCode});
            return error.CurlFailed;
        },
    }
}
