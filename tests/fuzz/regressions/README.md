# Saved fuzz crash inputs

Each file in `<harness>/` (for example `decode_fuzz/0x1234abcd.bin`) is the
exact input Zig's fuzzer recorded when a campaign crashed. Its name is the
campaign seed. `./fuzz --fuzz` writes it here on failure, using
`tools/fuzz-save-crash`.

The fuzzer is coverage-guided, so a seed repeats a run only while the code and
corpus are unchanged. A saved input does not depend on either: `build.zig`
lists this directory and adds every `.bin` file to that harness's corpus, so
`zig build fuzz` and every `./test` run replay it.

To keep a crash as a permanent regression, fix the bug and commit the file.
File names may use only `A-Z a-z 0-9 . _ -`.
