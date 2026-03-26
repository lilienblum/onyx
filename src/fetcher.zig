const std = @import("std");
const nar = @import("nar.zig");
const resolver = @import("resolver.zig");
const ui = @import("ui.zig");
pub const NarInfo = struct {
    store_path: []const u8,
    url: []const u8,
    compression: Compression,
    file_hash: []const u8,
    file_size: u64,
    nar_hash: []const u8,
    nar_size: u64,
    references: []const []const u8,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *NarInfo) void {
        self._arena.deinit();
    }
};

pub const Compression = enum { none, xz, zstd, bzip2 };

const cache_url = "https://cache.nixos.org";

/// Item queued for parallel NAR download.
const FetchItem = struct {
    store_path: []const u8,
    nar_url: []const u8,
    compression: Compression,
    file_hash: []const u8,
    file_size: u64,
};

/// Shared state for parallel download workers.
const DownloadContext = struct {
    allocator: std.mem.Allocator,
    items: []const FetchItem,
    progress: std.atomic.Value(usize),
    failures: std.atomic.Value(usize),
    total: usize,
};

/// Fetch a complete package closure into the nix store.
/// Returns the list of all store paths in the closure.
pub fn fetchClosure(
    allocator: std.mem.Allocator,
    store_path: []const u8,
) ![]const []const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Arena for closure data that persists through the function
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Phase 1: BFS to discover full closure and collect fetch items
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var closure: std.ArrayList([]const u8) = .{};
    errdefer {
        for (closure.items) |cp| allocator.free(cp);
        closure.deinit(allocator);
    }
    var to_fetch: std.ArrayList(FetchItem) = .{};
    defer to_fetch.deinit(allocator);

    // BFS queue
    var queue: std.ArrayList([]const u8) = .{};
    try queue.append(allocator, store_path);

    while (queue.items.len > 0) {
        // Process current queue, build next
        var next_queue: std.ArrayList([]const u8) = .{};

        for (queue.items) |path| {
            const basename = resolver.storePathBasename(path) catch continue;
            if (visited.contains(basename)) continue;
            try visited.put(try aa.dupe(u8, basename), {});

            // Record in closure (caller-owned copy)
            try closure.append(allocator, try allocator.dupe(u8, path));

            // Fetch narinfo to discover references
            const hash = resolver.storePathHash(path) catch continue;
            var narinfo = fetchNarInfo(allocator, &client, hash) catch |err| {
                ui.warn("narinfo fetch failed: {s}: {}", .{ basename, err });
                continue;
            };
            defer narinfo.deinit();

            // Check if NAR needs downloading
            std.fs.accessAbsolute(path, .{}) catch {
                try to_fetch.append(allocator, .{
                    .store_path = try aa.dupe(u8, narinfo.store_path),
                    .nar_url = try aa.dupe(u8, narinfo.url),
                    .compression = narinfo.compression,
                    .file_hash = try aa.dupe(u8, narinfo.file_hash),
                    .file_size = narinfo.file_size,
                });
            };

            // Enqueue references
            for (narinfo.references) |ref| {
                if (ref.len == 0) continue;
                if (visited.contains(ref)) continue;
                const ref_path = try std.fmt.allocPrint(aa, "/nix/store/{s}", .{ref});
                try next_queue.append(allocator, ref_path);
            }
        }

        queue.deinit(allocator);
        queue = next_queue;
    }
    queue.deinit(allocator);

    // Phase 2: Parallel NAR download + decompress + unpack
    if (to_fetch.items.len > 0) {
        // Progress is handled silently — main.zig prints the summary
        try parallelDownload(allocator, to_fetch.items);
    } else {
        ui.print("all packages already in store\n", .{});
    }

    return closure.toOwnedSlice(allocator);
}

fn parallelDownload(
    allocator: std.mem.Allocator,
    items: []const FetchItem,
) !void {
    if (items.len == 0) return;

    var ctx = DownloadContext{
        .allocator = allocator,
        .items = items,
        .progress = std.atomic.Value(usize).init(0),
        .failures = std.atomic.Value(usize).init(0),
        .total = items.len,
    };

    // Use thread pool for parallel downloads
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = @min(items.len, 8),
    });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};

    for (0..items.len) |i| {
        pool.spawnWg(&wg, downloadWorker, .{ &ctx, i });
    }

    pool.waitAndWork(&wg);

    const failed = ctx.failures.load(.acquire);
    if (failed > 0) {
        ui.warn("{d}/{d} downloads failed", .{ failed, items.len });
    }
}

fn downloadWorker(ctx: *DownloadContext, index: usize) void {
    const item = ctx.items[index];
    const basename = resolver.storePathBasename(item.store_path) catch "unknown";

    // Each worker gets its own HTTP client to avoid data races
    var client: std.http.Client = .{ .allocator = ctx.allocator };
    defer client.deinit();

    downloadAndUnpack(ctx.allocator, &client, item) catch |err| {
        // Only print first error per type
        const prev_fails = ctx.failures.fetchAdd(1, .monotonic);
        if (err == error.AccessDenied and prev_fails == 0) {
            ui.errCmd("/nix/store is not writable — run ", "onyx init", .{});
        } else if (err != error.AccessDenied) {
            ui.err("{s}: {}", .{ basename, err });
        }
        return;
    };

    _ = ctx.progress.fetchAdd(1, .monotonic);
}

fn downloadAndUnpack(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    item: FetchItem,
) !void {
    // Build full NAR URL
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_url, item.nar_url });
    defer allocator.free(url);

    // Download compressed NAR
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.HttpError;

    const compressed = try aw.toOwnedSlice();
    defer allocator.free(compressed);

    // Verify SHA256 hash of compressed data
    if (item.file_hash.len > 0) {
        try verifyHash(compressed, item.file_hash);
    }

    // Create the store directory
    const basename = try resolver.storePathBasename(item.store_path);
    const dest_path = try std.fmt.allocPrint(allocator, "/nix/store/{s}", .{basename});
    defer allocator.free(dest_path);

    std.fs.makeDirAbsolute(dest_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dest_dir = try std.fs.openDirAbsolute(dest_path, .{});
    defer dest_dir.close();

    // Decompress and unpack
    switch (item.compression) {
        .xz => {
            var fbs = std.io.fixedBufferStream(compressed);
            var decomp = try std.compress.xz.decompress(allocator, fbs.reader());
            defer decomp.deinit();
            try nar.unpack(decomp.reader(), dest_dir);
        },
        .none => {
            var fbs = std.io.fixedBufferStream(compressed);
            try nar.unpack(fbs.reader(), dest_dir);
        },
        .zstd => {
            const decompressed = try decompressZstd(allocator, compressed);
            defer allocator.free(decompressed);
            var fbs = std.io.fixedBufferStream(decompressed);
            try nar.unpack(fbs.reader(), dest_dir);
        },
        .bzip2 => return error.UnsupportedCompression,
    }

}

// --- Hash Verification ---

/// Verify compressed data against narinfo FileHash (format: "sha256:<nix-base32>")
fn verifyHash(data: []const u8, expected_hash: []const u8) !void {
    // Parse "sha256:xxxxx" format
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, expected_hash, prefix)) return; // unknown hash type, skip

    const nix32_hash = expected_hash[prefix.len..];

    // Compute SHA256 of data
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    const computed = hasher.finalResult();

    // Decode nix base32 hash and compare
    const decoded = nixBase32Decode(nix32_hash) catch return; // skip if decode fails
    if (decoded.len != computed.len) return error.HashMismatch;
    if (!std.mem.eql(u8, &decoded, &computed)) return error.HashMismatch;
}

// Nix base32 alphabet: 0123456789abcdfghijklmnpqrsvwxyz
const nix_base32_chars = "0123456789abcdfghijklmnpqrsvwxyz";

fn nixBase32Decode(encoded: []const u8) ![32]u8 {
    // Nix base32 encodes 32 bytes (256 bits) as 52 characters
    // Each character represents 5 bits, read in reverse byte order
    if (encoded.len != 52) return error.InvalidHash;

    var result: [32]u8 = undefined;
    @memset(&result, 0);

    var bit_pos: usize = 0;
    // Nix base32 reads characters from the END
    var i: usize = encoded.len;
    while (i > 0) {
        i -= 1;
        const c = encoded[i];
        const val: u8 = for (nix_base32_chars, 0..) |nc, idx| {
            if (nc == c) break @intCast(idx);
        } else return error.InvalidHash;

        // Place 5 bits at current position
        for (0..5) |bit| {
            if (bit_pos + bit >= 256) break;
            if (val & (@as(u8, 1) << @intCast(bit)) != 0) {
                const target_bit = bit_pos + bit;
                result[target_bit / 8] |= @as(u8, 1) << @intCast(target_bit % 8);
            }
        }
        bit_pos += 5;
    }

    return result;
}

// --- NAR Info ---

pub fn fetchNarInfo(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    hash: []const u8,
) !NarInfo {
    const url = try std.fmt.allocPrint(allocator, "{s}/{s}.narinfo", .{ cache_url, hash });
    defer allocator.free(url);

    const body = try resolver.httpGet(allocator, client, url);
    defer allocator.free(body);

    return parseNarInfo(allocator, body);
}

pub const fetchNarInfoFromText = parseNarInfo;

fn parseNarInfo(allocator: std.mem.Allocator, text: []const u8) !NarInfo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var store_path: []const u8 = "";
    var url: []const u8 = "";
    var compression: Compression = .xz;
    var file_hash: []const u8 = "";
    var file_size: u64 = 0;
    var nar_hash: []const u8 = "";
    var nar_size: u64 = 0;
    var references: std.ArrayList([]const u8) = .{};

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, ": ")) |colon| {
            const key = line[0..colon];
            const value = line[colon + 2 ..];

            if (std.mem.eql(u8, key, "StorePath")) {
                store_path = try aa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "URL")) {
                url = try aa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "Compression")) {
                if (std.mem.eql(u8, value, "xz")) {
                    compression = .xz;
                } else if (std.mem.eql(u8, value, "zstd")) {
                    compression = .zstd;
                } else if (std.mem.eql(u8, value, "bzip2")) {
                    compression = .bzip2;
                } else if (std.mem.eql(u8, value, "none")) {
                    compression = .none;
                }
            } else if (std.mem.eql(u8, key, "FileHash")) {
                file_hash = try aa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "FileSize")) {
                file_size = std.fmt.parseInt(u64, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "NarHash")) {
                nar_hash = try aa.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "NarSize")) {
                nar_size = std.fmt.parseInt(u64, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "References")) {
                var refs = std.mem.splitScalar(u8, value, ' ');
                while (refs.next()) |ref| {
                    if (ref.len > 0) {
                        try references.append(aa, try aa.dupe(u8, ref));
                    }
                }
            }
        }
    }

    return NarInfo{
        .store_path = store_path,
        .url = url,
        .compression = compression,
        .file_hash = file_hash,
        .file_size = file_size,
        .nar_hash = nar_hash,
        .nar_size = nar_size,
        .references = try references.toOwnedSlice(aa),
        ._arena = arena,
    };
}

// --- Zstd Decompression ---

fn decompressZstd(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var input_reader = std.Io.Reader.fixed(data);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var decomp: std.compress.zstd.Decompress = .init(&input_reader, &.{}, .{});
    _ = try decomp.reader.streamRemaining(&aw.writer);

    return aw.toOwnedSlice();
}
