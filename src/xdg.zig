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

pub fn pkgDir(allocator: std.mem.Allocator) ![]const u8 {
    const data = try dataDir(allocator);
    defer allocator.free(data);
    return std.fmt.allocPrint(allocator, "{s}/packages", .{data});
}

pub fn statePath(allocator: std.mem.Allocator) ![]const u8 {
    const data = try dataDir(allocator);
    defer allocator.free(data);
    return std.fmt.allocPrint(allocator, "{s}/state.json", .{data});
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
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}
