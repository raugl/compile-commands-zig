# Generate compilation commands database from `build.zig`

The goal of this library is to add something akin to `CMAKE_EXPORT_COMPILE_COMMANDS` flag in cmake.
This is so you can use an [LSP](https://microsoft.github.io/language-server-protocol/) like
[clangd](https://clangd.llvm.org/) to develop your C or C++ projects that make use of the zig build
system and toolchain, as opposed to the traditional tools in that ecosystem.

Note that this library only supports zig >= 0.16.

Note that this library is nowhere near to production ready. Its a personal utility that I improve
whenever I run into a limitation. If you have any improvements, PRs are highly welcomed.

# Usage

First you need to fetch this as a dependency.

```
zig fetch --save git+https://github.com/raugl/compile-commands-zig
```

Then you need to import its module in your `build.zig` and register the generation step. You need to
supply it with a list of all the compilation targets that you want to be included in the compilation
commands database.

```zig
const zcc = @import("src/compile_commands.zig");

const cc_step = b.step("compile-commands", "Generate the compile_commands.json file");
const cc_gen_step = zcc.createStep(b, target, &.{exe, lib1, lib2});
cc_step.dependOn(cc_gen_step);
```

In this example you need to run `zig build compile-commands` to generate the file, but if you want
you can also make the default install step depend on the generation step instead, this will
regenerate the compilation commands database every time you build you project.

```zig
const cc_gen_step = zcc.createStep(b, target, &.{exe, lib1, lib2});
b.getInstallStep().dependOn(cc_gen_step);
```

Here is a complete example which also showcases the most common actions when setting up a build
script for a C project.

```zig
const std = @import("std");
const zcc = @import("src/compile_commands.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    exe.root_module.addCSourceFiles(.{
        .files = &.{ "src/foo.c", "src/bar.cpp" },
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{"-DSTB_IMAGE_IMPLEMENTATION=1"},
    });
    exe.root_module.addCMacro("PLATROFM_WIN32", "1");
    exe.root_module.addSystemIncludePath(b.path("foo/bar"));
    exe.root_module.linkSystemLibrary("GL", .{});

    const cc_step = b.step("compile-commands", "Generate the compile_commands.json file");
    cc_step.dependOn(zcc.createStep(b, target, &.{exe}));
}
```

The resulting `compile_commands.json` will look something like this
```json
[
  {
    "directory": "src",
    "command": "clang -c foo.c -I/home/user/project-dir/foo/bar -target x86_64-unknown-linux-gnu",
    "file": "src/foo.c"
  },
  {
    "directory": "src",
    "command": "clang -c bar.cpp -I/home/user/project-dir/foo/bar -target x86_64-unknown-linux-gnu",
    "file": "src/bar.cpp"
  },
  {
    "directory": "/home/user/project-dir/src",
    "command": "clang -c main.c -I/home/user/project-dir/foo/bar -DSTB_IMAGE_IMPLEMENTATION=1 -target x86_64-unknown-linux-gnu",
    "file": "/home/user/project-dir/src/main.c"
  }
]
```
