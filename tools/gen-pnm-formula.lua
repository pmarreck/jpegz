-- usage: gen.lua out W H channels maxval   (PGM/PPM/PAM, big-endian 16-bit above 255)
local out, W, H, C, M = arg[1], tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5])
local f = io.open(out, "wb")
if C == 1 then f:write(("P5\n%d %d\n%d\n"):format(W, H, M))
elseif C == 3 then f:write(("P6\n%d %d\n%d\n"):format(W, H, M))
else f:write(("P7\nWIDTH %d\nHEIGHT %d\nDEPTH %d\nMAXVAL %d\nTUPLTYPE %s\nENDHDR\n"):format(W, H, C, M, C == 4 and "RGB_ALPHA" or "GRAYSCALE_ALPHA")) end
local t = {}
for y = 0, H - 1 do for x = 0, W - 1 do for c = 0, C - 1 do
  local v = (37 * x + 101 * y + 53 * c + 7 * x * y) % (M + 1)
  if M > 255 then t[#t + 1] = string.char(math.floor(v / 256), v % 256) else t[#t + 1] = string.char(v) end
end end end
f:write(table.concat(t)); f:close()
