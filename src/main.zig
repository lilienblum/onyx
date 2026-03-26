const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const resolver = @import("resolver.zig");
const fetcher = @import("fetcher.zig");
const source = @import("source.zig");
const store = @import("store.zig");
const xdg = @import("xdg.zig");
const ui = @import("ui.zig");

/// Detect source type from package ref.
const SourceType = enum { nix, github, domain };

fn detectSource(ref: cli.PackageRef) SourceType {
    const name = ref.source orelse ref.name;
    // Has : → GitHub shorthand (user:repo)
    if (std.mem.indexOfScalar(u8, name, ':') != null) return .github;
    // Has . → domain (tako.sh)
    if (std.mem.indexOfScalar(u8, name, '.') != null) return .domain;
    return .nix;
}

// x-release-please-start-version
pub const version = "0.1.0";
// x-release-please-end

pub fn main() !void {
    ui.init();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            ui.print("onyx {s}\n", .{version});
            return;
        }
    }

    const cmd = cli.parse(args) catch {
        ui.err("missing argument", .{});
        ui.print("\n", .{});
        ui.printUsage();
        std.process.exit(1);
    };

    switch (cmd) {
        .install => |ref| cmdInstall(allocator, ref) catch |e| {
            switch (e) {
                error.HttpError => ui.err("package not found: {s}", .{ref.name}),
                error.PackageNotFound => ui.err("package not found: {s}", .{ref.name}),
                error.NoBinaryForPlatform => ui.err("no binary available for {s} on {s}", .{ ref.name, source.platform }),
                error.NoVersionFound => ui.err("version not found: {s}", .{if (ref.version) |v| v else "latest"}),
                else => ui.err("{}", .{e}),
            }
            std.process.exit(1);
        },
        .uninstall => |ref| cmdUninstall(allocator, ref) catch |e| fatal(e),
        .list => cmdList(allocator) catch |e| fatal(e),
        .exec => |ea| cmdExec(allocator, ea) catch |e| {
            switch (e) {
                error.HttpError => ui.err("package not found: {s}", .{ea.package.name}),
                error.PackageNotFound => ui.err("package not found: {s}", .{ea.package.name}),
                else => ui.err("{}", .{e}),
            }
            std.process.exit(1);
        },
        .use_cmd => |ref| cmdUse(allocator, ref) catch |e| fatal(e),
        .gc => cmdGc(allocator) catch |e| fatal(e),
        .init_cmd => |exec| cmdInit(allocator, exec) catch |e| fatal(e),
        .implode => |exec| cmdImplode(allocator, exec) catch |e| fatal(e),
        .upgrade => |ua| cmdUpgrade(allocator, ua) catch |e| fatal(e),
        .help => ui.printUsage(),
    }
}

fn fatal(e: anyerror) noreturn {
    ui.err("{}", .{e});
    std.process.exit(1);
}

fn acquireLock(allocator: std.mem.Allocator) !std.fs.File {
    const data_dir = try xdg.dataDir(allocator);
    defer allocator.free(data_dir);

    try xdg.makeDirAbsoluteRecursive(data_dir);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/lock", .{data_dir});
    defer allocator.free(lock_path);

    const file = try std.fs.createFileAbsolute(lock_path, .{ .read = true });
    file.lock(.exclusive) catch {
        ui.err("another onyx process is running", .{});
        std.process.exit(1);
    };
    return file;
}

fn releaseLock(file: std.fs.File) void {
    file.unlock();
    file.close();
}

fn cmdInstall(allocator: std.mem.Allocator, ref: cli.PackageRef) anyerror!void {
    const lock = try acquireLock(allocator);
    defer releaseLock(lock);
    return cmdInstallInner(allocator, ref);
}

fn cmdInstallInner(allocator: std.mem.Allocator, ref: cli.PackageRef) anyerror!void {
    const src_type = detectSource(ref);

    switch (src_type) {
        .github, .domain => return installThirdParty(allocator, ref, src_type),
        .nix => {},
    }

    // Nix package install
    try ensureNixStore();

    ui.status("installing {s}...", .{ref.name});

    var resolved = try resolver.resolve(allocator, ref.name, ref.version);
    defer resolved.deinit();

    // Check if already installed
    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    if (db.getActiveVersion(resolved.name)) |ver| {
        if (std.mem.eql(u8, ver.store_path, resolved.store_path)) {
            ui.print("already installed {s}@{s}\n", .{ resolved.name, ver.version });
            if (ver.bins.len > 0) {
                ui.print("  ", .{});
                for (ver.bins, 0..) |bin, i| {
                    if (i > 0) ui.print(", ", .{});
                    ui.print("{s}", .{bin});
                }
                ui.print("\n", .{});
            }
            return;
        }
    }

    const closure = try fetcher.fetchClosure(allocator, resolved.store_path);
    defer {
        for (closure) |cp| allocator.free(cp);
        allocator.free(closure);
    }

    const bins = try store.Database.discoverBins(allocator, resolved.store_path);
    defer {
        for (bins) |b| allocator.free(b);
        allocator.free(bins);
    }

    try db.addVersion(resolved.name, resolved.version, resolved.store_path, bins, closure, .{});

    // If this was previously ephemeral, clear the flag (explicit install = permanent)
    if (db.getActiveVersion(resolved.name)) |ver| {
        ver.ephemeral = false;
        ver.last_used = 0;
    }

    try db.installSymlinks(allocator, resolved.name);
    try db.save(state_path);

    ui.ok("installed {s}@{s}", .{ resolved.name, resolved.version });
    if (bins.len > 0) {
        ui.print("  ", .{});
        for (bins, 0..) |bin, i| {
            if (i > 0) ui.print(", ", .{});
            ui.print("{s}", .{bin});
        }
        ui.print("\n", .{});
    }
}

fn installThirdParty(allocator: std.mem.Allocator, ref: cli.PackageRef, src_type: SourceType) !void {
    const name = ref.source orelse ref.name;

    ui.status("installing {s}...", .{name});

    var pkg = switch (src_type) {
        .github => try source.resolveGithub(allocator, name, ref.version),
        .domain => try source.resolveDomain(allocator, name, ref.version),
        .nix => unreachable,
    };
    defer pkg.deinit();

    ui.pkg(pkg.name, pkg.version);

    // Install dependencies first
    if (pkg.deps.len > 0) {
        ui.status("installing {d} dependencies...", .{pkg.deps.len});
        for (pkg.deps) |dep| {
            const dep_ref = cli.PackageRef.parse(dep);
            cmdInstallInner(allocator, dep_ref) catch |err| {
                ui.err("failed to install dependency {s}: {}", .{ dep, err });
                return err;
            };
        }
    }

    // Download the binary
    ui.status("downloading...", .{});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = pkg.url },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.DownloadFailed;

    const data = try aw.toOwnedSlice();
    defer allocator.free(data);

    // Verify SHA256 if provided
    if (pkg.sha256.len > 0) {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data);
        const hex = std.fmt.bytesToHex(hasher.finalResult(), .lower);
        if (!std.mem.eql(u8, &hex, pkg.sha256)) {
            ui.err("sha256 mismatch for {s}", .{pkg.name});
            return error.HashMismatch;
        }
    }

    // Install to package store: ~/.local/share/onyx/packages/{name}/{version}/
    const pkg_base = try xdg.pkgDir(allocator);
    defer allocator.free(pkg_base);

    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ pkg_base, pkg.name, pkg.version });
    defer allocator.free(pkg_path);

    const pkg_bin_path = try std.fmt.allocPrint(allocator, "{s}/bin", .{pkg_path});
    defer allocator.free(pkg_bin_path);

    // Clean previous install of same version
    std.fs.deleteTreeAbsolute(pkg_path) catch {};

    // Create bin dir (and parents)
    std.fs.makeDirAbsolute(pkg_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const name_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_base, pkg.name });
    defer allocator.free(name_dir);
    std.fs.makeDirAbsolute(name_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(pkg_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(pkg_bin_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    if (std.mem.endsWith(u8, pkg.url, ".tar.gz") or std.mem.endsWith(u8, pkg.url, ".tgz")) {
        const cache_dir = try xdg.cacheDir(allocator);
        defer allocator.free(cache_dir);

        try xdg.makeDirAbsoluteRecursive(cache_dir);

        const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tar.gz", .{ cache_dir, pkg.name });
        defer allocator.free(archive_path);

        const archive_file = try std.fs.createFileAbsolute(archive_path, .{});
        try archive_file.writeAll(data);
        archive_file.close();

        // Extract to a temp dir, then move bins into the package bin/
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}/extract-{s}", .{ cache_dir, pkg.name });
        defer allocator.free(tmp_path);

        std.fs.deleteTreeAbsolute(tmp_path) catch {};
        std.fs.makeDirAbsolute(tmp_path) catch {};

        var tar = std.process.Child.init(
            &.{ "tar", "xzf", archive_path, "-C", tmp_path },
            allocator,
        );
        const tar_term = try tar.spawnAndWait();
        if (tar_term != .Exited or tar_term.Exited != 0) return error.ExtractFailed;

        for (pkg.bins) |bin| {
            const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_bin_path, bin });
            defer allocator.free(dst);

            const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_path, bin });
            defer allocator.free(src);

            const actual_src = blk: {
                std.fs.accessAbsolute(src, .{}) catch {
                    var find = std.process.Child.init(
                        &.{ "find", tmp_path, "-name", bin, "-type", "f" },
                        allocator,
                    );
                    find.stdout_behavior = .Pipe;
                    _ = try find.spawn();
                    var stdout_buf: [4096]u8 = undefined;
                    const find_out = find.stdout.?;
                    var n: usize = 0;
                    while (n < stdout_buf.len) {
                        const r = try find_out.read(stdout_buf[n..]);
                        if (r == 0) break;
                        n += r;
                    }
                    _ = try find.wait();
                    if (n > 0) {
                        const found = std.mem.trim(u8, stdout_buf[0..n], " \t\n\r");
                        if (std.mem.indexOfScalar(u8, found, '\n')) |nl| {
                            break :blk found[0..nl];
                        }
                        break :blk found;
                    }
                    continue;
                };
                break :blk src;
            };

            std.fs.renameAbsolute(actual_src, dst) catch {
                var child = std.process.Child.init(
                    &.{ "cp", actual_src, dst },
                    allocator,
                );
                _ = try child.spawnAndWait();
            };

            var f = std.fs.openFileAbsolute(dst, .{ .mode = .read_write }) catch continue;
            f.chmod(0o755) catch {};
            f.close();
        }

        std.fs.deleteTreeAbsolute(tmp_path) catch {};
        std.fs.deleteFileAbsolute(archive_path) catch {};
    } else {
        // Raw binary
        const bin_name = if (pkg.bins.len > 0) pkg.bins[0] else pkg.name;
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_bin_path, bin_name });
        defer allocator.free(dst);

        const file = try std.fs.createFileAbsolute(dst, .{});
        try file.writeAll(data);
        file.chmod(0o755) catch {};
        file.close();
    }

    // Save to db and symlink
    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    try db.addVersion(pkg.name, pkg.version, pkg_path, pkg.bins, &.{}, .{});
    try db.installSymlinks(allocator, pkg.name);
    try db.save(state_path);

    ui.ok("installed {s}@{s}", .{ pkg.name, pkg.version });
    for (pkg.bins) |bin| {
        ui.detail("{s}", .{bin});
    }
}

fn cmdUninstall(allocator: std.mem.Allocator, ref: cli.PackageRef) !void {
    const lock = try acquireLock(allocator);
    defer releaseLock(lock);

    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    // Try resolved alias, fall back to raw name if not in state
    const resolved = resolver.resolveAlias(allocator, ref.name) catch ref.name;
    const pkg_name = if (db.packages.contains(resolved)) resolved else ref.name;
    defer if (resolved.ptr != ref.name.ptr) allocator.free(resolved);

    if (ref.version) |ver| {
        // Remove specific version
        if (db.removeVersion(pkg_name, ver)) {
            try db.removeSymlinks(allocator, pkg_name);
            // Re-link active version if any remain
            if (db.getActiveVersion(pkg_name) != null) {
                try db.installSymlinks(allocator, pkg_name);
            }
            try db.save(state_path);
            ui.print("removed {s}@{s}\n", .{ ref.name, ver });
        } else {
            ui.print("{s}@{s} is not installed\n", .{ ref.name, ver });
        }
    } else {
        // Get info before removing
        const active = db.getActiveVersion(pkg_name);
        const ver_str = if (active) |v| v.version else "";
        const bins = if (active) |v| v.bins else &[_][]const u8{};

        try db.removeSymlinks(allocator, pkg_name);
        if (db.removePackage(pkg_name)) {
            try db.save(state_path);
            cleanupPaths(allocator, pkg_name);
            cleanupPkgStore(allocator, pkg_name);
            ui.print("removed {s}@{s}\n", .{ pkg_name, ver_str });
            if (bins.len > 0) {
                ui.print("  ", .{});
                for (bins, 0..) |bin, i| {
                    if (i > 0) ui.print(", ", .{});
                    ui.print("{s}", .{bin});
                }
                ui.print("\n", .{});
            }
        } else {
            ui.print("{s} is not installed\n", .{ref.name});
        }
    }
}

/// Fetch cleanup paths from registry and delete them.
fn cleanupPaths(allocator: std.mem.Allocator, name: []const u8) void {
    const toml_url = resolver.registryUrl(allocator, name) catch return;
    defer allocator.free(toml_url);

    const full_url = std.fmt.allocPrint(allocator, "{s}.toml", .{toml_url}) catch return;
    defer allocator.free(full_url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const body = resolver.httpGet(allocator, &client, full_url) catch return;
    defer allocator.free(body);

    const home = std.posix.getenv("HOME") orelse return;

    // Determine which cleanup sections to use
    const os_section = if (comptime builtin.os.tag == .macos) "cleanup.macos" else "cleanup.linux";
    const sections = [_][]const u8{ "cleanup", os_section };

    for (sections) |target_section| {
        var in_section = false;
        var in_paths = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len > 0 and trimmed[0] == '[') {
                const hdr = std.mem.trim(u8, trimmed, "[] \t");
                in_section = std.mem.eql(u8, hdr, target_section);
                in_paths = false;
                continue;
            }

            if (!in_section) continue;

            if (std.mem.startsWith(u8, trimmed, "paths")) {
                in_paths = true;
                continue;
            }

            if (in_paths and trimmed.len > 0 and trimmed[0] == ']') {
                in_paths = false;
                continue;
            }

            if (in_paths and trimmed.len > 2 and trimmed[0] == '"') {
                const path_val = std.mem.trim(u8, trimmed, " \t\",");
                if (path_val.len == 0) continue;

                // Expand ~ (with safety checks)
                if (std.mem.startsWith(u8, path_val, "~/")) {
                    if (path_val.len <= 2) continue; // reject "~/" alone
                    if (std.mem.indexOf(u8, path_val, "..") != null) continue;
                    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, path_val[2..] }) catch continue;
                    defer allocator.free(full);
                    std.fs.deleteTreeAbsolute(full) catch continue;
                }
            }
        }
    }
}

/// Delete the package store directory for a third-party package.
fn cleanupPkgStore(allocator: std.mem.Allocator, name: []const u8) void {
    const pkg_base = xdg.pkgDir(allocator) catch return;
    defer allocator.free(pkg_base);

    const pkg_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pkg_base, name }) catch return;
    defer allocator.free(pkg_dir);

    std.fs.deleteTreeAbsolute(pkg_dir) catch {};
}

fn cmdList(allocator: std.mem.Allocator) !void {
    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    var count: usize = 0;
    var it = db.packages.iterator();
    while (it.next()) |entry| {
        const all_ephemeral = for (entry.value_ptr.versions.items) |ver| {
            if (!ver.ephemeral) break false;
        } else true;
        if (all_ephemeral) continue;

        ui.listPackage(entry.key_ptr.*, entry.value_ptr.versions.items);
        count += 1;
    }

    if (count == 0) {
        ui.print("no packages installed\n", .{});
    }
}

fn cmdExec(allocator: std.mem.Allocator, ea: cli.ExecArgs) !void {
    // Fast path: if already in state, use stored data — no network
    blk: {
        const state_path = try xdg.statePath(allocator);
        defer allocator.free(state_path);

        var db = try store.Database.load(allocator, state_path);
        defer db.deinit();

        const resolved_name = resolver.resolveAlias(allocator, ea.package.name) catch ea.package.name;
        defer if (resolved_name.ptr != ea.package.name.ptr) allocator.free(resolved_name);

        if (db.getActiveVersion(resolved_name)) |ver| {
            // If a specific version was requested, make sure it matches
            if (ea.package.version) |req_ver| {
                if (!std.mem.startsWith(u8, ver.version, req_ver)) break :blk;
            }
            if (ver.store_path.len > 0) {
                if (ver.ephemeral) {
                    ver.last_used = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s));
                    try db.save(state_path);
                }
                return execBin(allocator, ver.store_path, ver.bins, ea);
            }
        }
    }

    // Slow path: not installed yet — resolve, fetch, save as ephemeral
    try ensureNixStore();

    var resolved = try resolver.resolve(allocator, ea.package.name, ea.package.version);
    defer resolved.deinit();

    ui.status("fetching {s}@{s}...", .{ resolved.name, resolved.version });
    const closure = try fetcher.fetchClosure(allocator, resolved.store_path);
    defer {
        for (closure) |cp| allocator.free(cp);
        allocator.free(closure);
    }

    const bins = try store.Database.discoverBins(allocator, resolved.store_path);
    defer {
        for (bins) |b| allocator.free(b);
        allocator.free(bins);
    }

    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    try db.addVersion(resolved.name, resolved.version, resolved.store_path, bins, closure, .{ .ephemeral = true });
    try db.save(state_path);

    return execBin(allocator, resolved.store_path, bins, ea);
}

fn execBin(allocator: std.mem.Allocator, store_path: []const u8, bins: []const []const u8, ea: cli.ExecArgs) !void {
    if (bins.len == 0) {
        // Fall back to discovering bins from the store path
        const discovered = try store.Database.discoverBins(allocator, store_path);
        defer {
            for (discovered) |b| allocator.free(b);
            allocator.free(discovered);
        }
        if (discovered.len == 0) {
            ui.err("no binaries found in {s}", .{store_path});
            std.process.exit(1);
        }
        return execBinInner(allocator, store_path, discovered, ea);
    }
    return execBinInner(allocator, store_path, bins, ea);
}

fn execBinInner(allocator: std.mem.Allocator, store_path: []const u8, bins: []const []const u8, ea: cli.ExecArgs) !void {
    var bin_name: []const u8 = bins[0];
    if (ea.bin) |explicit_bin| {
        bin_name = explicit_bin;
    } else {
        for (bins) |b| {
            if (std.mem.eql(u8, b, ea.package.name)) {
                bin_name = b;
                break;
            }
        }
    }

    const bin_path = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ store_path, bin_name });
    defer allocator.free(bin_path);

    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, bin_path);
    for (ea.args) |arg| {
        try argv.append(allocator, arg);
    }

    return std.process.execv(allocator, argv.items);
}

fn cmdUse(allocator: std.mem.Allocator, ref: cli.PackageRef) !void {
    const lock = try acquireLock(allocator);
    defer releaseLock(lock);

    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    // Resolve alias (node → nodejs)
    const resolved = resolver.resolveAlias(allocator, ref.name) catch ref.name;
    const pkg_name = if (db.packages.contains(resolved)) resolved else ref.name;
    defer if (resolved.ptr != ref.name.ptr) allocator.free(resolved);

    // If no version specified, pick the latest installed version
    const ver = ref.version orelse blk: {
        const entry = db.packages.getPtr(pkg_name) orelse {
            ui.err("{s} is not installed", .{ref.name});
            std.process.exit(1);
        };
        if (entry.versions.items.len == 0) {
            ui.err("{s} is not installed", .{ref.name});
            std.process.exit(1);
        }
        break :blk entry.versions.items[entry.versions.items.len - 1].version;
    };

    try db.removeSymlinks(allocator, pkg_name);

    db.setActiveVersion(pkg_name, ver) catch |e| {
        switch (e) {
            error.PackageNotInstalled => {
                ui.err("{s} is not installed", .{ref.name});
                std.process.exit(1);
            },
            error.VersionNotInstalled => {
                ui.err("{s}@{s} is not installed", .{ ref.name, ver });
                std.process.exit(1);
            },
            else => return e,
        }
    };

    try db.installSymlinks(allocator, pkg_name);
    try db.save(state_path);

    ui.print("switched to {s}@{s}\n", .{ ref.name, ver });
}

fn cmdGc(allocator: std.mem.Allocator) !void {
    try ensureNixStore();
    const lock = try acquireLock(allocator);
    defer releaseLock(lock);
    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    // Remove ephemeral packages not used in 30 days
    const now: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s));
    const thirty_days = 30 * 86400;
    var expired: std.ArrayList([]const u8) = .{};
    defer expired.deinit(allocator);

    var exp_it = db.packages.iterator();
    while (exp_it.next()) |entry| {
        const all_ephemeral_expired = for (entry.value_ptr.versions.items) |ver| {
            if (!ver.ephemeral or (now - ver.last_used) < thirty_days) break false;
        } else entry.value_ptr.versions.items.len > 0;

        if (all_ephemeral_expired) {
            try expired.append(allocator, entry.key_ptr.*);
        }
    }

    for (expired.items) |name| {
        db.removeSymlinks(allocator, name) catch {};
        if (db.removePackage(name)) {
            cleanupPkgStore(allocator, name);
            ui.detail("expired ephemeral: {s}", .{name});
        }
    }

    if (expired.items.len > 0) {
        try db.save(state_path);
    }

    // Clean orphaned third-party package dirs
    const pkg_base = xdg.pkgDir(allocator) catch null;
    if (pkg_base) |pb| {
        defer allocator.free(pb);
        var pkg_dir = std.fs.openDirAbsolute(pb, .{ .iterate = true }) catch null;
        if (pkg_dir) |*pd| {
            defer pd.close();
            var piter = pd.iterate();
            while (piter.next() catch null) |entry| {
                if (!db.packages.contains(entry.name)) {
                    ui.detail("removing {s}", .{entry.name});
                    pd.deleteTree(entry.name) catch {};
                }
            }
        }
    }

    var keep = std.StringHashMap(void).init(allocator);
    defer keep.deinit();

    var pkg_it = db.packages.iterator();
    while (pkg_it.next()) |entry| {
        for (entry.value_ptr.versions.items) |ver| {
            if (ver.store_path.len == 0) continue;
            const basename = resolver.storePathBasename(ver.store_path) catch continue;
            try keep.put(basename, {});
            for (ver.closure) |cp| {
                const cb = resolver.storePathBasename(cp) catch continue;
                try keep.put(cb, {});
            }
        }
    }

    var nix_store = std.fs.openDirAbsolute("/nix/store", .{ .iterate = true }) catch |e| {
        ui.err("cannot open /nix/store: {}", .{e});
        return;
    };
    defer nix_store.close();

    ui.print("scanning store...\n", .{});

    var removed: usize = 0;
    var iter = nix_store.iterate();
    while (try iter.next()) |entry| {
        if (!keep.contains(entry.name)) {
            ui.detail("removing {s}", .{entry.name});
            nix_store.deleteTree(entry.name) catch |e| {
                ui.warn("could not remove {s}: {}", .{ entry.name, e });
                continue;
            };
            removed += 1;
        }
    }

    if (removed == 0) {
        ui.print("nothing to clean up\n", .{});
    } else {
        ui.print("cleaned {d} store paths\n", .{removed});
    }
}

fn cmdUpgrade(allocator: std.mem.Allocator, ua: cli.UpgradeArgs) !void {
    // Upgrade onyx itself (unless targeting a specific package)
    if (ua.package == null) {
        try selfUpdate(allocator);
    }
    if (ua.self_only) return;

    // Upgrade packages
    try ensureNixStore();
    const lock = try acquireLock(allocator);
    defer releaseLock(lock);
    const state_path = try xdg.statePath(allocator);
    defer allocator.free(state_path);

    var db = try store.Database.load(allocator, state_path);
    defer db.deinit();

    var upgraded: usize = 0;
    var it = db.packages.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;

        if (ua.package) |target| {
            if (!std.mem.eql(u8, name, target)) continue;
        }

        var resolved = resolver.resolve(allocator, name, null) catch |e| {
            ui.warn("could not resolve {s}: {}", .{ name, e });
            continue;
        };
        defer resolved.deinit();

        const active = db.getActiveVersion(name);
        if (active) |ver| {
            if (std.mem.eql(u8, ver.store_path, resolved.store_path)) {
                ui.print("{s}@{s} up to date\n", .{ name, ver.version });
                continue;
            }
        }

        ui.status("upgrading {s} to {s}...", .{ name, resolved.version });

        const closure = fetcher.fetchClosure(allocator, resolved.store_path) catch |e| {
            ui.warn("failed to fetch {s}: {}", .{ name, e });
            continue;
        };
        defer {
            for (closure) |cp| allocator.free(cp);
            allocator.free(closure);
        }

        const bins = store.Database.discoverBins(allocator, resolved.store_path) catch continue;
        defer {
            for (bins) |b| allocator.free(b);
            allocator.free(bins);
        }

        db.removeSymlinks(allocator, name) catch {};
        try db.addVersion(name, resolved.version, resolved.store_path, bins, closure, .{});
        try db.setActiveVersion(name, resolved.version);
        try db.installSymlinks(allocator, name);

        upgraded += 1;
    }

    if (ua.package != null and upgraded == 0) {
        ui.err("{s} is not installed", .{ua.package.?});
        return;
    }

    try db.save(state_path);

    if (upgraded > 0) {
        ui.ok("upgraded {d} package{s}", .{ upgraded, if (upgraded != 1) @as([]const u8, "s") else "" });
    }
}

fn selfUpdate(allocator: std.mem.Allocator) !void {
    const target = resolver.system;
    const url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/lilienblum/onyx/releases/latest/download/onyx-{s}",
        .{target},
    );
    defer allocator.free(url);

    ui.print("checking for updates...\n", .{});

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch {
        ui.print("could not check for onyx updates\n", .{});
        return;
    };

    if (result.status != .ok) {
        ui.print("no onyx update available\n", .{});
        return;
    }

    const binary = aw.written();
    if (binary.len == 0) return;

    const bin_dir = try xdg.binDir(allocator);
    defer allocator.free(bin_dir);

    const onyx_path = try std.fmt.allocPrint(allocator, "{s}/onyx", .{bin_dir});
    defer allocator.free(onyx_path);

    // Write to temp file then rename to avoid ETXTBSY on Linux
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/.onyx.tmp", .{bin_dir});
    defer allocator.free(tmp_path);

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch {
        ui.print("could not write onyx binary\n", .{});
        return;
    };
    file.writeAll(binary) catch {
        file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return;
    };
    file.chmod(0o755) catch {};
    file.close();

    std.fs.renameAbsolute(tmp_path, onyx_path) catch {
        ui.print("could not replace onyx binary\n", .{});
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return;
    };

    ui.print("onyx updated\n", .{});
}

fn cmdInit(allocator: std.mem.Allocator, exec: bool) !void {
    std.fs.accessAbsolute("/nix/store", .{}) catch {
        const is_macos = comptime builtin.os.tag == .macos;

        if (!exec) {
            if (is_macos) {
                ui.dim("# macOS setup (one-time):", .{});
                ui.print("grep -q '^nix$' /etc/synthetic.conf 2>/dev/null || sudo sh -c 'echo nix >> /etc/synthetic.conf'\n", .{});
                ui.print("sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t\n", .{});
                ui.print("mount | grep -q ' on /nix ' || sudo diskutil apfs addVolume disk3 APFS nix -mountpoint /nix\n", .{});
                ui.print("sudo chown $(whoami) /nix && mkdir -p /nix/store\n", .{});
                ui.dim("# Or just: onyx init --exec", .{});
            } else {
                ui.dim("# Run this to get started:", .{});
                ui.print("sudo mkdir -p /nix/store && sudo chown $(whoami) /nix/store\n", .{});
                ui.dim("# Or just: onyx init --exec", .{});
            }
            return;
        }

        // --exec: do it automatically
        // Resolve username before entering sudo, where $(whoami) would be root
        const user = std.posix.getenv("USER") orelse "root";

        if (is_macos) {
            ui.print("creating /nix volume...\n", .{});
            const script = try std.fmt.allocPrint(allocator,
                \\set -e
                \\grep -q '^nix$' /etc/synthetic.conf 2>/dev/null || echo 'nix' >> /etc/synthetic.conf
                \\/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t || true
                \\if ! mount | grep -q ' on /nix '; then
                \\  diskutil apfs addVolume disk3 APFS nix -mountpoint /nix
                \\  echo 'LABEL=nix /nix apfs rw' >> /etc/fstab
                \\fi
                \\chown {s} /nix
                \\mkdir -p /nix/store
            , .{user});
            defer allocator.free(script);
            var child = std.process.Child.init(
                &.{ "sudo", "sh", "-c", script },
                allocator,
            );
            const term = child.spawnAndWait() catch {
                ui.err("failed to run sudo", .{});
                return;
            };
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        ui.err("init failed (exit {d})", .{code});
                        return;
                    }
                },
                else => {
                    ui.err("init failed", .{});
                    return;
                },
            }
        } else {
            ui.print("creating /nix/store...\n", .{});
            const cmd = try std.fmt.allocPrint(allocator,
                "mkdir -p /nix/store && chown {s} /nix/store", .{user});
            defer allocator.free(cmd);
            var child = std.process.Child.init(
                &.{ "sudo", "sh", "-c", cmd },
                allocator,
            );
            const term = child.spawnAndWait() catch {
                ui.err("failed to run sudo", .{});
                return;
            };
            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        ui.err("init failed (exit {d})", .{code});
                        return;
                    }
                },
                else => {
                    ui.err("init failed", .{});
                    return;
                },
            }
        }

        ui.print("/nix/store created\n", .{});
        checkPath(allocator);
        return;
    };
    // Check writable
    const test_path = "/nix/store/.onyx-write-test";
    if (std.fs.createFileAbsolute(test_path, .{})) |f| {
        f.close();
        std.fs.deleteFileAbsolute(test_path) catch {};
        ui.print("already initialized\n", .{});
        checkPath(allocator);
    } else |_| {
        if (exec) {
            ui.print("fixing /nix/store permissions...\n", .{});
            var child = std.process.Child.init(
                &.{ "sudo", "sh", "-c", "chown -R \"$(whoami)\" /nix/store" },
                allocator,
            );
            const term = child.spawnAndWait() catch {
                ui.err("failed to run sudo", .{});
                return;
            };
            switch (term) {
                .Exited => |code| {
                    if (code == 0) {
                        ui.print("fixed\n", .{});
                    } else {
                        ui.err("failed (exit {d})", .{code});
                    }
                },
                else => ui.err("failed", .{}),
            }
        } else {
            ui.err("/nix/store exists but is not writable", .{});
            ui.print("sudo chown $(whoami) /nix/store\n", .{});
        }
    }
}

fn checkPath(allocator: std.mem.Allocator) void {
    const bin_dir = xdg.binDir(allocator) catch return;
    defer allocator.free(bin_dir);

    const path = std.posix.getenv("PATH") orelse return;

    // Check if bin_dir is in PATH
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, bin_dir)) return;
    }

    ui.warn("~/.local/bin is not in your PATH", .{});

    // Detect shell
    const shell = std.posix.getenv("SHELL") orelse "";
    if (std.mem.endsWith(u8, shell, "fish")) {
        ui.print("fish_add_path ~/.local/bin\n", .{});
    } else if (std.mem.endsWith(u8, shell, "zsh")) {
        ui.print("echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc\n", .{});
    } else {
        ui.print("echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.bashrc\n", .{});
    }
}

fn ensureNixStore() !void {
    std.fs.accessAbsolute("/nix/store", .{}) catch {
        ui.errCmd("not initialized — run ", "onyx init", .{});
        std.process.exit(1);
    };
    // Check writable
    const test_path = "/nix/store/.onyx-write-test";
    const f = std.fs.createFileAbsolute(test_path, .{}) catch {
        ui.errCmd("/nix/store is not writable — run ", "onyx init", .{});
        std.process.exit(1);
    };
    f.close();
    std.fs.deleteFileAbsolute(test_path) catch {};
}

fn cmdImplode(allocator: std.mem.Allocator, exec: bool) !void {
    const is_macos = comptime builtin.os.tag == .macos;

    if (!exec) {
        ui.dim("# Remove everything onyx created:", .{});
        if (is_macos) {
            ui.print("sudo diskutil apfs deleteVolume nix 2>/dev/null; true\n", .{});
            ui.print("sudo sed -i '' '/^nix$/d' /etc/synthetic.conf\n", .{});
            ui.print("sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t\n", .{});
        } else {
            ui.print("sudo rm -rf /nix/store\n", .{});
        }

        const home = std.posix.getenv("HOME") orelse "";
        ui.print("rm -rf {s}/.local/share/onyx {s}/.cache/onyx\n", .{ home, home });
        ui.dim("# Or just: onyx implode --exec", .{});
        return;
    }

    ui.print("removing onyx data...\n", .{});

    // Remove XDG dirs
    const data_dir = try xdg.dataDir(allocator);
    defer allocator.free(data_dir);
    std.fs.deleteTreeAbsolute(data_dir) catch {};

    const cache_dir = try xdg.cacheDir(allocator);
    defer allocator.free(cache_dir);
    std.fs.deleteTreeAbsolute(cache_dir) catch {};

    // Remove symlinks
    const bin_dir_path = try xdg.binDir(allocator);
    defer allocator.free(bin_dir_path);
    var bin_dir = std.fs.openDirAbsolute(bin_dir_path, .{}) catch null;
    if (bin_dir) |*bd| {
        // Remove the onyx binary itself
        bd.deleteFile("onyx") catch {};
        bd.close();
    }

    if (is_macos) {
        ui.print("removing /nix volume...\n", .{});
        var child = std.process.Child.init(
            &.{ "sudo", "sh", "-c", "diskutil apfs deleteVolume nix 2>/dev/null; sed -i '' '/^nix$/d' /etc/synthetic.conf; /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t" },
            allocator,
        );
        _ = child.spawnAndWait() catch {};
    } else {
        ui.print("removing /nix/store...\n", .{});
        var child = std.process.Child.init(
            &.{ "sudo", "rm", "-rf", "/nix/store" },
            allocator,
        );
        _ = child.spawnAndWait() catch {};
    }

    ui.print("onyx has been removed\n", .{});
}
