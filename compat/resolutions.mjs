export const resolutions = {
  // typescript depends on flat-cache which will otherwise fail
  "flat-cache@<3.0.0": "flat-cache@3.x",
  // node-sass ages very badly
  "node-sass@<6.0.1": "node-sass@^6.0.1",
};
