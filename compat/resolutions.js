export const resolutions = {
  // typescript depends on flat-cache which will otherwise fail
  "flat-cache@<3.0.0": "flat-cache@3.x",
  // char-regex~1.0.2 has broken chmod entries
  "char-regex@<2.0.0": "char-regex@2.x",
};
