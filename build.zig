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

	// chardetz: pure-Zig charset DETECTOR (universalchardet/uchardet reimplementation).
	// Replaces the old C++ uchardet entirely — no C dependency, compiles to
	// wasm32-freestanding. Target-agnostic module, recompiled per consumer target.
	const chardetz_mod = b.dependency("chardetz", .{}).module("chardetz");

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
	core_mod.addImport("chardetz", chardetz_mod);

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
	ffi_mod.linkLibrary(sqlite3_lib);
	ffi_mod.linkLibrary(vec_static_lib);
	ffi_mod.addCMacro("SQLITE_VEC_STATIC", "1");
	lib.installHeader(b.path("ffi/docscan_core.h"), "docscan_core.h");
	b.installArtifact(lib);

	// C CLI executable — dogfoods the C FFI
	const exe_mod = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	exe_mod.addCSourceFiles(.{
		.files = &.{ "cli/main.c", "cli/embed_util.c" },
		.flags = &.{"-std=c11"},
	});
	exe_mod.addIncludePath(b.path("ffi"));

	const exe = b.addExecutable(.{
		.name = "docscan",
		.root_module = exe_mod,
	});
	exe_mod.linkLibrary(lib);
	exe_mod.linkLibrary(sqlite3_lib);
	exe_mod.linkLibrary(vec_static_lib);
	exe_mod.link_libc = true;
	// Link Windows socket library for networking code
	if (target.result.os.tag == .windows) {
		exe_mod.linkSystemLibrary("ws2_32", .{});
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
	test_mod.linkLibrary(sqlite3_lib);
	test_mod.linkLibrary(vec_static_lib);
	test_mod.addCMacro("SQLITE_VEC_STATIC", "1");
	test_mod.addImport("chardetz", chardetz_mod);

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
	ffi_test_mod.linkLibrary(sqlite3_lib);
	ffi_test_mod.linkLibrary(vec_static_lib);
	ffi_test_mod.addCMacro("SQLITE_VEC_STATIC", "1");

	const run_ffi_tests = b.addRunArtifact(ffi_tests);

	// "test" step runs both core and FFI tests
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	test_step.dependOn(&run_ffi_tests.step);

	// ── WASM parse-to-text slice (browser / incitez_web) ──
	// wasm32-freestanding, reactor module, ZERO imports. Comptime-excludes the
	// sqlite/search/embedding machinery; parses docx/pdf/md/txt and transcodes
	// charsets via pure-Zig chardetz + codepages (no C deps at all).
	const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
	const wasm_mod = b.createModule(.{
		.root_source_file = b.path("src/wasm_main.zig"),
		.target = wasm_target,
		.optimize = .ReleaseSmall,
	});
	wasm_mod.addImport("chardetz", chardetz_mod);
	const wasm_exe = b.addExecutable(.{
		.name = "docscan",
		.root_module = wasm_mod,
	});
	wasm_exe.entry = .disabled;
	wasm_exe.rdynamic = true;
	const wasm_install = b.addInstallArtifact(wasm_exe, .{});
	const wasm_step = b.step("wasm", "Build the wasm32-freestanding parse-to-text slice");
	wasm_step.dependOn(&wasm_install.step);
}
