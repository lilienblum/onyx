const std = @import("std");
const ui = @import("ui.zig");
const resolver = @import("resolver.zig");
const builtin = @import("builtin");

/// A resolved third-party package (GitHub or domain).
pub const Package = struct {
    name: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    bins: []const []const u8,
    deps: []const []const u8,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Package) void {
        self._arena.deinit();
    }
};

/// Info extracted from an onyx.toml manifest (all versions/platforms).
pub const ManifestInfo = struct {
    name: []const u8,
    entries: []const Entry,
    _arena: std.heap.ArenaAllocator,

    pub const Entry = struct {
        version: []const u8,
        platform: []const u8,
    };

    pub fn deinit(self: *ManifestInfo) void {
        self._arena.deinit();
    }
};

/// TOML platform name for current system.
pub const platform = switch (builtin.os.tag) {
    .macos => "macos",
    .linux => "linux-" ++ switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => unreachable,
    },
    else => unreachable,
};

/// Resolve a GitHub shorthand: user:repo[@version]
pub fn resolveGithub(allocator: std.mem.Allocator, ref: []const u8, version: ?[]const u8) !Package {
    const colon = std.mem.indexOfScalar(u8, ref, ':') orelse return error.InvalidSource;
    const user = ref[0..colon];
    const repo = ref[colon + 1 ..];
    if (version) |v| {
        const toml_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/onyx.toml", .{ user, repo, v });
        defer allocator.free(toml_url);
        return fetchAndParse(allocator, toml_url, v);
    }

    // Detect default branch via GitHub API
    const branch = try getDefaultBranch(allocator, user, repo);
    defer allocator.free(branch);

    const toml_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/onyx.toml", .{ user, repo, branch });
    defer allocator.free(toml_url);
    return fetchAndParse(allocator, toml_url, null);
}

/// Resolve a domain: tako.sh[@version]
/// Fetches <meta name="onyx" content="git https://github.com/user/repo">
pub fn resolveDomain(allocator: std.mem.Allocator, domain: []const u8, version: ?[]const u8) !Package {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const meta_url = try std.fmt.allocPrint(allocator, "https://{s}?onyx-get=1", .{domain});
    defer allocator.free(meta_url);

    const body = try resolver.httpGet(allocator, &client, meta_url);
    defer allocator.free(body);

    const git_url = try parseOnyxMeta(body) orelse return error.NoOnyxMeta;
    const gh_prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, git_url, gh_prefix)) return error.UnsupportedGitHost;

    const path = git_url[gh_prefix.len..];
    const clean_path = if (std.mem.endsWith(u8, path, ".git")) path[0 .. path.len - 4] else path;

    if (version) |v| {
        const toml_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/onyx.toml", .{ clean_path, v });
        defer allocator.free(toml_url);
        return fetchAndParse(allocator, toml_url, v);
    }

    // Extract user/repo from clean_path for API call
    const slash = std.mem.indexOfScalar(u8, clean_path, '/') orelse return error.InvalidSource;
    const gh_user = clean_path[0..slash];
    const gh_repo = clean_path[slash + 1 ..];

    const branch = try getDefaultBranch(allocator, gh_user, gh_repo);
    defer allocator.free(branch);

    const toml_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/onyx.toml", .{ clean_path, branch });
    defer allocator.free(toml_url);
    return fetchAndParse(allocator, toml_url, null);
}

/// Fetch manifest info for a GitHub package (all versions/platforms).
pub fn infoGithub(allocator: std.mem.Allocator, ref: []const u8, version: ?[]const u8) !ManifestInfo {
    const colon = std.mem.indexOfScalar(u8, ref, ':') orelse return error.InvalidSource;
    const user = ref[0..colon];
    const repo = ref[colon + 1 ..];

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const toml_url = if (version) |v|
        try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/onyx.toml", .{ user, repo, v })
    else blk: {
        const branch = try getDefaultBranch(allocator, user, repo);
        defer allocator.free(branch);
        break :blk try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}/onyx.toml", .{ user, repo, branch });
    };
    defer allocator.free(toml_url);

    const body = try resolver.httpGet(allocator, &client, toml_url);
    defer allocator.free(body);

    return parseManifestInfo(allocator, body);
}

/// Fetch manifest info for a domain package (all versions/platforms).
pub fn infoDomain(allocator: std.mem.Allocator, domain: []const u8, version: ?[]const u8) !ManifestInfo {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const meta_url = try std.fmt.allocPrint(allocator, "https://{s}?onyx-get=1", .{domain});
    defer allocator.free(meta_url);

    const body = try resolver.httpGet(allocator, &client, meta_url);
    defer allocator.free(body);

    const git_url = try parseOnyxMeta(body) orelse return error.NoOnyxMeta;
    const gh_prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, git_url, gh_prefix)) return error.UnsupportedGitHost;

    const path = git_url[gh_prefix.len..];
    const clean_path = if (std.mem.endsWith(u8, path, ".git")) path[0 .. path.len - 4] else path;

    const toml_url = if (version) |v|
        try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/onyx.toml", .{ clean_path, v })
    else blk: {
        const slash = std.mem.indexOfScalar(u8, clean_path, '/') orelse return error.InvalidSource;
        const gh_user = clean_path[0..slash];
        const gh_repo = clean_path[slash + 1 ..];
        const branch = try getDefaultBranch(allocator, gh_user, gh_repo);
        defer allocator.free(branch);
        break :blk try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/onyx.toml", .{ clean_path, branch });
    };
    defer allocator.free(toml_url);

    const toml_body = try resolver.httpGet(allocator, &client, toml_url);
    defer allocator.free(toml_body);

    return parseManifestInfo(allocator, toml_body);
}

/// Get default branch name from GitHub API.
fn getDefaultBranch(allocator: std.mem.Allocator, user: []const u8, repo: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}", .{ user, repo });
    defer allocator.free(api_url);

    const body = resolver.httpGet(allocator, &client, api_url) catch {
        // Fallback if API fails
        return try allocator.dupe(u8, "master");
    };
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    }) catch return try allocator.dupe(u8, "master");
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("default_branch")) |branch| {
            if (branch == .string) {
                return try allocator.dupe(u8, branch.string);
            }
        }
    }

    return try allocator.dupe(u8, "master");
}

fn fetchAndParse(allocator: std.mem.Allocator, toml_url: []const u8, version: ?[]const u8) !Package {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const body = try resolver.httpGet(allocator, &client, toml_url);
    defer allocator.free(body);

    return parseOnyxToml(allocator, body, version);
}

// --- TOML Parser ---

const Section = enum { none, package, release };

pub fn parseOnyxToml(allocator: std.mem.Allocator, content: []const u8, req_version: ?[]const u8) !Package {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var name: []const u8 = "";
    var matched_version: []const u8 = "";
    var url: []const u8 = "";
    var sha256: []const u8 = "";
    var bins: std.ArrayList([]const u8) = .{};
    var deps: std.ArrayList([]const u8) = .{};

    var section: Section = .none;
    var current_version: []const u8 = "";
    var current_platform: []const u8 = "";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section headers
        if (trimmed[0] == '[') {
            const hdr = std.mem.trim(u8, trimmed, "[] \t");

            if (std.mem.eql(u8, hdr, "package")) {
                section = .package;
                continue;
            }

            // ["1.0.0".platform]
            if (hdr.len > 0 and hdr[0] == '"') {
                section = .release;
                if (std.mem.indexOfScalar(u8, hdr[1..], '"')) |ver_end| {
                    current_version = try aa.dupe(u8, hdr[1 .. 1 + ver_end]);
                    current_platform = "";
                    const after = 1 + ver_end + 1;
                    if (after < hdr.len and hdr[after] == '.') {
                        current_platform = try aa.dupe(u8, hdr[after + 1 ..]);
                    }
                }
                continue;
            }

            // Any other section
            section = .none;
            continue;
        }

        // Key = value
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        var val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        // Strip quotes
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        // Root-level fields (before any section or in [package])
        if (section == .none or section == .package) {
            if (std.mem.eql(u8, key, "deps")) {
                if (val.len > 1 and val[0] == '[') {
                    const inner = if (val[val.len - 1] == ']') val[1 .. val.len - 1] else val[1..];
                    var it = std.mem.splitScalar(u8, inner, ',');
                    while (it.next()) |item| {
                        const clean = std.mem.trim(u8, item, " \t\"");
                        if (clean.len > 0) try deps.append(aa, try aa.dupe(u8, clean));
                    }
                }
            }
        }

        switch (section) {
            .package => {
                if (std.mem.eql(u8, key, "name")) {
                    name = try aa.dupe(u8, val);
                }
            },
            .release => {
                const ver_matches = if (req_version) |rv|
                    std.mem.startsWith(u8, current_version, rv) and
                        (rv.len == current_version.len or
                        (rv.len < current_version.len and current_version[rv.len] == '.'))
                else
                    current_version.len > 0;

                if (!ver_matches or !std.mem.eql(u8, current_platform, platform)) continue;

                if (std.mem.eql(u8, key, "url")) {
                    url = try aa.dupe(u8, val);
                    matched_version = current_version;
                } else if (std.mem.eql(u8, key, "sha256")) {
                    sha256 = try aa.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "bin")) {
                    if (val.len > 1 and val[0] == '[') {
                        const inner = if (val[val.len - 1] == ']') val[1 .. val.len - 1] else val[1..];
                        var it = std.mem.splitScalar(u8, inner, ',');
                        while (it.next()) |item| {
                            const clean = std.mem.trim(u8, item, " \t\"");
                            if (clean.len > 0) try bins.append(aa, try aa.dupe(u8, clean));
                        }
                    }
                }
            },
            .none => {},
        }
    }

    if (url.len == 0) return error.NoBinaryForPlatform;
    if (matched_version.len == 0) return error.NoVersionFound;

    return Package{
        .name = if (name.len > 0) name else "unknown",
        .version = matched_version,
        .url = url,
        .sha256 = sha256,
        .bins = bins.toOwnedSlice(aa) catch &.{},
        .deps = deps.toOwnedSlice(aa) catch &.{},
        ._arena = arena,
    };
}

// --- Meta tag parser ---

pub fn parseOnyxMeta(html: []const u8) !?[]const u8 {
    const needle = "name=\"onyx\"";
    const pos = std.mem.indexOf(u8, html, needle) orelse return null;

    const after = html[pos + needle.len ..];
    const content_start = std.mem.indexOf(u8, after, "content=\"") orelse return null;
    const val_start = content_start + "content=\"".len;
    const val_end = std.mem.indexOfScalar(u8, after[val_start..], '"') orelse return null;

    const content = after[val_start .. val_start + val_end];

    if (std.mem.startsWith(u8, content, "git ")) {
        return content[4..];
    }

    return content;
}

/// Parse an onyx.toml manifest to extract all version/platform entries.
pub fn parseManifestInfo(allocator: std.mem.Allocator, content: []const u8) !ManifestInfo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var name: []const u8 = "";
    var entries: std.ArrayList(ManifestInfo.Entry) = .{};
    var section: Section = .none;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '[') {
            const hdr = std.mem.trim(u8, trimmed, "[] \t");
            if (std.mem.eql(u8, hdr, "package")) {
                section = .package;
                continue;
            }
            if (hdr.len > 0 and hdr[0] == '"') {
                section = .release;
                if (std.mem.indexOfScalar(u8, hdr[1..], '"')) |ver_end| {
                    const ver = hdr[1 .. 1 + ver_end];
                    const after = 1 + ver_end + 1;
                    if (after < hdr.len and hdr[after] == '.') {
                        const plat = hdr[after + 1 ..];
                        try entries.append(aa, .{
                            .version = try aa.dupe(u8, ver),
                            .platform = try aa.dupe(u8, plat),
                        });
                    }
                }
                continue;
            }
            section = .none;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        var val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        if (section == .package or section == .none) {
            if (std.mem.eql(u8, key, "name")) {
                name = try aa.dupe(u8, val);
            }
        }
    }

    return ManifestInfo{
        .name = if (name.len > 0) name else "unknown",
        .entries = entries.toOwnedSlice(aa) catch &.{},
        ._arena = arena,
    };
}
