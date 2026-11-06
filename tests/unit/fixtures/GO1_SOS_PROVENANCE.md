# Go 1.0 SOS fixture provenance

`go1_sos_zero_se_16x16.jpg` (625 bytes, SHA-256
`e0263c904f104c73cd8d54473c1c01bfdf33c7f2a53996d8faace2578d049563`) is the
output of Go's `image/jpeg` writer as it stood at golang/go commit
`0157c72d133471631c13419f61117b75dcd7c255`. That commit is the parent of
`5f7bec69`, which fixed issue #3916, "image/jpeg: Invalid SOS parameters for
sequential JPEG".

## Why it exists

Before that fix, the writer ended every scan header with `Ss=0, Se=0, Ah/Al=0`
(`00 00 00`), where sequential DCT requires `00 3f 00`. The owner accepted
the issue and its fix commit as writer evidence on 2026-11-05. This fixture is
the exemplar for the resulting known-defect entry.

## How it was made

1. The package's non-test sources (`fdct.go`, `huffman.go`, `idct.go`,
   `reader.go`, `writer.go`) were taken unmodified from `src/pkg/image/jpeg`
   at that commit and compiled as a local module with nixpkgs Go 1.26.7.
2. That code is BSD-licensed and is not copied into this repository; only its
   output is.
3. The program below encoded a 16x16 RGBA gradient at quality 75:

```go
img := image.NewRGBA(image.Rect(0, 0, 16, 16))
for y := 0; y < 16; y++ {
	for x := 0; x < 16; x++ {
		img.Set(x, y, color.RGBA{uint8(x * 16), uint8(y * 16), uint8((x + y) * 8), 255})
	}
}
jpeg.Encode(f, img, &jpeg.Options{Quality: 75})
```

The pre-fix writer emits, in order: SOI, one DQT segment with both tables
(132 bytes), SOF0 for 16x16 4:2:0 YCbCr, one DHT segment with all four
standard tables (418 bytes), then the scan header
`ff da 00 0c 03 01 00 02 11 03 11 00 00 00`. It writes no APP0 segment. The
color conversion comes from the toolchain's current `image/color`, so the
sample values may differ from those a 2012 toolchain would produce. The header
bytes cannot differ, because the vendored writer writes them literally.

## Reader evidence

- **libjpeg-turbo 3.1.4 `djpeg`:** warns "Invalid SOS parameters for
  sequential JPEG" (the issue's title) and exits 2. Its pixels are identical to
  those of the same file with Se corrected to `3f`, which decodes with exit 0.
- **jpegz before the known-defect entry:** reports FAIL 64
  `sequential_scan_invalid`, "Se=0; required 63", at byte 587.
