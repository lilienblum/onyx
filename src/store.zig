const std = @import("std");
const xdg = @import("xdg.zig");
const resolver = @import("resolver.zig");

pub const Database = struct {
    packages: std.StringArrayHashMap(PackageEntry),
    allocator: std.mem.Allocator,
    _arena: std.heap.ArenaAllocator,

    const PackageEntry = struct {
        versions: std.ArrayList(VersionEntry),
    };

    pub const VersionEntry = struct {
        version: []const u8,
        store_path: []const u8,
        bins: []const []const u8,
        closure: []const []const u8,
        active: bool,
        ephemeral: bool = false,
        last_used: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .packages = std.StringArrayHashMap(PackageEntry).init(allocator),
            .allocator = allocator,
            ._arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Database) void {
        // Free version lists
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.versions.deinit(self.allocator);
        }
        self.packages.deinit();
        self._arena.deinit();
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Database {
        var db = Database.init(allocator);
        errdefer db.deinit();

        const file_contents = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return db,
            else => return err,
        };
        defer allocator.free(file_contents);

        const aa = db._arena.allocator();

        var parsed = try std.json.parseFromSlice(std.json.Value, aa, file_contents, .{
            .allocate = .alloc_always,
        });
        // JSON data lives on the arena — intentionally not deinit'd
        _ = &parsed;

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return db,
        };

        const pkgs = root.get("packages") orelse return db;
        const pkgs_obj = switch (pkgs) {
            .object => |o| o,
            else => return db,
        };

        var pkg_it = pkgs_obj.iterator();
        while (pkg_it.next()) |entry| {
            const pkg_name = entry.key_ptr.*;
            const pkg_val = entry.value_ptr.*;

            const versions_val = switch (pkg_val) {
                .object => |o| o.get("versions") orelse continue,
                else => continue,
            };
            const versions_arr = switch (versions_val) {
                .array => |a| a,
                else => continue,
            };

            var pe = PackageEntry{ .versions = .{} };

            for (versions_arr.items) |ver_val| {
                const ver_obj = switch (ver_val) {
                    .object => |o| o,
                    else => continue,
                };

                const version = switch (ver_obj.get("version") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const store_path = switch (ver_obj.get("store_path") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const active = if (ver_obj.get("active")) |a| switch (a) {
                    .bool => |b| b,
                    else => false,
                } else false;
                const ephemeral = if (ver_obj.get("ephemeral")) |a| switch (a) {
                    .bool => |b| b,
                    else => false,
                } else false;
                const last_used: i64 = if (ver_obj.get("last_used")) |a| switch (a) {
                    .integer => |n| n,
                    else => 0,
                } else 0;

                var bins: std.ArrayList([]const u8) = .{};
                if (ver_obj.get("bins")) |bins_val| {
                    switch (bins_val) {
                        .array => |arr| {
                            for (arr.items) |b| {
                                if (b == .string) try bins.append(aa, b.string);
                            }
                        },
                        else => {},
                    }
                }

                var closure_list: std.ArrayList([]const u8) = .{};
                if (ver_obj.get("closure")) |closure_val| {
                    switch (closure_val) {
                        .array => |arr| {
                            for (arr.items) |c| {
                                if (c == .string) try closure_list.append(aa, c.string);
                            }
                        },
                        else => {},
                    }
                }

                try pe.versions.append(allocator, .{
                    .version = version,
                    .store_path = store_path,
                    .bins = try bins.toOwnedSlice(aa),
                    .closure = try closure_list.toOwnedSlice(aa),
                    .active = active,
                    .ephemeral = ephemeral,
                    .last_used = last_used,
                });
            }

            try db.packages.put(pkg_name, pe);
        }

        return db;
    }

    pub fn save(self: *Database, path: []const u8) !void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |dir| {
            try xdg.makeDirAbsoluteRecursive(dir);
        }

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var w: std.json.Stringify = .{
            .writer = &aw.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        try w.beginObject();
        try w.objectField("packages");
        try w.beginObject();

        var it = self.packages.iterator();
        while (it.next()) |entry| {
            try w.objectField(entry.key_ptr.*);
            try w.beginObject();
            try w.objectField("versions");
            try w.beginArray();

            for (entry.value_ptr.versions.items) |ver| {
                try w.beginObject();
                try w.objectField("version");
                try w.write(ver.version);
                try w.objectField("store_path");
                try w.write(ver.store_path);
                try w.objectField("active");
                try w.write(ver.active);
                if (ver.ephemeral) {
                    try w.objectField("ephemeral");
                    try w.write(true);
                    try w.objectField("last_used");
                    try w.write(ver.last_used);
                }
                try w.objectField("bins");
                try w.beginArray();
                for (ver.bins) |bin| {
                    try w.write(bin);
                }
                try w.endArray();
                try w.objectField("closure");
                try w.beginArray();
                for (ver.closure) |cp| {
                    try w.write(cp);
                }
                try w.endArray();
                try w.endObject();
            }

            try w.endArray();
            try w.endObject();
        }

        try w.endObject();
        try w.endObject();

        const json_str = try aw.toOwnedSlice();
        defer self.allocator.free(json_str);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(json_str);
    }

    pub fn addVersion(self: *Database, name: []const u8, version: []const u8, store_path: []const u8, bins: []const []const u8, closure: []const []const u8, opts: struct { ephemeral: bool = false }) !void {
        const aa = self._arena.allocator();
        const name_d = try aa.dupe(u8, name);
        const version_d = try aa.dupe(u8, version);
        const store_path_d = try aa.dupe(u8, store_path);

        var bins_d = try aa.alloc([]const u8, bins.len);
        for (bins, 0..) |bin, i| {
            bins_d[i] = try aa.dupe(u8, bin);
        }

        var closure_d = try aa.alloc([]const u8, closure.len);
        for (closure, 0..) |cp, i| {
            closure_d[i] = try aa.dupe(u8, cp);
        }

        const gop = try self.packages.getOrPut(name_d);
        if (!gop.found_existing) {
            gop.value_ptr.* = PackageEntry{ .versions = .{} };
        }

        const now: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s));

        // Check if version already exists
        for (gop.value_ptr.versions.items) |*ver| {
            if (std.mem.eql(u8, ver.version, version_d)) {
                ver.store_path = store_path_d;
                ver.bins = bins_d;
                ver.closure = closure_d;
                if (opts.ephemeral) ver.last_used = now;
                return;
            }
        }

        // First version is active by default
        const is_active = gop.value_ptr.versions.items.len == 0;

        try gop.value_ptr.versions.append(self.allocator, .{
            .version = version_d,
            .store_path = store_path_d,
            .bins = bins_d,
            .closure = closure_d,
            .active = is_active,
            .ephemeral = opts.ephemeral,
            .last_used = if (opts.ephemeral) now else 0,
        });
    }

    pub fn getActiveVersion(self: *Database, name: []const u8) ?*VersionEntry {
        const entry = self.packages.getPtr(name) orelse return null;
        for (entry.versions.items) |*ver| {
            if (ver.active) return ver;
        }
        if (entry.versions.items.len > 0) return &entry.versions.items[0];
        return null;
    }

    pub fn setActiveVersion(self: *Database, name: []const u8, version: []const u8) !void {
        const entry = self.packages.getPtr(name) orelse return error.PackageNotInstalled;
        var found = false;
        for (entry.versions.items) |*ver| {
            ver.active = std.mem.eql(u8, ver.version, version);
            if (ver.active) found = true;
        }
        if (!found) return error.VersionNotInstalled;
    }

    pub fn removePackage(self: *Database, name: []const u8) bool {
        if (self.packages.getPtr(name)) |entry| {
            entry.versions.deinit(self.allocator);
        }
        return self.packages.orderedRemove(name);
    }

    pub fn removeVersion(self: *Database, name: []const u8, version: []const u8) bool {
        const entry = self.packages.getPtr(name) orelse return false;
        var i: usize = 0;
        while (i < entry.versions.items.len) {
            if (std.mem.eql(u8, entry.versions.items[i].version, version)) {
                const was_active = entry.versions.items[i].active;
                _ = entry.versions.orderedRemove(i);
                if (entry.versions.items.len == 0) {
                    entry.versions.deinit(self.allocator);
                    _ = self.packages.orderedRemove(name);
                } else if (was_active) {
                    entry.versions.items[0].active = true;
                }
                return true;
            }
            i += 1;
        }
        return false;
    }

    pub fn discoverBins(allocator: std.mem.Allocator, store_path: []const u8) ![]const []const u8 {
        var bins: std.ArrayList([]const u8) = .{};
        errdefer bins.deinit(allocator);

        const bin_path = try std.fmt.allocPrint(allocator, "{s}/bin", .{store_path});
        defer allocator.free(bin_path);

        var dir = std.fs.openDirAbsolute(bin_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return try bins.toOwnedSlice(allocator),
            else => return err,
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                try bins.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }

        return try bins.toOwnedSlice(allocator);
    }

    pub fn installSymlinks(self: *Database, allocator: std.mem.Allocator, name: []const u8) !void {
        const ver = self.getActiveVersion(name) orelse return error.PackageNotInstalled;
        if (ver.store_path.len == 0) return;
        const bin_dir_path = try xdg.binDir(allocator);
        defer allocator.free(bin_dir_path);

        try xdg.makeDirAbsoluteRecursive(bin_dir_path);

        var bin_dir = try std.fs.openDirAbsolute(bin_dir_path, .{});
        defer bin_dir.close();

        // Symlink binaries — skip if a non-symlink file already exists
        for (ver.bins) |bin| {
            const target = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ ver.store_path, bin });
            defer allocator.free(target);

            // Check if something already exists at this path
            const stat = bin_dir.statFile(bin) catch {
                // Nothing there, safe to create
                bin_dir.symLink(target, bin, .{}) catch {};
                continue;
            };

            if (stat.kind == .sym_link) {
                // It's a symlink (probably ours), safe to replace
                bin_dir.deleteFile(bin) catch {};
                bin_dir.symLink(target, bin, .{}) catch {};
            }
            // else: real file exists (e.g. from another package manager), don't touch
        }

        // Symlink shell completions
        const home = std.posix.getenv("HOME") orelse return;
        const completion_srcs = [_][]const u8{
            "share/bash-completion/completions",
            "share/zsh/site-functions",
            "share/fish/vendor_completions.d",
        };
        const completion_dsts = [_][]const u8{
            "/.local/share/bash-completion/completions",
            "/.local/share/zsh/site-functions",
            "/.local/share/fish/vendor_completions.d",
        };

        for (completion_srcs, completion_dsts) |comp_src, comp_dst| {
            const src_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ ver.store_path, comp_src }) catch continue;
            defer allocator.free(src_path);

            var src_dir = std.fs.openDirAbsolute(src_path, .{ .iterate = true }) catch continue;
            defer src_dir.close();

            const dst_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, comp_dst }) catch continue;
            defer allocator.free(dst_path);

            std.fs.makeDirAbsolute(dst_path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => continue,
            };

            var dst_dir = std.fs.openDirAbsolute(dst_path, .{}) catch continue;
            defer dst_dir.close();

            var iter = src_dir.iterate();
            while (iter.next() catch null) |entry| {
                const target = std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.name }) catch continue;
                defer allocator.free(target);
                dst_dir.deleteFile(entry.name) catch {};
                dst_dir.symLink(target, entry.name, .{}) catch {};
            }
        }

        // Symlink man pages
        const man_src = std.fmt.allocPrint(allocator, "{s}/share/man", .{ver.store_path}) catch return;
        defer allocator.free(man_src);

        std.fs.accessAbsolute(man_src, .{}) catch return;

        const man_dst = std.fmt.allocPrint(allocator, "{s}/.local/share/man", .{home}) catch return;
        defer allocator.free(man_dst);

        std.fs.makeDirAbsolute(man_dst) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        // Link man section dirs (man1, man2, etc.)
        var man_dir = std.fs.openDirAbsolute(man_src, .{ .iterate = true }) catch return;
        defer man_dir.close();

        var man_iter = man_dir.iterate();
        while (man_iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;

            const section_src = std.fmt.allocPrint(allocator, "{s}/{s}", .{ man_src, entry.name }) catch continue;
            defer allocator.free(section_src);

            const section_dst = std.fmt.allocPrint(allocator, "{s}/{s}", .{ man_dst, entry.name }) catch continue;
            defer allocator.free(section_dst);

            std.fs.makeDirAbsolute(section_dst) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => continue,
            };

            var sec_src = std.fs.openDirAbsolute(section_src, .{ .iterate = true }) catch continue;
            defer sec_src.close();

            var sec_dst = std.fs.openDirAbsolute(section_dst, .{}) catch continue;
            defer sec_dst.close();

            var sec_iter = sec_src.iterate();
            while (sec_iter.next() catch null) |man_entry| {
                const target = std.fmt.allocPrint(allocator, "{s}/{s}", .{ section_src, man_entry.name }) catch continue;
                defer allocator.free(target);
                sec_dst.deleteFile(man_entry.name) catch {};
                sec_dst.symLink(target, man_entry.name, .{}) catch {};
            }
        }
    }

    pub fn removeSymlinks(self: *Database, allocator: std.mem.Allocator, name: []const u8) !void {
        const entry = self.packages.getPtr(name) orelse return;
        const bin_dir_path = try xdg.binDir(allocator);
        defer allocator.free(bin_dir_path);

        var bin_dir = std.fs.openDirAbsolute(bin_dir_path, .{}) catch return;
        defer bin_dir.close();

        for (entry.versions.items) |ver| {
            if (ver.active) {
                for (ver.bins) |bin| {
                    // Only remove symlinks we own (pointing to /nix/store or our package store)
                    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const target = bin_dir.readLink(bin, &link_buf) catch continue;
                    if (std.mem.startsWith(u8, target, "/nix/store/") or
                        std.mem.indexOf(u8, target, "/onyx/packages/") != null)
                    {
                        bin_dir.deleteFile(bin) catch {};
                    }
                }
            }
        }
        // Note: completion and man page symlinks are left behind on remove
        // They'll be overwritten on next install or cleaned by gc
    }
};
