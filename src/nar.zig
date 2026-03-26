const std = @import("std");
const fs = std.fs;

pub fn unpack(reader: anytype, dest: fs.Dir) anyerror!void {
    try expectStr(reader, "nix-archive-1");
    try parseObject(reader, dest, null);
}

fn parseObject(reader: anytype, parent_dir: fs.Dir, entry_name: ?[]const u8) anyerror!void {
    try expectStr(reader, "(");
    try expectStr(reader, "type");

    var type_buf: [16]u8 = undefined;
    const type_str = try readStr(reader, &type_buf);

    if (std.mem.eql(u8, type_str, "regular")) {
        try parseRegular(reader, parent_dir, entry_name);
        // parseRegular consumes its own closing ")"
    } else if (std.mem.eql(u8, type_str, "directory")) {
        try parseDirectory(reader, parent_dir, entry_name);
        // parseDirectory consumes its own closing ")"
    } else if (std.mem.eql(u8, type_str, "symlink")) {
        try parseSymlink(reader, parent_dir, entry_name);
        try expectStr(reader, ")");
    } else {
        return error.InvalidToken;
    }
}

fn parseRegular(reader: anytype, parent_dir: fs.Dir, entry_name: ?[]const u8) anyerror!void {
    var tag_buf: [16]u8 = undefined;
    const tag = try readStr(reader, &tag_buf);

    var executable = false;
    var has_contents = false;

    if (std.mem.eql(u8, tag, "executable")) {
        executable = true;
        // Read empty string marker
        var empty_buf: [1]u8 = undefined;
        const empty = try readStr(reader, &empty_buf);
        if (empty.len != 0) return error.InvalidToken;
        // Read "contents" tag
        var contents_buf: [16]u8 = undefined;
        const contents_tag = try readStr(reader, &contents_buf);
        if (!std.mem.eql(u8, contents_tag, "contents")) return error.InvalidToken;
        has_contents = true;
    } else if (std.mem.eql(u8, tag, "contents")) {
        has_contents = true;
    } else if (std.mem.eql(u8, tag, ")")) {
        // Empty file — closing paren already consumed from stream
        if (entry_name) |name| {
            const file = try parent_dir.createFile(name, .{});
            file.close();
        }
        return;
    }

    if (has_contents) {
        const size = try readU64(reader);

        if (entry_name) |name| {
            const file = try parent_dir.createFile(name, .{});
            defer file.close();
            try copyBytes(reader, file, size);
            if (executable) {
                file.chmod(0o755) catch {};
            }
        } else {
            try skipBytes(reader, size);
        }

        // Skip padding
        const pad = padLen(size);
        if (pad > 0) {
            var pad_buf: [7]u8 = undefined;
            try readExact(reader, pad_buf[0..pad]);
        }
    }

    try expectStr(reader, ")");
}

fn parseDirectory(reader: anytype, parent_dir: fs.Dir, entry_name: ?[]const u8) anyerror!void {
    var dir: fs.Dir = undefined;
    var owns_dir = false;

    if (entry_name) |name| {
        dir = try parent_dir.makeOpenPath(name, .{});
        owns_dir = true;
    } else {
        dir = parent_dir;
    }
    defer if (owns_dir) dir.close();

    while (true) {
        var tag_buf: [16]u8 = undefined;
        const tag = try readStr(reader, &tag_buf);

        if (std.mem.eql(u8, tag, ")")) {
            return; // End of directory
        }

        if (!std.mem.eql(u8, tag, "entry")) return error.InvalidToken;

        try expectStr(reader, "(");
        try expectStr(reader, "name");

        var name_buf: [256]u8 = undefined;
        const name = try readStr(reader, &name_buf);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return error.InvalidName;
        }
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            return error.InvalidName;
        }

        try expectStr(reader, "node");
        try parseObject(reader, dir, name);
        try expectStr(reader, ")"); // close entry
    }
}

fn parseSymlink(reader: anytype, parent_dir: fs.Dir, entry_name: ?[]const u8) anyerror!void {
    try expectStr(reader, "target");
    var target_buf: [4096]u8 = undefined;
    const target = try readStr(reader, &target_buf);

    if (entry_name) |name| {
        parent_dir.symLink(target, name, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try parent_dir.deleteFile(name);
                try parent_dir.symLink(target, name, .{});
            },
            else => return err,
        };
    }
}

fn readU64(reader: anytype) !u64 {
    var buf: [8]u8 = undefined;
    try readExact(reader, &buf);
    return std.mem.readInt(u64, &buf, .little);
}

fn readStr(reader: anytype, buf: []u8) ![]const u8 {
    const len = try readU64(reader);
    if (len > buf.len) return error.NameTooLong;
    const int_len: usize = @intCast(len);
    try readExact(reader, buf[0..int_len]);

    const pad = padLen(len);
    if (pad > 0) {
        var pad_buf: [7]u8 = undefined;
        try readExact(reader, pad_buf[0..pad]);
        for (pad_buf[0..pad]) |b| {
            if (b != 0) return error.InvalidPadding;
        }
    }

    return buf[0..int_len];
}

fn expectStr(reader: anytype, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    const actual = try readStr(reader, &buf);
    if (!std.mem.eql(u8, actual, expected)) {
        return error.InvalidToken;
    }
}

fn readExact(reader: anytype, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try reader.read(buf[total..]);
        if (n == 0) return error.UnexpectedEof;
        total += n;
    }
}

fn copyBytes(reader: anytype, file: fs.File, size: u64) !void {
    var buf: [65536]u8 = undefined;
    var remaining = size;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buf.len));
        try readExact(reader, buf[0..to_read]);
        try file.writeAll(buf[0..to_read]);
        remaining -= to_read;
    }
}

fn skipBytes(reader: anytype, size: u64) !void {
    var buf: [65536]u8 = undefined;
    var remaining = size;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buf.len));
        try readExact(reader, buf[0..to_read]);
        remaining -= to_read;
    }
}

fn padLen(len: u64) usize {
    const m = len % 8;
    return if (m != 0) @intCast(8 - m) else 0;
}
