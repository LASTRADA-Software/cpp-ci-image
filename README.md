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

`publish.yml` runs in four stages:

1. **resolve** pins an immutable Ubuntu base-image digest and the exact `pace`
   `master` commit.
2. **build** builds the toolchain image with no seed, smoke-tests it, and pushes
   it as `<sha>-base`. Pull requests stop here.
3. **warm** runs the `pace` cache warm-up inside that base image, then pushes the
   resulting store as `ghcr.io/lastrada-software/cpp-ci-seed-pace:<sha>`.
4. **publish** bakes the seed into the final image, smoke-tests it, pushes
   `<sha>`, and moves `latest` to it on `master`.

If the warm-up fails, `publish` does not run, and `latest` stays on the previous
image with its previous seed. Consumers pick up each new image automatically, so
no changes are needed in their repositories.

## Seed warmer

The warmer builds each configured project's Linux presets once, with the compile
cache enabled, into a single-file `pace-kv` store. The store is baked into the
image under `/opt/pace/seed-cache/<project>/`, and each consumer copies only its
own project's directory.

**Status:** `pace` is the first project onboarded. The other three are not yet
onboarded. The blockers are tracked upstream:

- `Lightweight`: a test compile definition embeds an absolute build-tree path,
  so cache entries are not shared across checkouts. See
  [Lightweight#693](https://github.com/LASTRADA-Software/Lightweight/issues/693).
- `formula-cpp`: no cache integration. See
  [formula-cpp#36](https://github.com/LASTRADA-Software/formula-cpp/issues/36).
- `morph`: not yet measured.

### Manifest

[`warm-targets.json`](warm-targets.json) lists the presets to warm. It contains
`pace`'s nine Linux presets: gcc debug/release, clang debug/release, the two gate
presets, clang tracy, clang asan-ubsan, and clang tsan. Coverage presets are
excluded, because `pace-cc` binds coverage objects to the checkout root and they
never hit from another checkout. Windows presets are out of scope.

Presets listed in `test_presets` also run `ctest`, which for `pace` means
`gcc-release` and `clang-release`.

### What the warm-up does

[`scripts/warm-project.sh`](scripts/warm-project.sh) runs inside the base image:

- starts a local `pace-kv` on a single-file store, with an on-disk cap of
  `WARM_MAX_DISK` (default `4g`);
- for each preset, configures with `-DUSE_COMPILER_CACHE=ON` and builds it, and
  for test presets runs `ctest`;
- fails fast: a failing configure or build stops the warm-up, so no partial seed
  is produced;
- stops `pace-kv` with SIGTERM, so batched writes are flushed;
- reopens the store once to confirm that it opens.

The project checkout sits at the same path inside the container as on the host.

### Decisions

- **Gate on build, not on tests.** A build failure fails the warm-up. `ctest`
  failures are reported as warnings. The container runs as root with no services,
  so a few of `pace`'s environment-dependent tests fail (a permission check, and
  daemon start-up). The seed depends on what compiled, not on which tests passed.
  This departs from the earlier design, which gated on tests.
- **Sanitizer and debug presets build only**, without running their tests. That
  keeps the warm-up time down, and it does not change what the cache holds.
- **One store per project.** `pace-kv` cannot merge stores, so each project's
  store is written by one job.
- **Warm-up runs inside `publish.yml`,** not on a separate schedule. The seed is
  produced by the same `pace-cc`, `pace-kv`, and compilers it is baked beside.
  Cache keys include the compiler banner, and `pace-kv` refuses stores written by
  a different `pace` build.
- **Credentials.** The warm-up uses a local `pace-kv`, so it needs no
  `PACE_TOKEN`. `pace` is a public repository, so no checkout token is needed.
  The warm job has `contents: read` and `packages: write` only.
- **Runner.** The warm-up runs on `ubuntu-24.04` unless the `WARM_RUNNER`
  repository or organization variable selects another runner. A hosted runner
  may not have the time or disk for a full warm-up, so a larger runner may be
  needed.

### Measurements

These come from building on the same machine, against a local `pace-kv` store.

| Build | Compiles | Hits | Notes |
|---|---|---|---|
| `pace` `gcc-release`, cold, checkout A | 1,173 | 0 | 541 s build |
| `pace` `gcc-release`, checkout B, same store | 1,173 | 1,149 (98.0%) | 52 s build; 23 misses not investigated |
| `Lightweight` `gcc-release`, checkout B, same store | 243 | 104 (43%) | cause: test compile definition with absolute path |
| `Lightweight` after that define is made relative | 228 | 226 (99.1%) | counterfactual |
| `formula-cpp` `gcc-release`, checkout B, launchers set by hand | 415 | 339 (81.7%) | no cache integration; prefix-map rules not applied |

The store size for `pace` has not been measured yet, so the `4g` cap is a
placeholder. It should be set from the first real run.

### Open risks

- **The 23 `pace` misses are unexplained.** A verbose run would show which
  translation units miss.
- **Warm-up time on hosted runners is unknown.** Nine presets, two of them
  sanitizer builds, may exceed the time or disk of a standard runner.
- **Compiler banner drift.** If the `apt.llvm.org` clang 22 point release changes
  between daily builds, the cache is re-keyed every day. The base build pins the
  compiler version, so the banner should be compared between runs.
- **Seed size in every pull.** The seed is part of the image, so every job that
  pulls the image also pulls the seed.
