const std = @import("std");

pub const nix_store_dir = "/nix/store";

fn getenv(key: []const u8) ?[]const u8 {
    return std.posix.getenv(key);
}

fn getHome() ![]const u8 {
    return getenv("HOME") orelse error.HomeNotSet;
}

pub fn dataDir(allocator: std.mem.Allocator) ![]const u8 {
    if (getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/onyx", .{xdg});
    }
    const home = try getHome();
    return std.fmt.allocPrint(allocator, "{s}/.local/share/onyx", .{home});
}

pub fn cacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (getenv("XDG_CACHE_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/onyx", .{xdg});
    }
    const home = try getHome();
    return std.fmt.allocPrint(allocator, "{s}/.cache/onyx", .{home});
}

pub fn binDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = try getHome();
    return std.fmt.allocPrint(allocator, "{s}/.local/bin", .{home});
}

pub const pkg_store_dir = "/opt/onyx/packages";

pub fn pkgDir(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, pkg_store_dir);
}

pub fn statePath(allocator: std.mem.Allocator) ![]const u8 {
    const data = try dataDir(allocator);
    defer allocator.free(data);
    return std.fmt.allocPrint(allocator, "{s}/state.json", .{data});
}

pub fn makeDirAbsoluteRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist, create it first
            if (std.fs.path.dirname(path)) |parent| {
                try makeDirAbsoluteRecursive(parent);
                try std.fs.makeDirAbsolute(path);
            } else return err;
        },
        else => return err,
    };
}

pub fn ensureDirs(allocator: std.mem.Allocator) !void {
    const data = try dataDir(allocator);
    defer allocator.free(data);

    const cache = try cacheDir(allocator);
    defer allocator.free(cache);

    const bin = try binDir(allocator);
    defer allocator.free(bin);

    const dirs = [_][]const u8{ data, cache, bin };
    for (dirs) |dir| {
        try makeDirAbsoluteRecursive(dir);
    }
}
