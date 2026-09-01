-- WezTerm uses a translucent background; keep blur subtle and avoid xray,
-- which would make tiled terminal windows excessively transparent.
hl.config({
  decoration = {
    blur = {
      enabled = true,
      size = 5,
      passes = 1,
      xray = false,
    },
  },
})
