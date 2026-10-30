# C++ CI Image

The shared Linux toolchain image for `pace`, `morph`, `Lightweight`, and
`formula-cpp`.

It includes GCC 14, Clang 22, CMake, Ninja, `pace-cc`, and `pace-kv`. It is
published to GHCR by `.github/workflows/publish.yml`. Consumers use the moving
`latest` tag, which every successful `master` build advances.

Consumers reference `ghcr.io/lastrada-software/cpp-ci:latest` and never a
pinned digest. Read [the usage guide](docs/usage.md) before migrating a workflow.
In particular, every CMake configure must enable the cache with
`-DUSE_COMPILER_CACHE=ON` and set four `pace-cc` environment variables
(`PACE_ADDR`, `PACE_TOKEN`, `PACE_SOURCE_DIR`, `PACE_BINARY_DIR`). An
authenticated `pace-kv` alone does not distinguish cache readers from writers.

## Publishing

The workflow resolves an immutable Ubuntu base-image digest and the exact
`pace` `master` commit before building. It runs on pull requests (build and
smoke test only), on pushes to `master`, and once daily. Each `master` build is
pushed under its `<sha>` tag and then moves the `latest` tag to it. Consumers
use `latest`, so new images reach all CI runs automatically. The image labels
record both revisions.

Pull requests build and smoke-test the image without pushing it.

The current image is the toolchain foundation. The seed cache directory is
created empty. **The seed warmer is not yet implemented in this repository**, so
no consumer currently gets a seed. The design is below.

## Seed warmer design (proposed)

**Status:** proposal, reviewed, not implemented.

### Goal

Every CI job on every Linux runner in the organization starts with a compile
cache already populated for the presets it builds, so compile results are not
recomputed per job.

### Scope

The manifest is [`warm-targets.yml`](warm-targets.yml): 27 (project, preset)
pairs.

| Project | Presets |
|---|---|
| `pace` | 9: gcc debug/release/gate, clang debug/release/gate/tracy, clang asan-ubsan/tsan |
| `morph` | 8: gcc debug/release, clang debug/release/`linux-everything`, clang asan/tsan/ubsan |
| `Lightweight` | 6: gcc debug/release, clang debug/release, clang asan-ubsan/tsan |
| `formula-cpp` | 4: gcc release, clang debug/release/ubsan |

Excluded:

- **Windows presets** (`cl-*`, `clangcl-*`, `windows-everything`): the image is
  Linux-only.
- **Coverage presets:** `pace-cc` binds coverage-map objects to the checkout
  root, so they never hit from another checkout. `pace` and `morph` also refuse
  to configure coverage with a compiler launcher.

Each pair is its own cache namespace. Namespaces include the toolchain ABI,
architecture, project, and preset, as [the usage guide](docs/usage.md#seed-cache-lifecycle)
requires.

### Flow

The warm-up is a job inside `publish.yml`, not a separate workflow. The seed
must be produced by the same `pace-cc`, `pace-kv`, and compilers it is baked
beside: cache keys include the compiler banner, and `pace-kv` refuses stores
written by a different `pace` build. `publish.yml` re-resolves `pace` `master`
on every run, so a separately scheduled warmer could seed an image with a store
it cannot read.

1. **Build base.** Build `cpp-ci:<sha>-base` (toolchain only) and push it.
2. **Warm.** For each project, run one job inside the base image. The job
   checks out the project's default branch at a recorded commit and builds
   each of its presets with `-DUSE_COMPILER_CACHE=ON`, using a local
   `pace-kv` daemon as the only writer. Release presets also run `ctest`.
   Only `master` or the schedule writes; pull requests never do.
3. **Gate.** A project's store is kept only if every one of its presets builds
   and passes. The store is closed with a graceful stop, which flushes pending
   writes, before it is copied.
4. **Validate.** Each store is opened with the new `pace-kv` binary. A store
   that fails to open is dropped, and the image is built without a seed for
   that project.
5. **Bake and tag.** Copy the validated stores into the image under
   `/opt/pace/seed-cache/<project>/`, push the image as `cpp-ci:<sha>`, and move
   `latest` to it.
6. **Consume.** A job copies only its own project's store to a writable
   location before starting its local `pace-kv`, as
   [the usage guide](docs/usage.md#seed-cache-lifecycle) describes. A store that
   fails to open falls back to an empty one.

### Decisions

- **Store layout:** one store per project. `pace-kv` cannot merge stores and
  has no key enumeration or export, so each writer job owns one store. Stores
  are started with a file path, not a directory, so the shard count cannot
  change between writer and reader.
- **Coverage:** excluded (see Scope).
- **Sanitizers and debug presets:** warmed on every run. Sanitizer builds are
  the most expensive, so they are where a seed saves the most time.
- **Tests:** release presets run `ctest`. Sanitizer and debug presets only
  build, because running their tests roughly doubles job time without changing
  what the cache holds.
- **Size cap:** each project's warm-up runs `pace-kv` with a disk cap of
  2 GiB, and the cap is revisited after the first measured run. The cap evicts
  least-recently-used entries, and it counts compressed size. The store file
  keeps free pages above the cap, so the file size is what gets measured.
  Measured locally: `morph` `linux-everything` objects total 1.7 GiB, and
  `gcc-debug` 8.6 GiB, because debug builds carry full `-g` line tables.
  Debug presets dominate the size.
- **Credentials:** the warm-up uses a local `pace-kv`, so it needs no
  `PACE_TOKEN`. All four repositories are public, so no checkout token is
  needed. The warm job gets `GITHUB_TOKEN` with `contents: read` and
  `packages: write` only. A shared remote daemon, if one is added later, would
  get `PACE_KV_TOKEN` in a GitHub Environment limited to `master`, never on
  pull request events.

### Open risks

- **Path portability fails for Lightweight `gcc-release`.** Measured with the
  image's `pace-kv` and `pace-cc`, cold build then a build from a second
  checkout at a different path against the same store:

  | Build | Compiles | Hits | Store size |
  |---|---|---|---|
  | Cold, checkout A | 243 | 0 | 317 MB |
  | Warm, checkout B (different path) | 243 | 104 (43%) | 545 MB |

  **Cause:** `LightweightTest` defines
  `LIGHTWEIGHT_TEST_POST_MIGRATE_PLUGIN="$<TARGET_FILE:post_migrate_plugin>"`
  (`Lightweight/src/tests/CMakeLists.txt:211`). That value is an absolute
  build-tree path, so every test compile's arguments differ between checkouts.
  `pace-cc` does not relativize `-D` values: `PathPortionOf` in
  `src/apps/pace-cc/CacheKey.cpp` only tokenizes the flags in the path table,
  and `-D` is not one of them. The 138 test objects that carry the define are
  exactly the misses. The 12 test objects without it hit, and so did all
  library and tool objects.

  **Counterfactual:** with the define set to the relative name
  `post_migrate_plugin`, a build of `LightweightTest` in a second checkout hit
  226 of 228 compiles (99.1%). Before the change it hit 43%.

  Until this is fixed, a seed built in one path helps only jobs that build at
  the same path, so warm-up and consumer jobs must use the same checkout layout.
  No other local project (`pace`, `morph`) matched this pattern. `formula-cpp`
  has not been checked for it.

- **Compiler banner drift.** If the `apt.llvm.org` clang 22 point release changes
  between daily builds, the cache is re-keyed every day. The base build pins the
  compiler version, so this can be detected by comparing banners between runs.
- **Warm-up time and size are unmeasured.** Per-preset times and compressed
  store sizes on GitHub runners are unknown until the first run.
- **Unverified for two projects.** The coverage guard was verified only in
  `pace` and `morph`. `Lightweight` and `formula-cpp` need the same check before
  their presets are trusted.
- **Seed size in every pull.** All project stores are baked into one image, so
  every job pulls all of them. Splitting them into per-project images is an
  alternative if the pull cost is too high.
