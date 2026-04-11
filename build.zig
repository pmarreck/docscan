const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	// SQLite + sqlite-vec from dependency
	const sqlite_vec_dep = b.dependency("sqlite_vec", .{
		.target = target,
		.optimize = optimize,
	});
	const sqlite3_lib = sqlite_vec_dep.artifact("sqlite3");
	const vec_static_lib = sqlite_vec_dep.artifact("sqlite_vec0");

	// uchardet encoding detection (C++ with C API)
	// The uchardetz package exposes both static and shared "uchardet" artifacts,
	// so we can't use artifact() which panics on ambiguity. Find the static one.
	const uchardetz_dep = b.dependency("uchardetz", .{
		.target = target,
		.optimize = optimize,
	});
	const uchardet_lib = blk: {
		for (uchardetz_dep.builder.install_tls.step.dependencies.items) |dep_step| {
			const inst = dep_step.cast(std.Build.Step.InstallArtifact) orelse continue;
			if (std.mem.eql(u8, inst.artifact.name, "uchardet")) {
				if (inst.artifact.linkage) |lm| {
					if (lm != .static) continue;
				}
				break :blk inst.artifact;
			}
		}
		@panic("unable to find static uchardet artifact");
	};

	// Core module — root.zig re-exports all sub-modules
	const core_mod = b.createModule(.{
		.root_source_file = b.path("src/core/root.zig"),
		.target = target,
		.optimize = optimize,
	});
	// storage.zig needs sqlite3.h and sqlite-vec.h
	core_mod.addCMacro("SQLITE_VEC_STATIC", "1");
	core_mod.linkLibrary(sqlite3_lib);
	core_mod.linkLibrary(vec_static_lib);
	// encoding.zig uses uchardet for heuristic encoding detection
	core_mod.linkLibrary(uchardet_lib);

	// Static library for C FFI
	const ffi_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi/c_api.zig"),
		.target = target,
		.optimize = optimize,
	});
	ffi_mod.addImport("core", core_mod);

	const lib = b.addLibrary(.{
		.name = "docscan_core",
		.root_module = ffi_mod,
		.linkage = .static,
	});
	lib.linkLibrary(sqlite3_lib);
	lib.linkLibrary(vec_static_lib);
	lib.linkLibrary(uchardet_lib);
	ffi_mod.addCMacro("SQLITE_VEC_STATIC", "1");
	lib.installHeader(b.path("ffi/docscan_core.h"), "docscan_core.h");
	b.installArtifact(lib);

	// C CLI executable — dogfoods the C FFI
	const exe_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	exe_mod.addCSourceFile(.{
		.file = b.path("cli/main.c"),
		.flags = &.{"-std=c11"},
	});
	exe_mod.addIncludePath(b.path("ffi"));

	const exe = b.addExecutable(.{
		.name = "docscan",
		.root_module = exe_mod,
	});
	exe.linkLibrary(lib);
	exe.linkLibrary(sqlite3_lib);
	exe.linkLibrary(vec_static_lib);
	exe.linkLibrary(uchardet_lib);
	exe.linkLibC();
	// Link Windows socket library for networking code
	if (target.result.os.tag == .windows) {
		exe.linkSystemLibrary("ws2_32");
	}
	b.installArtifact(exe);

	// Unit tests — core modules (direct file imports for test discovery)
	const test_mod = b.createModule(.{
		.root_source_file = b.path("src/all_tests.zig"),
		.target = target,
		.optimize = .Debug,
	});

	const unit_tests = b.addTest(.{
		.root_module = test_mod,
	});
	unit_tests.linkLibrary(sqlite3_lib);
	unit_tests.linkLibrary(vec_static_lib);
	unit_tests.linkLibrary(uchardet_lib);
	test_mod.addCMacro("SQLITE_VEC_STATIC", "1");

	const run_unit_tests = b.addRunArtifact(unit_tests);

	// FFI tests — uses named "core" module import
	const ffi_test_mod = b.createModule(.{
		.root_source_file = b.path("src/ffi/c_api.zig"),
		.target = target,
		.optimize = .Debug,
	});
	ffi_test_mod.addImport("core", core_mod);

	const ffi_tests = b.addTest(.{
		.root_module = ffi_test_mod,
	});
	ffi_tests.linkLibrary(sqlite3_lib);
	ffi_tests.linkLibrary(vec_static_lib);
	ffi_tests.linkLibrary(uchardet_lib);
	ffi_test_mod.addCMacro("SQLITE_VEC_STATIC", "1");

	const run_ffi_tests = b.addRunArtifact(ffi_tests);

	// "test" step runs both core and FFI tests
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	test_step.dependOn(&run_ffi_tests.step);
}
