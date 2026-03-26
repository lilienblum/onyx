const std = @import("std");
const testing = std.testing;

const cli = @import("cli.zig");
const resolver = @import("resolver.zig");
const fetcher = @import("fetcher.zig");
const source = @import("source.zig");

// --- CLI parsing ---

test "parse install command" {
    const args = &[_][]const u8{ "onyx", "install", "nodejs@22" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .install => |ref| {
            try testing.expectEqualStrings("nodejs", ref.name);
            try testing.expectEqualStrings("22", ref.version.?);
            try testing.expect(ref.source == null);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse install with source" {
    const args = &[_][]const u8{ "onyx", "install", "dan:my-tool@1.0" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .install => |ref| {
            try testing.expectEqualStrings("dan:my-tool", ref.source.?);
            try testing.expectEqualStrings("dan:my-tool", ref.name);
            try testing.expectEqualStrings("1.0", ref.version.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse install without version" {
    const args = &[_][]const u8{ "onyx", "install", "go" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .install => |ref| {
            try testing.expectEqualStrings("go", ref.name);
            try testing.expect(ref.version == null);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse remove command" {
    const args = &[_][]const u8{ "onyx", "remove", "nodejs" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .uninstall => |ref| {
            try testing.expectEqualStrings("nodejs", ref.name);
            try testing.expect(ref.version == null);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse rm alias" {
    const args = &[_][]const u8{ "onyx", "rm", "nodejs@20" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .uninstall => |ref| {
            try testing.expectEqualStrings("nodejs", ref.name);
            try testing.expectEqualStrings("20", ref.version.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse list command" {
    const args = &[_][]const u8{ "onyx", "list" };
    const cmd = try cli.parse(args);
    try testing.expect(cmd == .list);
}

test "parse ls alias" {
    const args = &[_][]const u8{ "onyx", "ls" };
    const cmd = try cli.parse(args);
    try testing.expect(cmd == .list);
}

test "parse exec with bin flag" {
    const args = &[_][]const u8{ "onyx", "exec", "nodejs", "-b", "npm", "--", "install" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .exec => |ea| {
            try testing.expectEqualStrings("nodejs", ea.package.name);
            try testing.expectEqualStrings("npm", ea.bin.?);
            try testing.expect(ea.args.len == 1);
            try testing.expectEqualStrings("install", ea.args[0]);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse x alias for exec" {
    const args = &[_][]const u8{ "onyx", "x", "nodejs" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .exec => |ea| {
            try testing.expectEqualStrings("nodejs", ea.package.name);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse upgrade all" {
    const args = &[_][]const u8{ "onyx", "upgrade" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .upgrade => |ua| {
            try testing.expect(ua.package == null);
            try testing.expect(!ua.self_only);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse upgrade specific package" {
    const args = &[_][]const u8{ "onyx", "upgrade", "nodejs" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .upgrade => |ua| {
            try testing.expectEqualStrings("nodejs", ua.package.?);
            try testing.expect(!ua.self_only);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse upgrade --self" {
    const args = &[_][]const u8{ "onyx", "upgrade", "--self" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .upgrade => |ua| {
            try testing.expect(ua.self_only);
            try testing.expect(ua.package == null);
        },
        else => return error.UnexpectedCommand,
    }
}

test "parse init command" {
    const args = &[_][]const u8{ "onyx", "init" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .init_cmd => |exec| try testing.expect(!exec),
        else => return error.UnexpectedCommand,
    }
}

test "parse init --exec" {
    const args = &[_][]const u8{ "onyx", "init", "--exec" };
    const cmd = try cli.parse(args);
    switch (cmd) {
        .init_cmd => |exec| try testing.expect(exec),
        else => return error.UnexpectedCommand,
    }
}

test "parse help" {
    const args = &[_][]const u8{ "onyx", "--help" };
    const cmd = try cli.parse(args);
    try testing.expect(cmd == .help);
}

test "parse no args returns help" {
    const args = &[_][]const u8{"onyx"};
    const cmd = try cli.parse(args);
    try testing.expect(cmd == .help);
}

test "missing argument returns error" {
    const args = &[_][]const u8{ "onyx", "install" };
    try testing.expectError(error.MissingArgument, cli.parse(args));
}

// --- Package ref parsing ---

test "PackageRef parse simple name" {
    const ref = cli.PackageRef.parse("hello");
    try testing.expectEqualStrings("hello", ref.name);
    try testing.expect(ref.version == null);
    try testing.expect(ref.source == null);
}

test "PackageRef parse name@version" {
    const ref = cli.PackageRef.parse("nodejs@22.0.0");
    try testing.expectEqualStrings("nodejs", ref.name);
    try testing.expectEqualStrings("22.0.0", ref.version.?);
    try testing.expect(ref.source == null);
}


test "PackageRef parse user:repo" {
    const ref = cli.PackageRef.parse("dan:my-tool");
    try testing.expectEqualStrings("dan:my-tool", ref.source.?);
    try testing.expect(ref.version == null);
}

test "PackageRef parse user:repo@version" {
    const ref = cli.PackageRef.parse("dan:my-tool@2.0");
    try testing.expectEqualStrings("dan:my-tool", ref.source.?);
    try testing.expectEqualStrings("2.0", ref.version.?);
}

test "PackageRef parse domain" {
    const ref = cli.PackageRef.parse("tako.sh");
    try testing.expectEqualStrings("tako.sh", ref.source.?);
    try testing.expect(ref.version == null);
}

test "PackageRef parse domain@version" {
    const ref = cli.PackageRef.parse("tako.sh@1.0");
    try testing.expectEqualStrings("tako.sh", ref.source.?);
    try testing.expectEqualStrings("1.0", ref.version.?);
}

// --- Store path parsing ---

test "storePathHash extracts hash" {
    const hash = try resolver.storePathHash("/nix/store/abc123def-hello-2.12.3");
    try testing.expectEqualStrings("abc123def", hash);
}

test "storePathBasename extracts basename" {
    const base = try resolver.storePathBasename("/nix/store/abc123-hello-2.12.3");
    try testing.expectEqualStrings("abc123-hello-2.12.3", base);
}

test "storePathHash rejects invalid path" {
    try testing.expectError(error.InvalidStorePath, resolver.storePathHash("/usr/bin/hello"));
}

// --- Narinfo parsing ---

test "parse narinfo" {
    const narinfo_text =
        \\StorePath: /nix/store/abc123-hello-2.12.3
        \\URL: nar/xyz.nar.xz
        \\Compression: xz
        \\FileHash: sha256:aabbccdd
        \\FileSize: 12345
        \\NarHash: sha256:eeff0011
        \\NarSize: 67890
        \\References: dep1-foo-1.0 dep2-bar-2.0
        \\Sig: cache.nixos.org-1:fakesig==
    ;

    var info = try fetcher.fetchNarInfoFromText(std.testing.allocator, narinfo_text);
    defer info.deinit();

    try testing.expectEqualStrings("/nix/store/abc123-hello-2.12.3", info.store_path);
    try testing.expectEqualStrings("nar/xyz.nar.xz", info.url);
    try testing.expect(info.compression == .xz);
    try testing.expectEqualStrings("sha256:aabbccdd", info.file_hash);
    try testing.expect(info.file_size == 12345);
    try testing.expectEqualStrings("sha256:eeff0011", info.nar_hash);
    try testing.expect(info.nar_size == 67890);
    try testing.expect(info.references.len == 2);
    try testing.expectEqualStrings("dep1-foo-1.0", info.references[0]);
    try testing.expectEqualStrings("dep2-bar-2.0", info.references[1]);
}

// --- NAR unpacking ---

test "unpack simple NAR with single file" {
    // A minimal NAR containing a single regular file with content "hello"
    // nix-archive-1 ( type regular contents <5 bytes: hello> )
    const nar_data = [_]u8{
        // "nix-archive-1" (len=13)
        0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        'n', 'i', 'x', '-', 'a', 'r', 'c', 'h', 'i', 'v', 'e', '-', '1', 0, 0, 0,
        // "(" (len=1)
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        '(', 0, 0, 0, 0, 0, 0, 0,
        // "type" (len=4)
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        't', 'y', 'p', 'e', 0, 0, 0, 0,
        // "regular" (len=7)
        0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        'r', 'e', 'g', 'u', 'l', 'a', 'r', 0,
        // "contents" (len=8)
        0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        'c', 'o', 'n', 't', 'e', 'n', 't', 's',
        // file data: "hello" (len=5)
        0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        'h', 'e', 'l', 'l', 'o', 0, 0, 0,
        // ")" (len=1)
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ')', 0, 0, 0, 0, 0, 0, 0,
    };

    const nar_mod = @import("nar.zig");

    // Create temp dir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fbs = std.io.fixedBufferStream(&nar_data);
    try nar_mod.unpack(fbs.reader(), tmp.dir);

    // The NAR root is a regular file, but our unpacker handles root files
    // by not creating them (entry_name is null for root). This test verifies
    // the parser doesn't crash on a valid NAR.
}

// --- System detection ---

test "system string is valid" {
    const sys = resolver.system;
    try testing.expect(sys.len > 0);
    // Should be one of: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin
    try testing.expect(
        std.mem.eql(u8, sys, "x86_64-linux") or
            std.mem.eql(u8, sys, "aarch64-linux") or
            std.mem.eql(u8, sys, "x86_64-darwin") or
            std.mem.eql(u8, sys, "aarch64-darwin"),
    );
}

// --- onyx.toml parsing ---

test "parse onyx.toml basic" {
    const toml =
        \\[package]
        \\name = "my-tool"
        \\
        \\["1.0.0".
    ++ source.platform ++
        \\]
        \\url = "https://example.com/my-tool.tar.gz"
        \\sha256 = "abc123"
        \\bin = ["my-tool"]
    ;

    var pkg = try source.parseOnyxToml(testing.allocator, toml, null);
    defer pkg.deinit();

    try testing.expectEqualStrings("my-tool", pkg.name);
    try testing.expectEqualStrings("1.0.0", pkg.version);
    try testing.expectEqualStrings("https://example.com/my-tool.tar.gz", pkg.url);
    try testing.expectEqualStrings("abc123", pkg.sha256);
    try testing.expect(pkg.bins.len == 1);
    try testing.expectEqualStrings("my-tool", pkg.bins[0]);
}

test "parse onyx.toml version match" {
    const toml =
        \\[package]
        \\name = "tool"
        \\
        \\["1.0.0".
    ++ source.platform ++
        \\]
        \\url = "https://example.com/v1.tar.gz"
        \\sha256 = "aaa"
        \\bin = ["tool"]
        \\
        \\["2.0.0".
    ++ source.platform ++
        \\]
        \\url = "https://example.com/v2.tar.gz"
        \\sha256 = "bbb"
        \\bin = ["tool"]
    ;

    var pkg = try source.parseOnyxToml(testing.allocator, toml, "2");
    defer pkg.deinit();

    try testing.expectEqualStrings("2.0.0", pkg.version);
    try testing.expectEqualStrings("https://example.com/v2.tar.gz", pkg.url);
}

test "parse onyx.toml no matching platform" {
    const toml =
        \\[package]
        \\name = "tool"
        \\
        \\["1.0.0".fake-platform]
        \\url = "https://example.com/tool.tar.gz"
        \\sha256 = "abc"
        \\bin = ["tool"]
    ;

    try testing.expectError(error.NoBinaryForPlatform, source.parseOnyxToml(testing.allocator, toml, null));
}

test "parse onyx.toml multiple bins" {
    const toml =
        \\[package]
        \\name = "node"
        \\
        \\["22.0.0".
    ++ source.platform ++
        \\]
        \\url = "https://example.com/node.tar.gz"
        \\sha256 = "abc"
        \\bin = ["node", "npm", "npx"]
    ;

    var pkg = try source.parseOnyxToml(testing.allocator, toml, null);
    defer pkg.deinit();

    try testing.expect(pkg.bins.len == 3);
    try testing.expectEqualStrings("node", pkg.bins[0]);
    try testing.expectEqualStrings("npm", pkg.bins[1]);
    try testing.expectEqualStrings("npx", pkg.bins[2]);
}

// --- Meta tag parsing ---

test "parse onyx meta tag" {
    const html =
        \\<html><head>
        \\<meta name="onyx" content="git https://github.com/user/repo">
        \\</head></html>
    ;

    const result = try source.parseOnyxMeta(html);
    try testing.expectEqualStrings("https://github.com/user/repo", result.?);
}

test "parse onyx meta tag no git prefix" {
    const html =
        \\<meta name="onyx" content="https://github.com/user/repo">
    ;

    const result = try source.parseOnyxMeta(html);
    try testing.expectEqualStrings("https://github.com/user/repo", result.?);
}

test "parse onyx meta tag missing" {
    const html =
        \\<html><head><title>Hello</title></head></html>
    ;

    const result = try source.parseOnyxMeta(html);
    try testing.expect(result == null);
}

// --- Platform detection ---

test "platform string is valid" {
    const p = source.platform;
    try testing.expect(
        std.mem.eql(u8, p, "macos") or
            std.mem.eql(u8, p, "linux-x64") or
            std.mem.eql(u8, p, "linux-arm64"),
    );
}
