{
	description = "docscan — document indexing and semantic search";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };

				sqlite-amalgamation = pkgs.fetchzip {
					url = "https://www.sqlite.org/2024/sqlite-amalgamation-3450300.zip";
					sha256 = "sha256-F50oTmmcPIl0AZJbsWAR3tbNAPV3pQLf+CNITzhmXfI=";
					stripRoot = true;
				};

				# Pre-fetch Zig build.zig.zon dependencies for sandboxed builds
				sqlite-vec-src = pkgs.fetchgit {
					url = "https://github.com/pmarreck/sqlite-vec.git";
					rev = "742ac1607d5490c71758c9fde80820387391910d";
					hash = "sha256-CFZAditwPGoWpAK7AG8BaxksfxjEzyGdlMvuZPsJ7CQ=";
				};

				uchardetz-src = pkgs.fetchgit {
					url = "https://github.com/pmarreck/uchardetz.git";
					rev = "c8e00e37f2b1d615e59df4158d1245d28c4d16b5";
					hash = "sha256-KON5YWftYlcqaou1PlHJYsM+k6OOKbHyOQ6AunN2Fns=";
				};

				# Create a directory matching Zig's package cache layout
				# so we can pass it via --system to avoid network fetches
				zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
					{
						name = "sqlite_vec-0.1.7-alpha.2-4Cdt0OvwBACYsEQvfmbSw0sUHuXhcwD5PgjGyslHXU2q";
						path = sqlite-vec-src;
					}
					{
						name = "uchardetz-0.0.6-koAyw7NFCwDRxaKK3hCecnFZVHhvUcs5HCfrJlrRmTzr";
						path = uchardetz-src;
					}
				];

				buildDocscan = { optimize ? "ReleaseFast", extraFlags ? [] }:
					pkgs.stdenv.mkDerivation {
						pname = "docscan";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = [ pkgs.zig_0_16 ];

						dontConfigure = true;
						dontFixup = true;

						buildPhase = ''
							export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
							mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

							zig build \
								--system ${zigPkgCache} \
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
							export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
							mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

							timeout 600 zig build test \
								--system ${zigPkgCache} \
								--color off \
								|| { echo "Tests failed"; exit 1; }
						'';

						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
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
			}
		);
}
