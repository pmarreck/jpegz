# JP2 tile-origin adoption receipt

## Scope and status

This bounded check covers the JPEG 2000 Part 1 SIZ tile-origin constraint
through jpegz's Zig strict-validation facade. It does not establish full
specification coverage, a new mutation rejection rate, or JPEG XL behavior.
Published `f1a255a5b132680da1a2ac670e84a2bda7eec2ee` pinned jp2z
`91264891cdce2180dd65e211029098dac80ff067`, package
`jp2z-0.0.1-yLLHxdW_bgAiJm0mWuSYiGMXHrhnVOJ8iowwbhbrlg98`, with Nix dependency
hash `sha256-DCc/vzvvWPdBG5rp33IoEEIO/wLAnFbWtanyaV3radM=`. The worktree now
moves jp2z to published `434b9d53b60bf3ae69597926ef50ad083b23099b`, and the
fixed-output rebuild of that graph printed
`sha256-n86bl1BO1NcPy8YAV/sLAUTGcfndo4LfpxAbwVBivRY=`. That value is
`zigDepsHash`. A later package build produced
`/nix/store/psrn4iz2mc6h2gzchhiqdp9gqp61c5cc-jpegz-0.0.1` and did not report a
hash mismatch, so the closure hash is confirmed. The facade suite is part of
the Zig unit-test check, and that check passed on a rerun after the coverage
files were visible to Nix. The aarch64 Linux, macOS, and Windows link gates
also passed on a rerun after the disabled JXL options stand-in grew
`max_pixels`. A later full `./test` of that tree passed, including the
facade suite, the package build, all four foreign link gates, the validator
closure and the zero-C consumer.
The sampling packet stays held.

The red witness below used baseline jpegz
`33ea3946d06a66892ab4b8e080a6bcf968096889` and jp2z
`54917d611b087fea46df721bf66a66f2db84b9dd`. The draft pin examined before the
published repin was `54531e2650459a1037975db769b707c67e9d78b1`. Its invariant
fix is `3953e2a9d406e2c8abdeec518c61688c87e360b4`, which is an ancestor of
`91264891`. Draft revision `54531e26` and evidence revision
`338a43a58c3bee5d1e8e556cdc5241d9ef03b777` produced the same Zig package hash:

`jp2z-0.0.1-yLLHxXpkbgDaTSQFMehFO8Kw4HO_JSdn-Iz3gLe1glrQ`

That draft hash is historical. It is not the published pin's package hash.
`91264891` also contains a later MQ-coder change, so the hashes differ.

The proposed revision's `src/decode/codestream.zig` SHA-256 is
`01619d8542efaf61ce027a104c589287c138bb068e73f102a472b3e5175a1519`.
Its independently queried Mechatron Prime CI result was success in 134 seconds,
finishing at `2026-10-10T04:00:19Z`. This is upstream evidence, separate from
the pending jpegz gates.

## Normative control

[ITU-T T.800 (11/2015), section B.3, equations B-3 and B-4](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-T.800-201511-S%21%21PDF-E&lang=e&type=items)
requires the first tile to include the image origin on both axes:

`XTOsiz <= XOsiz < XTOsiz + XTsiz`

`YTOsiz <= YOsiz < YTOsiz + YTsiz`

The downloaded PDF SHA-256 is
`b1ca01eecd3fe13ad58ea2e253c19274eb091e4a3e240b489941c664e96869e0`.
This receipt uses the 2015 edition; it does not claim review of every later
edition or extension. The additions must use a widened type because legal
32-bit parameter values can produce a sum greater than `u32`.

## Persistent controls

`tests/unit/facade_validation.zig` contains the test
`JPEG 2000 facade identifies the SIZ tile-origin invariant at its marker`.
It classifies six SIZ-only streams: a just-inside boundary on both axes,
equality on each axis, both axes short of the origin, a larger covering tile,
and a legal coordinate sum exceeding `u32`. The malformed cases must carry
the existing FAIL 146, `jp2_invalid_siz`, from jp2z, at the raw codestream's
SIZ marker offset 2, with the B.3 detail preserved.

The SIZ-only streams assess this invariant. They are incomplete codestreams
and are not labeled valid whole images. A separate pristine full-stream
control, `tests/unit/fixtures/jp2_8x8_rgb.jp2`, must remain valid. Its SHA-256 is
`c0667a3c864a9ef4448ae5f4805bcc670f3cdc8f92b6da772b0371d9cac14379`.
No RNG or mutation seed is involved; all parameter changes are explicit in
the test. No private fixture or newly saved crash file is used.

The red witness against the old pin failed with 234/235 Zig tests passing.
The sole failure was this facade regression: the invariant-specific finding
was absent. The C FFI smoke check (71 assertions) and CLI suite (52 checks)
passed in the same run. This was a behavioral failure, not a build failure.
The ReleaseSafe facade test executable for that run had SHA-256
`b35bba1c029194ad56bf039ba7438bfb3924bf8ced2dafad8a7cda36480b8328`.
The regression source at that run had SHA-256
`f0c53386a4885c2e4bfc35ef26e351a294c2535bbeac7cf6ba8d221cc68a4623`.

```sh
build-budget --project jpegz -- nix develop -c zig build test --summary failures -j2
```

## Dependency-hash checkpoint

The worktree closure hash in `flake.nix` is
`sha256-n86bl1BO1NcPy8YAV/sLAUTGcfndo4LfpxAbwVBivRY=`, printed by a
fixed-output mismatch against the published hash and then accepted by a
package build. An earlier draft pin produced a different closure hash, and
that draft is not restored.

## Acceptance gates

Production builds retain Zig 0.16.0 and ReleaseFast. Runtime unit tests use
ReleaseSafe. Heavy commands use the shared build-budget wrapper without a
limit bypass. No unrelated dependency or compiler-series refresh is included.

`./test` includes native Linux tests/build, dependency compatibility, the
validation closure, the zero-C consumer, and foreign-target test-graph linking.
The three previously absent ARM64 cross-check attributes have missing-attribute
red witnesses and now evaluate successfully; realization is still pending.

| Target | Evidence required |
| --- | --- |
| x86_64-linux-musl | Native tests and optimized Nix build |
| aarch64-linux-musl | Compile/link; JXL and external oracles disabled |
| aarch64-macos | Compile/link; JXL and external oracles disabled |
| x86_64-windows-gnu | Compile/link; JXL and external oracles disabled |
| aarch64-windows-gnu | Compile/link; JXL and external oracles disabled |

Foreign-target link checks do not establish native runtime behavior. Native
Linux tests retain the full enabled feature set. The validation-only closure
must still exclude external JPEG-family decoders.

## Residuals

A named invariant can improve a finding even when another check already
rejects the input. This receipt makes no rejection-rate gain claim. The JP2
host-offset/exactness work, JPEG sampling panic, SOF1 table-id investigation,
and typed entropy-padding finding remain separate work items. Resource limits
and unsupported features must remain distinguishable from proven corruption.
