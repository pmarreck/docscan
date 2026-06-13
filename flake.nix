{
	description = "docscan — document indexing and semantic search";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs {
					inherit system;
					overlays = [
						# unpaper 7.0.0 is broken in current nixos-unstable: its own
						# pytest suite fails AND the binary is SIGKILL'd at runtime, so
						# ocrmypdf's test suite (which exercises unpaper) fails too. This
						# blocked `nix develop` because ocrmypdf is in the default shell.
						#
						# docscan invokes ocrmypdf WITHOUT --clean/--deskew (see
						# cli/main.c auto-preprocess), so it never calls unpaper — the
						# broken unpaper is irrelevant to docscan's actual OCR path. We
						# skip unpaper's check (so it builds) and ocrmypdf's check (so its
						# unpaper-integration tests don't gate the package). Both build
						# fine; only their test suites fail on the upstream regression.
						(final: prev: {
							unpaper = prev.unpaper.overrideAttrs (_: {
								doCheck = false;
								doInstallCheck = false;
							});
							ocrmypdf = prev.ocrmypdf.overrideAttrs (_: {
								doCheck = false;
								doInstallCheck = false;
							});
						})
					];
				};

				sqlite-amalgamation = pkgs.fetchzip {
					url = "https://www.sqlite.org/2024/sqlite-amalgamation-3450300.zip";
					sha256 = "sha256-F50oTmmcPIl0AZJbsWAR3tbNAPV3pQLf+CNITzhmXfI=";
					stripRoot = true;
				};

				# Fixed-output derivation that pre-fetches all Zig deps declared in
				# build.zig.zon (URL deps for sqlite_vec, uchardetz). This is the
				# only step with network access; the consumer builds offline.
				# To recompute: set zigDepsHash = ""; nix build; copy printed hash.
				zigDepsHash = "sha256-6RDUzlXOKUNx302PH2PiYdgId1lMY2CxMctiXwYjVhw=";

				zigDeps = pkgs.stdenv.mkDerivation {
					pname = "docscan-zig-deps";
					version = "0.1.0";
					src = ./.;
					nativeBuildInputs = [ pkgs.zig_0_16 pkgs.git pkgs.cacert ];
					outputHashMode = "recursive";
					outputHashAlgo = "sha256";
					outputHash = zigDepsHash;
					buildPhase = ''
						export HOME=$TMPDIR
						export ZIG_GLOBAL_CACHE_DIR=$out
						export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
						export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
						zig build --fetch=all
					'';
					dontInstall = true;
					dontFixup = true;
				};

				buildDocscan = { optimize ? "ReleaseFast", extraFlags ? [] }:
					pkgs.stdenv.mkDerivation {
						pname = "docscan";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ pkgs.zig_0_16 ];

						dontConfigure = true;
						dontFixup = true;

						buildPhase = ''
							export HOME=$TMPDIR
							export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
							mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

							zig build \
								-Doptimize=${optimize} \
								--color off \
								${builtins.concatStringsSep " " extraFlags}
						'';

						installPhase = ''
							mkdir -p $out/bin
							cp zig-out/bin/docscan $out/bin/
						'';

						meta = with pkgs.lib; {
							description = "Document indexing and semantic search powered by SQLite + sqlite-vec";
							license = licenses.mit;
							platforms = platforms.unix;
							mainProgram = "docscan";
						};
					};
			in {
				packages.default = buildDocscan {};

				# wasm32-freestanding parse-to-text slice for incitez_web. `zig build
				# wasm` runs the full build() so the zig deps must be present, but the
				# slice links none of them (sqlite/uchardet excluded). Single output
				# file, mirroring incitez: $out/docscan.wasm.
				packages.wasm = pkgs.stdenv.mkDerivation {
					pname = "docscan-wasm";
					version = "0.1.0";
					src = ./.;

					nativeBuildInputs = [ pkgs.zig_0_16 ];

					dontConfigure = true;
					dontFixup = true;

					buildPhase = ''
						export HOME=$TMPDIR
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
						cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
						chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
						zig build wasm --color off
					'';

					installPhase = ''
						mkdir -p $out
						cp zig-out/bin/docscan.wasm $out/
					'';

					meta = with pkgs.lib; {
						description = "docscan parse-to-text WASM slice (wasm32-freestanding, zero imports)";
						license = licenses.mit;
					};
				};

				checks = {
					build = self.packages.${system}.default;

					test = pkgs.stdenv.mkDerivation {
						pname = "docscan-tests";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ pkgs.zig_0_16 ];

						dontConfigure = true;
						dontFixup = true;

						buildPhase = ''
							export HOME=$TMPDIR
							export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
							mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

							timeout 600 zig build test \
								--color off \
								|| { echo "Tests failed"; exit 1; }
						'';

						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
					};

					# Non-Zig consumer refuting the wasm artifact at its boundary: build
					# the slice, then instantiate + exercise it from Node with an EMPTY
					# import object (proving the zero-imports contract) and run the
					# embedded selftest + real extraction. The MFIC gate Garnix runs on push.
					wasm = pkgs.stdenv.mkDerivation {
						pname = "docscan-wasm-smoke";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ pkgs.zig_0_16 pkgs.nodejs ];

						dontConfigure = true;
						dontFixup = true;

						buildPhase = ''
							export HOME=$TMPDIR
							export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
							mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

							zig build wasm --color off
							node tests/wasm/smoke.mjs zig-out/bin/docscan.wasm
						'';

						installPhase = ''
							mkdir -p $out
							echo "wasm smoke passed" > $out/result
						'';
					};
				};

				devShells.default = pkgs.mkShell {
				packages = with pkgs; [
					zig_0_16
					jq
					hyperfine
					ocrmypdf
					vips          # image preprocessing (future: C API for in-process use)
					ghostscript   # PDF page rasterization for preprocessing
				];
				shellHook = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
						export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
					'';
				};

				# Minimal shell for CI: omits ocrmypdf (transitively pulls
				# unpaper, which has failing tests in current nixos-unstable
				# and blocks dev-shell evaluation). All zig build, cross-
				# compile, and CLI smoke tests work without ocrmypdf — only
				# runtime PDF OCR fallback needs it.
				devShells.ci = pkgs.mkShell {
					packages = with pkgs; [
						zig_0_16
						jq
						hyperfine
						vips
						ghostscript
					];
					shellHook = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
						export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
					'';
				};
			}
		);
}
