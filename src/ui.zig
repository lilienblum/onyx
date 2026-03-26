const std = @import("std");

// Theme — all colors in one place
const theme = struct {
    const esc = "\x1b[";
    const reset = esc ++ "0m";
    const bold = esc ++ "1m";
    const dim = esc ++ "2m";
    const italic = esc ++ "3m";
    // Semantic colors
    const accent = esc ++ "1;36m"; // bold cyan — brand, titles
    const ok = esc ++ "1;32m"; // bold green — success, steps
    const fail = esc ++ "1;31m"; // bold red — errors
    const attention = esc ++ "1;33m"; // bold yellow — warnings
    const value = esc ++ "36m"; // cyan — package names, values
    const version_c = esc ++ "32m"; // green — versions
    const muted = esc ++ "2m"; // dim — secondary info
    const cmd = esc ++ "37m"; // white — onyx prefix in help
    const arg = esc ++ "33m"; // yellow — args in help
};

var no_color: bool = false;

pub fn init() void {
    if (std.posix.getenv("NO_COLOR") != null) {
        no_color = true;
        return;
    }
    if (!std.posix.isatty(std.posix.STDOUT_FILENO)) {
        no_color = true;
    }
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    nosuspend fbs.writer().print(fmt, args) catch return;
    _ = std.posix.write(std.posix.STDOUT_FILENO, fbs.getWritten()) catch return;
}

// --- Output functions ---

pub fn print(comptime fmt: []const u8, args: anytype) void {
    out(fmt, args);
}

pub fn dim(comptime msg: []const u8, args: anytype) void {
    if (no_color) {
        std.debug.print(msg ++ "\n", args);
    } else {
        std.debug.print(theme.muted ++ msg ++ theme.reset ++ "\n", args);
    }
}

pub fn status(comptime msg: []const u8, args: anytype) void {
    std.debug.print(msg ++ "\n", args);
}

/// Success message with color on the value
pub fn ok(comptime msg: []const u8, args: anytype) void {
    if (no_color) {
        out(msg ++ "\n", args);
    } else {
        out(theme.ok ++ msg ++ theme.reset ++ "\n", args);
    }
}

pub fn detail(comptime msg: []const u8, args: anytype) void {
    if (no_color) {
        out("  " ++ msg ++ "\n", args);
    } else {
        out("  " ++ theme.muted ++ msg ++ theme.reset ++ "\n", args);
    }
}

pub fn warn(comptime msg: []const u8, args: anytype) void {
    if (no_color) {
        std.debug.print("warning: " ++ msg ++ "\n", args);
    } else {
        std.debug.print(theme.attention ++ "warning:" ++ theme.reset ++ " " ++ msg ++ "\n", args);
    }
}

pub fn err(comptime msg: []const u8, args: anytype) void {
    if (no_color) {
        std.debug.print("error: " ++ msg ++ "\n", args);
    } else {
        std.debug.print(theme.fail ++ "error:" ++ theme.reset ++ " " ++ msg ++ "\n", args);
    }
}

/// Error with a highlighted command: errCmd("run ", "onyx init")
pub fn errCmd(comptime msg: []const u8, comptime command: []const u8, args: anytype) void {
    if (no_color) {
        std.debug.print("error: " ++ msg ++ command ++ "\n", args);
    } else {
        std.debug.print(theme.fail ++ "error:" ++ theme.reset ++ " " ++ msg ++ theme.bold ++ command ++ theme.reset ++ "\n", args);
    }
}

pub fn pkg(name: []const u8, ver: []const u8) void {
    if (no_color) {
        out("{s}@{s}\n", .{ name, ver });
    } else {
        out(theme.value ++ "{s}" ++ theme.reset ++ "@" ++ theme.version_c ++ "{s}" ++ theme.reset ++ "\n", .{ name, ver });
    }
}

pub fn downloadProgress(done: usize, total: usize, name: []const u8) void {
    if (no_color) {
        std.debug.print("   [{d}/{d}] {s}\n", .{ done, total, name });
    } else {
        std.debug.print("   " ++ theme.muted ++ "[{d}/{d}]" ++ theme.reset ++ " {s}\n", .{ done, total, name });
    }
}

pub fn listPackage(name: []const u8, versions: anytype) void {
    if (no_color) {
        out("{s}\n", .{name});
        for (versions, 0..) |ver, i| {
            const prefix = if (i == versions.len - 1) "└─" else "├─";
            if (ver.active) {
                out("{s} {s} *\n", .{ prefix, ver.version });
            } else {
                out("{s} {s}\n", .{ prefix, ver.version });
            }
        }
    } else {
        out(theme.bold ++ theme.value ++ "{s}" ++ theme.reset ++ "\n", .{name});
        for (versions, 0..) |ver, i| {
            const prefix = if (i == versions.len - 1) "└─" else "├─";
            if (ver.active) {
                out(theme.muted ++ "{s}" ++ theme.reset ++ " {s}\n", .{ prefix, ver.version });
            } else {
                out(theme.muted ++ "{s} {s}" ++ theme.reset ++ "\n", .{ prefix, ver.version });
            }
        }
    }
}

pub fn printUsage() void {
    if (no_color) {
        out(usage_plain, .{});
    } else {
        out(usage_color, .{});
    }
}

const usage_plain =
    \\Onyx — tiny package manager backed by the Nix binary cache
    \\
    \\Usage: onyx <command> [...args]
    \\
    \\Commands:
    \\  install   postgresql@18            Install a package
    \\  uninstall postgresql               Uninstall a package
    \\  list                               Show installed packages
    \\  exec      node -b npx -- vitest    Run without installing
    \\  use       user:repo@2              Switch active version
    \\  upgrade   [package | --self]       Upgrade packages or onyx
    \\  gc                                 Free up disk space
    \\  init      [--exec]                 Get started
    \\  implode   [--exec]                 Remove everything
    \\
    \\Examples:
    \\  $ onyx install nodejs@22
    \\  $ onyx exec ruby -- script.rb
    \\  $ onyx x nodejs -b npm -- install
    \\  $ onyx use nodejs@20
    \\
    \\Learn more about Onyx: https://github.com/lilienblum/onyx
    \\
;

const R = theme.reset;
const A = theme.accent;
const C = theme.cmd;
const V = theme.value;
const Y = theme.arg;
const D = theme.muted;
const B = theme.bold;
const G = theme.version_c;

const usage_color =
    "Onyx — tiny package manager backed by the Nix binary cache\n" ++
    "\n" ++
    B ++ "Usage: onyx <command> [...args]" ++ R ++ "\n" ++
    "\n" ++
    B ++ "Commands:" ++ R ++ "\n" ++
    "  " ++ V ++ "install" ++ R ++ "   " ++ D ++ "postgresql@18" ++ R ++ "            Install a package\n" ++
    "  " ++ V ++ "uninstall" ++ R ++ " " ++ D ++ "postgresql" ++ R ++ "               Uninstall a package\n" ++
    "  " ++ V ++ "list" ++ R ++ "                               Show installed packages\n" ++
    "  " ++ V ++ "exec" ++ R ++ "      " ++ D ++ "node -b npx -- vitest" ++ R ++ "    Run without installing\n" ++
    "  " ++ V ++ "use" ++ R ++ "       " ++ D ++ "user:repo@2" ++ R ++ "              Switch active version\n" ++
    "  " ++ V ++ "upgrade" ++ R ++ "   " ++ D ++ "[package | --self]" ++ R ++ "       Upgrade packages or onyx\n" ++
    "  " ++ V ++ "gc" ++ R ++ "                                 Free up disk space\n" ++
    "  " ++ V ++ "init" ++ R ++ "      " ++ D ++ "[--exec]" ++ R ++ "                 Get started\n" ++
    "  " ++ V ++ "implode" ++ R ++ "   " ++ D ++ "[--exec]" ++ R ++ "                 Remove everything\n" ++
    "\n" ++
    B ++ "Examples:" ++ R ++ "\n" ++
    "  " ++ D ++ "$" ++ R ++ " onyx install nodejs@22\n" ++
    "  " ++ D ++ "$" ++ R ++ " onyx exec ruby -- script.rb\n" ++
    "  " ++ D ++ "$" ++ R ++ " onyx x nodejs -b npm -- install\n" ++
    "  " ++ D ++ "$" ++ R ++ " onyx use nodejs@20\n" ++
    "\n" ++
    "Learn more about Onyx: " ++ V ++ "https://github.com/lilienblum/onyx" ++ R ++ "\n";
