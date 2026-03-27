const std = @import("std");
const builtin = @import("builtin");
const xdg = @import("xdg.zig");

pub const system = blk: {
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @compileError("unsupported architecture"),
    };
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        else => @compileError("unsupported OS"),
    };
    break :blk arch ++ "-" ++ os;
};

pub const ResolvedPackage = struct {
    name: []const u8,
    version: []const u8,
    store_path: []const u8,
    _parsed: std.json.Parsed(std.json.Value),
    _allocator: std.mem.Allocator,
    _name_owned: bool,

    pub fn deinit(self: *ResolvedPackage) void {
        if (self._name_owned) self._allocator.free(self.name);
        self._parsed.deinit();
    }
};

pub fn resolve(allocator: std.mem.Allocator, name: []const u8, version: ?[]const u8) !ResolvedPackage {
    return resolveInner(allocator, name, version, true);
}

pub fn resolveCached(allocator: std.mem.Allocator, name: []const u8, version: ?[]const u8) !ResolvedPackage {
    return resolveInner(allocator, name, version, false);
}

fn resolveInner(allocator: std.mem.Allocator, name: []const u8, version: ?[]const u8, refresh: bool) !ResolvedPackage {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Check local index for alias resolution
    const resolved_name = resolveAliasInner(allocator, name, refresh) catch name;
    errdefer if (resolved_name.ptr != name.ptr) allocator.free(resolved_name);

    const actual_version = version orelse "latest";

    // Build resolve URL
    const url = try std.fmt.allocPrint(
        allocator,
        "https://search.devbox.sh/v2/resolve?name={s}&version={s}",
        .{ resolved_name, actual_version },
    );
    defer allocator.free(url);

    // Fetch
    const body = try httpGet(allocator, &client, url);
    defer allocator.free(body);

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    // Navigate to the system-specific entry
    // Response format varies; try to find store path
    const root = parsed.value;

    // Try to find the store path for our system
    const store_path = try findStorePath(root) orelse {
        // Check if the package exists for other platforms
        if (hasAnySystem(root)) return error.NoPlatformBuild;
        return error.PackageNotFound;
    };
    const resolved_version = findVersion(root) orelse actual_version;

    return ResolvedPackage{
        .name = resolved_name,
        .version = resolved_version,
        .store_path = store_path,
        ._allocator = allocator,
        ._name_owned = resolved_name.ptr != name.ptr,
        ._parsed = parsed,
    };
}

fn findStorePath(root: std.json.Value) !?[]const u8 {
    // The Nixhub API response has different structures.
    // Common pattern: root object has system keys, each with outputs array.
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };

    // Try: root[system].outputs[0].path
    if (obj.get(system)) |sys_val| {
        if (extractOutputPath(sys_val)) |path| return path;
    }

    // Try: root.outputs[0].path (single-system response)
    if (extractOutputPath(root)) |path| return path;

    // Try: root.systems[system].outputs[0].path
    if (obj.get("systems")) |systems| {
        if (systems == .object) {
            if (systems.object.get(system)) |sys_val| {
                if (extractOutputPath(sys_val)) |path| return path;
            }
        }
    }

    return null;
}

fn extractOutputPath(val: std.json.Value) ?[]const u8 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };

    // Try outputs array
    if (obj.get("outputs")) |outputs_val| {
        switch (outputs_val) {
            .array => |outputs| {
                for (outputs.items) |output| {
                    if (output == .object) {
                        if (output.object.get("path")) |path_val| {
                            if (path_val == .string) return path_val.string;
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Try store_path directly
    if (obj.get("store_path")) |sp| {
        if (sp == .string) return sp.string;
    }

    return null;
}

/// Check if the response has data for any system (even if not ours).
fn hasAnySystem(root: std.json.Value) bool {
    const obj = switch (root) {
        .object => |o| o,
        else => return false,
    };
    // Check for direct system keys (aarch64-linux, x86_64-darwin, etc.)
    const known = [_][]const u8{ "aarch64-linux", "x86_64-linux", "aarch64-darwin", "x86_64-darwin" };
    for (known) |s| {
        if (obj.get(s) != null) return true;
    }
    // Check systems object
    if (obj.get("systems")) |systems| {
        if (systems == .object and systems.object.count() > 0) return true;
    }
    return false;
}

/// Return the list of available system keys from a resolve response.
pub fn availableSystems(root: std.json.Value) [4]?[]const u8 {
    var result = [_]?[]const u8{ null, null, null, null };
    const obj = switch (root) {
        .object => |o| o,
        else => return result,
    };

    const known = [_][]const u8{ "aarch64-linux", "x86_64-linux", "aarch64-darwin", "x86_64-darwin" };

    // Check top-level system keys
    var i: usize = 0;
    for (known) |s| {
        if (obj.get(s) != null) {
            result[i] = s;
            i += 1;
        }
    }
    if (i > 0) return result;

    // Check systems object
    if (obj.get("systems")) |systems| {
        if (systems == .object) {
            for (known) |s| {
                if (systems.object.get(s) != null) {
                    result[i] = s;
                    i += 1;
                }
            }
        }
    }
    return result;
}

fn findVersion(root: std.json.Value) ?[]const u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    if (obj.get("version")) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

pub fn httpGet(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) {
        return error.HttpError;
    }

    return aw.toOwnedSlice();
}

pub const PackageInfo = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    systems: [4]?[]const u8,
    store_path: ?[]const u8,
    _parsed: std.json.Parsed(std.json.Value),
    _allocator: std.mem.Allocator,
    _name_owned: bool,

    pub fn deinit(self: *PackageInfo) void {
        if (self._name_owned) self._allocator.free(self.name);
        self._parsed.deinit();
    }
};

pub fn info(allocator: std.mem.Allocator, name: []const u8, version: ?[]const u8) !PackageInfo {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const resolved_name = resolveAliasInner(allocator, name, false) catch name;
    errdefer if (resolved_name.ptr != name.ptr) allocator.free(resolved_name);

    const actual_version = version orelse "latest";

    const url = try std.fmt.allocPrint(
        allocator,
        "https://search.devbox.sh/v2/resolve?name={s}&version={s}",
        .{ resolved_name, actual_version },
    );
    defer allocator.free(url);

    const body = try httpGet(allocator, &client, url);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.PackageNotFound,
    };

    const resolved_version = findVersion(root) orelse actual_version;
    const summary = if (obj.get("summary")) |s| switch (s) {
        .string => s.string,
        else => "",
    } else "";

    const systems = availableSystems(root);
    const store_path = try findStorePath(root);

    return PackageInfo{
        .name = resolved_name,
        .version = resolved_version,
        .summary = summary,
        .systems = systems,
        .store_path = store_path,
        ._allocator = allocator,
        ._name_owned = resolved_name.ptr != name.ptr,
        ._parsed = parsed,
    };
}

/// Extract the hash portion from a nix store path.
/// E.g., "/nix/store/abc123-name" -> "abc123"
pub fn storePathHash(store_path: []const u8) ![]const u8 {
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, store_path, prefix)) return error.InvalidStorePath;
    const rest = store_path[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        return rest[0..dash];
    }
    return rest;
}

/// Extract basename from store path: "/nix/store/hash-name" -> "hash-name"
pub fn storePathBasename(store_path: []const u8) ![]const u8 {
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, store_path, prefix)) return error.InvalidStorePath;
    return store_path[prefix.len..];
}

// --- Aliases ---

const aliases_url = "https://raw.githubusercontent.com/lilienblum/onyx/master/aliases.json";

fn ensureAliases(allocator: std.mem.Allocator, refresh: bool) ![]const u8 {
    const cache_dir = try xdg.cacheDir(allocator);
    defer allocator.free(cache_dir);

    try xdg.makeDirAbsoluteRecursive(cache_dir);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/aliases.json", .{cache_dir});
    defer allocator.free(cache_path);

    // Check cache: fast path uses any age, refresh path requires < 1 day
    const stale = blk: {
        if (!refresh) break :blk false;
        const file = std.fs.openFileAbsolute(cache_path, .{}) catch break :blk true;
        defer file.close();
        const stat = file.stat() catch break :blk true;
        break :blk (std.time.nanoTimestamp() - stat.mtime >= 86400 * std.time.ns_per_s);
    };
    if (!stale) {
        if (std.fs.cwd().readFileAlloc(allocator, cache_path, 1 << 20)) |content| {
            return content;
        } else |_| {}
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const body = httpGet(allocator, &client, aliases_url) catch {
        // Offline fallback: return stale cache if available
        return std.fs.cwd().readFileAlloc(allocator, cache_path, 1 << 20) catch return error.IndexFetchFailed;
    };

    // Cache it
    const file = std.fs.createFileAbsolute(cache_path, .{}) catch return body;
    file.writeAll(body) catch {};
    file.close();

    return body;
}

pub fn resolveAlias(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return resolveAliasInner(allocator, name, false);
}

pub fn resolveAliasFresh(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return resolveAliasInner(allocator, name, true);
}

fn resolveAliasInner(allocator: std.mem.Allocator, name: []const u8, refresh: bool) ![]const u8 {
    const content = ensureAliases(allocator, refresh) catch return name;
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return name;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return name,
    };

    if (root.get(name)) |target| {
        if (target == .string) {
            return try allocator.dupe(u8, target.string);
        }
    }

    return name;
}
