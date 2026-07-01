# Third-party notices (jpegz)

jpegz is MIT-licensed (see `LICENSE`). It links **no** third-party C libraries
in shipping builds — libjpeg-turbo, openjpeg, and charls are build-time test
oracles only, gated off by `-Dwith-libjpeg-oracle=false` / `-Dwith-charls=false`
and the vendored/ported JP2 path.

However, several pure-Zig kernels were **reimplemented from (ported from) the
source of the projects below**, kept byte-identical for oracle verification. Per
`LICENSING_NOTES.md`, that adaptation of algorithm shape requires the upstream
BSD attribution even though the C code is not linked. Those notices follow.

---

## libjpeg-turbo — BSD-3-Clause

Algorithm shapes ported into pure Zig (see `LICENSING_NOTES.md` "Provenance"):
- Integer "islow" inverse DCT — `src/decode/idct.zig` (from `jidctint.c` /
  `jidct12.c`: CONST_BITS, PASS1_BITS, fixed-point multiplier constants).
- YCbCr→RGB color conversion — `src/decode/color.zig` `ycbcrRowToRgb`
  (from `jdcolor.c`: SCALEBITS, FIX_* fixed-point scheme).
- Fancy chroma upsampling — `src/decode/color.zig` `fancyUpsample`
  (IJG fancy upsampling).
- CMYK / YCCK assembly — `src/decode/cmyk.zig`.

```
Copyright (C)2009-2024 D. R. Commander. All Rights Reserved.
Copyright (C)2015 Viktor Szathmáry. All Rights Reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of the libjpeg-turbo Project nor the names of its
  contributors may be used to endorse or promote products derived from this
  software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS",
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## OpenJPEG — BSD-2-Clause

The JPEG 2000 (T.800) path is provided by the sibling project `jp2z`, a
pure-Zig port of OpenJPEG. jpegz re-exports it as `jpegz.jpeg2000` and (today)
still delegates to the OpenJPEG C wrapper at runtime. OpenJPEG attribution:

```
The copyright in this software is being made available under the 2-clauses
BSD License, included below. This software may be subject to other third
party and contributor rights, including patent rights, and no such rights
are granted under this license.

Copyright (c) 2002-2014, Universite catholique de Louvain (UCL), Belgium
Copyright (c) 2002-2014, Professor Benoit Macq
Copyright (c) 2003-2014, Antonin Descampe
Copyright (c) 2003-2009, Francois-Olivier Devaux
Copyright (c) 2005, Herve Drolon, FreeImage team
Copyright (c) 2002-2003, Yannick Verschueren
Copyright (c) 2001-2003, David Janssens
Copyright (c) 2011-2012, Centre National d'Etudes Spatiales (CNES), France
Copyright (c) 2012, CS Systemes d'Information, France
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## charls — BSD-3-Clause

Build-time JPEG-LS (T.87) oracle only (`-Dwith-charls`), used to verify the
cleanroom JPEG-LS decoder. Not linked in shipping builds and not ported from
(the JPEG-LS decoder is cleanroom from T.87), so listed for completeness.
Copyright (c) Team CharLS. BSD-3-Clause.
