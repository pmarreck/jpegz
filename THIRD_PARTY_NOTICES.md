# Third-party notices (jpegz)

jpegz is MIT-licensed (see `LICENSE`). Third-party components fall into three
tiers; obligations differ per tier. Canonical provenance: `LICENSING_NOTES.md`.

**Accurate linkage summary (correcting an earlier over-claim):**
- **JPEG / JPEG-LS decode is pure Zig** with no *required* C runtime dependency:
  libjpeg-turbo is a droppable test oracle (`-Dwith-libjpeg-oracle=false`) and
  CharLS is a droppable JPEG-LS build-time oracle (`-Dwith-charls=false`).
- **JPEG 2000 (T.800) links a vendored openjpeg at runtime** (BSD-2) — this is a
  genuine runtime dependency today, until the `jp2z` cutover. So jpegz is NOT
  "zero C deps" in a default build; the JP2 codec is openjpeg.

---

## Tier 1 — PORTED into pure Zig (attribution OBLIGATORY)

Algorithm shapes reimplemented in Zig from **libjpeg-turbo** source, kept
byte-identical for oracle testing. These specific files are **inherited from the
original libjpeg (IJG)** and libjpeg-turbo's `LICENSE.md` assigns them the **IJG
License** (README.ijg), not the project-level BSD-3-Clause (BSD-3 governs only
the TurboJPEG API / build system). The IJG terms explicitly bind derivative
works: *"These conditions apply to any software derived from or based on the IJG
code, not just to the unmodified library."*

Ported files:
- `src/decode/idct.zig` — islow integer IDCT, from libjpeg-turbo `src/jidctint.c`
  (CONST_BITS, PASS1_BITS, fixed-point multiplier constants).
- `src/decode/color.zig` — `ycbcrRowToRgb` from `src/jdcolor.c` (SCALEBITS,
  FIX_* fixed-point); `fancyUpsample` from IJG fancy upsampling.
- `src/decode/cmyk.zig` — CMYK/YCCK assembly mirroring libjpeg-turbo.

**Copyright (verbatim from the ported file headers + README.ijg):**
```
jidctint.c / jdcolor.c were part of the Independent JPEG Group's software:
  Copyright (C) 1991-1998, Thomas G. Lane.
  Modification developed 2002-2018 by Guido Vollbeding.
libjpeg-turbo Modifications:
  Copyright (C) 2015, 2020, 2022, 2026, D. R. Commander.

IJG software is copyright (C) 1991-2020, Thomas G. Lane, Guido Vollbeding.
All Rights Reserved except as specified in the license.
```

**Required acknowledgment (IJG License clause 2):**
> This software is based in part on the work of the Independent JPEG Group.

**IJG License (README.ijg), permission and conditions (verbatim):**
```
Permission is hereby granted to use, copy, modify, and distribute this
software (or portions thereof) for any purpose, without fee, subject to these
conditions:
(1) If any part of the source code for this software is distributed, then this
README file must be included, with this copyright and no-warranty notice
unaltered; and any additions, deletions, or changes to the original files
must be clearly indicated in accompanying documentation.
(2) If only executable code is distributed, then the accompanying
documentation must state that "this software is based in part on the work of
the Independent JPEG Group".
(3) Permission for use of this software is granted only if the user accepts
full responsibility for any undesirable consequences; the authors accept
NO LIABILITY for damages of any kind.

These conditions apply to any software derived from or based on the IJG code,
not just to the unmodified library.

Permission is NOT granted for the use of any IJG author's name or company name
in advertising or publicity relating to this software or products derived from
it.
```
**Change indication (IJG clause 1):** the above files were *reimplemented in Zig*
(`src/decode/idct.zig`, `color.zig`, `cmyk.zig`); the fixed-point constants and
algorithm structure are preserved for byte-identical output, all surrounding
code is new. libjpeg-turbo's own `LICENSE.md` and `README.ijg` are the
authoritative texts.

---

## Tier 2 — RUNTIME dependency (attribution OBLIGATORY when distributed)

**OpenJPEG — BSD-2-Clause.** The JPEG 2000 (T.800) path (`jpegz.jpeg2000`) links
a vendored `libopenjp2` at runtime (`deps/openjpeg`, uclouvain 2.5.4). This is a
real runtime dependency in the shipped binary until the `jp2z` cutover.

```
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
AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED. [full BSD-2 disclaimer;
see deps/openjpeg upstream LICENSE.]
```

---

## Tier 3 — TEST-ORACLE ONLY (NO code adapted — courtesy)

No jpegz code was adapted from these; they are differential oracles only. The
production `decode()` dispatcher is cleanroom-only at runtime and never calls
them (it surfaces `error.NotImplemented` rather than falling back to a C lib).
Listed for completeness / distribution when linked as oracles.

- **CharLS — BSD-3-Clause.** Copyright (c) Team CharLS. JPEG-LS (T.87)
  differential oracle only (`-Dwith-charls`, droppable), reachable solely via
  `jpegz.internal.charlsDecode` — the production path never calls it. **The
  jpegz JPEG-LS decoder is cleanroom from ITU-T T.87 — no CharLS code was
  adapted**, so the cleanroom claim stands; this notice is a courtesy (and a
  distribution requirement only when CharLS is actually linked as an oracle).
- **libjpeg-turbo — as oracle.** When `-Dwith-libjpeg-oracle=true`, linked as a
  byte-perfect verification oracle (`jpegz.internal.wrapperDecode`); the runtime
  `decode()` path never calls it. Governed as above (IJG for inherited code,
  BSD-3 for TurboJPEG API). Droppable with `-Dwith-libjpeg-oracle=false`.
