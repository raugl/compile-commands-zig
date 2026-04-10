const std = @import("std");

const CompileCommands = struct {
    step: std.Build.Step,
    targets: []const *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
};

pub fn createStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    targets: []const *std.Build.Step.Compile,
) *std.Build.Step {
    const comp_cmds = b.allocator.create(CompileCommands) catch @panic("OOM");
    comp_cmds.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "CompileCommands",
            .owner = b,
            .makeFn = &make,
        }),
        .target = target,
        .targets = b.allocator.dupe(*std.Build.Step.Compile, targets) catch @panic("OOM"),
    };

    // make the generation of compile_commands.json depend on the generation of
    // all header files for libraries linked to the target, so that it can know
    // the absolute path to the generated directory
    for (targets) |target_| {
        for (target_.root_module.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |other_step| {
                    comp_cmds.step.dependOn(other_step.getEmittedIncludeTree().generated.file.step);
                },
                else => {},
            }
        }

        // paranoia: propagate all dependencies from targets to the step, but
        // not the building of the targets themselves. this is just here to
        // hopefully catch the possibility that there are some config headers
        // or something that need to be generated
        for (target_.step.dependencies.items) |dependency| {
            comp_cmds.step.dependOn(dependency);
        }
    }
    return &comp_cmds.step;
}

// TODO: make paths absolute by appending them to the `b`'s root
fn make(step: *std.Build.Step, make_options: std.Build.Step.MakeOptions) anyerror!void {
    _ = make_options;
    const gpa = step.owner.allocator;
    const b = step.owner;
    const io = step.owner.graph.io;
    const compile_commands: *CompileCommands = @fieldParentPtr("step", step);

    var out_file = try std.Io.Dir.cwd().createFile(io, "compile_commands.json", .{});
    defer out_file.close(io);

    var file_buffer: [1024]u8 = undefined;
    var file_writer = out_file.writer(io, &file_buffer);
    const writer = &file_writer.interface;

    var shared_flags: std.Io.Writer.Allocating = .init(gpa);
    defer shared_flags.deinit();

    var queue: std.Deque(*std.Build.Step.Compile) = .empty;
    defer queue.deinit(gpa);

    try queue.pushBackSlice(gpa, compile_commands.targets);
    try writer.writeAll("[");
    var is_first = true;

    while (queue.popFront()) |compile_step| {
        shared_flags.clearRetainingCapacity();
        try gatherSharedFlags(b, &shared_flags.writer, compile_step);

        for (compile_step.root_module.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => {
                    try queue.pushBack(gpa, link_object.other_step);
                },
                .c_source_file => |file| {
                    if (!is_first) try writer.writeByte(',') else is_first = false;
                    try writeCompileCommandEntry(
                        writer,
                        compile_commands.target,
                        shared_flags.written(),
                        file.flags,
                        file.file.getPath(b),
                    );
                },
                .c_source_files => |files| {
                    for (files.files) |file_path| {
                        if (!is_first) try writer.writeByte(',') else is_first = false;
                        try writeCompileCommandEntry(
                            writer,
                            compile_commands.target,
                            shared_flags.written(),
                            files.flags,
                            file_path,
                        );
                    }
                },
                else => continue,
            }
        }
    }
    try writer.writeAll("\n]");
    try file_writer.flush();
}

fn writeCompileCommandEntry(
    writer: *std.Io.Writer,
    target: std.Build.ResolvedTarget,
    shared_flags: []const u8,
    flags: []const []const u8,
    file_path: []const u8,
) !void {
    const path = std.Io.Dir.path;
    const ext = path.extension(file_path);
    const is_cpp = std.mem.eql(u8, ext, "cpp") or std.mem.eql(u8, ext, "cc");

    try writer.print(
        \\
        \\  {{
        \\    "directory": "{s}",
        \\    "command": "clang{s} -c {s}{s}
    , .{
        path.dirname(file_path).?, if (is_cpp) "++" else "",
        path.basename(file_path),  shared_flags,
    });
    for (flags) |flag| {
        const trimmed = std.mem.trimStart(u8, flag, &std.ascii.whitespace);
        if (!std.mem.startsWith(u8, trimmed, "-l")) {
            try writer.writeByte(' ');
            try writer.writeAll(flag);
        }
    }
    try writeClangTarget(writer, target);

    try writer.print(
        \\",
        \\    "file": "{s}"
        \\  }}
    , .{file_path});
}

fn writeClangTarget(writer: *std.Io.Writer, target: std.Build.ResolvedTarget) !void {
    const cpu = switch (target.result.cpu.arch) {
        .x86 => "i386",
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        .riscv64 => "riscv64",
        .riscv32 => "riscv32",
        .wasm32 => "wasm32",
        .wasm64 => "wasm64",

        else => @panic("unsupported arch"),
    };
    const os = switch (target.result.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "darwin",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .ios => "ios",
        .tvos => "tvos",
        .watchos => "watchos",
        .emscripten => "emscripten",
        .wasi => "wasi",

        else => @panic("unsupported os"),
    };
    const abi = switch (target.result.abi) {
        .gnu => "gnu",
        .gnueabi => "gnueabi",
        .gnueabihf => "gnueabihf",
        .musl => "musl",
        .musleabi => "musleabi",
        .musleabihf => "musleabihf",
        .msvc => "msvc",
        .none => "none",
        else => "unknown",
    };
    try writer.print(" -target {s}-unknown-{s}-{s}", .{ cpu, os, abi });
}

fn gatherSharedFlags(b: *std.Build, flags: *std.Io.Writer, step: *std.Build.Step.Compile) !void {
    for (step.root_module.include_dirs.items) |include_dir| {
        switch (include_dir) {
            .other_step => |other_step| {
                try flags.print(" -I{s}", .{other_step.getEmittedIncludeTree().getPath(b)});
                try gatherSharedFlags(b, flags, other_step);
            },
            .path => |path| {
                try flags.print(" -I{s}", .{path.getPath(b)});
            },
            .path_system => |path| {
                try flags.print(" -I{s}", .{path.getPath(b)});
            },
            // TODO: test these...
            .framework_path => |path| {
                std.log.warn("Found framework include path- compile commands generation for this is untested.", .{});
                try flags.print(" -I{s}", .{path.getPath(b)});
            },
            .framework_path_system => |path| {
                std.log.warn("Found system framework include path- compile commands generation for this is untested.", .{});
                try flags.print(" -I{s}", .{path.getPath(b)});
            },
            .path_after => |path| {
                std.log.warn("Found path_after- compile commands generation for this is untested.", .{});
                try flags.print(" -I{s}", .{path.getPath(b)});
            },
            // TODO: support this
            .config_header_step => {},
            // TODO: support this
            .embed_path => {},
        }
    }

    // NOTE: It's considered bad practice to include link flags
    // if (step.root_module.link_libc == true) try flags.writeAll(" -lc");
    // if (step.root_module.link_libcpp == true) try flags.writeAll(" -lc++");
    //
    // // catch all the system libraries being linked, make flags out of them
    // for (step.root_module.link_objects.items) |link_object| switch (link_object) {
    //     .system_lib => |lib| try flags.print(" -l{s}", .{lib.name}),
    //     else => continue,
    // };
}

