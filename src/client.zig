const std = @import("std");

const json = std.json;
const mem = std.mem;

const cURL = @cImport({
    @cInclude("curl/curl.h");
});

const ArrayListReader = struct {
    items: []u8,
    position: usize,
};

pub const Client = struct {
    ptr: *cURL.CURL,
    allocator: *mem.Allocator,

    pub fn init(allocator: *mem.Allocator) ?@This() {
        const ptr = cURL.curl_easy_init() orelse return null;

        return @This(){
            .ptr = ptr,
            .allocator = allocator,
        };
    }

    pub fn globalInit() anyerror!void {
        if (cURL.curl_global_init(cURL.CURL_GLOBAL_ALL) != cURL.CURLE_OK)
            return error.CURLGlobalInitFailed;
    }

    pub fn cleanup() anyerror!void {
        cURL.curl_global_cleanup();
    }

    pub fn getJSON(self: *@This(), comptime T: type, url: [*:0]const u8, headers: ?*std.StringHashMap([]const u8)) anyerror!T {
        var response_buffer = std.ArrayList(u8).init(self.allocator.*);
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_URL, url) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_HTTPGET, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_NOPROGRESS, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_MAXREDIRS, @as(c_long, 50)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        var header_slist: [*c]cURL.curl_slist = null;

        if (headers) |header| {
            var iterator = header.iterator();

            while (iterator.next()) |entry| {
                var buf = try self.allocator.alloc(u8, entry.key_ptr.*.len + 3 + entry.value_ptr.*.len);
                _ = try std.fmt.bufPrint(buf, "{s}: {s}\x00", .{ entry.key_ptr.*, entry.value_ptr.* });

                header_slist = cURL.curl_slist_append(header_slist, buf.ptr);
                self.allocator.free(buf);
            }
        }

        if (header_slist != null) {
            if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_HTTPHEADER, header_slist) != cURL.CURLE_OK)
                return error.CURLSetOptFailed;
        } else {
            if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_HTTPHEADER, @as(c_long, 0)) != cURL.CURLE_OK)
                return error.CURLSetOptFailed;
        }

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK)
            return error.CURLSetOptFailed;

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (cURL.curl_easy_perform(self.ptr) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (header_slist != null)
            cURL.curl_slist_free_all(header_slist);

        var stream = json.TokenStream.init(response_buffer.toOwnedSlice());

        @setEvalBranchQuota(10_000);
        const res = json.parse(T, &stream, .{ .allocator = self.allocator.*, .ignore_unknown_fields = true });

        response_buffer.deinit();

        return res;
    }

    pub fn postJSON(self: *@This(), url: []const u8, data: anytype, headers: ?std.StringHashMap([]const u8)) anyerror![]const u8 {
        var post_buffer = std.ArrayList(u8).init(self.allocator.*);
        var response_buffer = std.ArrayList(u8).init(self.allocator.*);

        var rawUrl = try self.allocator.allocSentinel(u8, url.len, 0);
        std.mem.copy(u8, rawUrl, url);

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_URL, rawUrl.ptr) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_NOPROGRESS, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_MAXREDIRS, @as(c_long, 50)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;
        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        var header_slist: [*c]cURL.curl_slist = null;

        if (headers) |h| {
            var iterator = h.iterator();

            while (iterator.next()) |entry| {
                var buf = try self.allocator.alloc(u8, entry.key_ptr.*.len + 3 + entry.value_ptr.*.len);
                _ = try std.fmt.bufPrint(buf, "{s}: {s}\x00", .{ entry.key_ptr.*, entry.value_ptr.* });

                header_slist = cURL.curl_slist_append(header_slist, buf.ptr);
                self.allocator.free(buf);
            }
        }

        header_slist = cURL.curl_slist_append(header_slist, "Content-Type: application/json");

        try json.stringify(data, .{}, post_buffer.writer());

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_POST, @as(c_long, 1)) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_READDATA, &ArrayListReader{
            .items = post_buffer.items,
            .position = 0,
        }) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_READFUNCTION, readFromArrayListCallback) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (header_slist != null) {
            if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_HTTPHEADER, header_slist) != cURL.CURLE_OK)
                return error.CURLSetOptFailed;
        } else {
            if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_HTTPHEADER, @as(c_long, 0)) != cURL.CURLE_OK)
                return error.CURLSetOptFailed;
        }

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_WRITEFUNCTION, writeToArrayListCallback) != cURL.CURLE_OK)
            return error.CURLSetOptFailed;

        if (cURL.curl_easy_setopt(self.ptr, cURL.CURLOPT_WRITEDATA, &response_buffer) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (cURL.curl_easy_perform(self.ptr) != cURL.CURLE_OK)
            return error.CURLPerformFailed;

        if (header_slist != null)
            cURL.curl_slist_free_all(header_slist);

        self.allocator.free(rawUrl);
        post_buffer.deinit();

        var res = response_buffer.toOwnedSlice();
        response_buffer.deinit();

        return res;
    }

    pub fn deinit(self: *@This()) void {
        cURL.curl_easy_cleanup(self.ptr);
    }
};

fn writeToArrayListCallback(data: *anyopaque, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    var buffer = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buffer.appendSlice(typed_data[0 .. nmemb * size]) catch return 0;

    return nmemb * size;
}

fn readFromArrayListCallback(ptr: *anyopaque, ptr_size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    var buffer = @intToPtr(*ArrayListReader, @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(ptr));

    if (buffer.position < buffer.items.len) {
        const size = @minimum(nmemb * ptr_size, @intCast(c_uint, buffer.items.len - buffer.position));

        for (buffer.items[buffer.position .. buffer.position + size]) |s, i|
            typed_data[i] = s;

        buffer.position += size;

        return size;
    }
    return 0;
}
