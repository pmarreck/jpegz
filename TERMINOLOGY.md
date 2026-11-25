# jpegz terminology

- MCU: minimum coded unit. In an interleaved DCT scan it groups component
  blocks according to sampling factors; in a non-interleaved DCT scan it is
  one block. It is not a whole row of blocks.
- DCT: discrete cosine transform used by classic lossy JPEG.
- Spectral selection: the coefficient band carried by a progressive scan.
- Successive approximation: progressive refinement of coefficient precision.
- EBCOT: JPEG 2000's embedded block coding with optimized truncation.
- LOCO-I: the predictive coding algorithm used by JPEG-LS.
- Q-coder: the binary arithmetic coder used by arithmetic JPEG.
- Strict verdict: valid, known_defect, corrupt, unsupported or indeterminate. Unsupported
  features and inconclusive checks remain distinguishable from validity.
- Known defect: an identified encoder mistake reported by the codec, separate
  from its warning or failure treatment. Reader tolerance alone does not
  establish this classification. Either basis admits one: the same signature
  in at least 3 independent real-world files, or an upstream bug report or
  fix that documents it, reproduced as a synthetic exemplar (owner,
  2026-11-05 and 2026-11-25).
- Mutation rejection: the observed rate at which a validator rejects modified
  inputs. It is not corruption sensitivity unless the inputs' invalidity is
  independently established.
