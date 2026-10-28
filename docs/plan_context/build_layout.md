# Build layout conformance

Target: the fleet `cross-platform-project-build-arch` convention (platform names as of 2026-10-23). Read its `references/verification-and-migration.md` before implementing or claiming conformance.

## Gaps observed 2026-10-23

- Products land in a flat `zig-out/bin/` (native) and `zig-out/cross/<zig-triple>/` (cross). The convention wants `zig-out/<PF>/[<VARIANT>/]<profile>/` installation trees, e.g. `zig-out/linux-amd64/musl/ReleaseFast/bin/docscan`, with compiler caches kept separate.
- No `bin/<PF>/docscan` PATH-facing entrypoint (relative symlink into the selected product tree). Generic `bin/` is for portable scripts only.
- `./build` copies `result/bin/*` into `zig-out/bin/` (copying out of the Nix store). The convention keeps a retained `.nix-out/<PF>/<profile>` output link instead, and publishes only after a successful build while preserving the previous selection on failure.
- `./build` takes a positional `debug`; the convention wants explicit debug/test modes (`--debug`, `--test`) and `--all-plats`/`--all-platforms` for the five-target matrix.
- `build_all` uses an underscore and duplicates build logic. Fold it into `./build --all-plats` (update README and any callers together).
- No `./run` (ensure host build is current, then launch it).
- `./test` and the black-box suites hard-code `zig-out/bin/docscan`; they should resolve the exact product the build step just produced for the host PF.
- Translate PF at tool boundaries only: Zig triples (`x86_64-linux-musl`) and Nix systems (`x86_64-linux`) keep their own spellings.
- Supported matrix to declare: `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, `mswin-arm64`. Cross builds do not prove the binaries run; record untested platforms honestly.
