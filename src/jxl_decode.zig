//! JPEG XL pixel decode through libjxlz's libjxl-shaped decoder API.
//!
//! The first (coalesced) frame in stored orientation, as interleaved u8
//! samples at 8 bits or fewer and host-order u16 above. libjxl's API returns
//! integer samples scaled to the full range of the output type, so samples
//! at any other depth are scaled back to `0 .. 2^bits - 1`; for an integer
//! source this inverts the API's rounding exactly. tiffz uses it to check JPEG
//! XL strips and tiles in TIFF (Compression 50002) and DNG 1.7 (52546).

const std = @import("std");
const Allocator = std.mem.Allocator;
const libjxlz = @import("libjxlz");
const build_options = @import("jpegz_build_options");
const types = @import("core/types.zig");

pub const Error = error{
	/// Built without JPEG XL, alpha stored at a depth other than the color
	/// channels, or a color channel count other than 1 or 3.
	NotImplemented,
	/// Floating-point samples, or more than 16 bits per sample.
	UnsupportedPrecision,
	/// The codestream ended before the first frame was complete.
	TruncatedStream,
	/// libjxlz rejected the codestream.
	BackendError,
	OutOfMemory,
};

pub const Decoded = struct {
	/// Color channels, then alpha when `has_alpha`. With alpha the layout is
	/// `.components`; `source_color_space` still names the color model.
	image: types.Image,
	color_channels: u8,
	has_alpha: bool,
	/// Extra channels other than the first alpha (depth, spot colors, a
	/// second alpha). The decoder API cannot return them, so their samples
	/// are absent from `image`; a nonzero count means partial coverage.
	extra_channels_dropped: u32,

	pub fn deinit(self: *Decoded, allocator: Allocator) void {
		self.image.deinit(allocator);
		self.* = undefined;
	}
};

pub fn decode(allocator: Allocator, data: []const u8) Error!Decoded {
	if (!build_options.with_jxl) return error.NotImplemented;
	const api = libjxlz.ffi.decode;
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);

	const events: c_int = @intFromEnum(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
		@intFromEnum(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE);
	if (api.JxlDecoderSubscribeEvents(dec, events) != .JXL_DEC_SUCCESS) return error.BackendError;
	// A tile's declared extent is in stored geometry.
	if (api.JxlDecoderSetKeepOrientation(dec, 1) != .JXL_DEC_SUCCESS) return error.BackendError;
	if (api.JxlDecoderSetInput(dec, data.ptr, data.len) != .JXL_DEC_SUCCESS) return error.BackendError;
	api.JxlDecoderCloseInput(dec);

	var info: api.JxlBasicInfo = undefined;
	var format: api.JxlPixelFormat = undefined;
	var pixels: ?[]u8 = null;
	errdefer if (pixels) |p| allocator.free(p);
	var result: Decoded = undefined;

	while (true) {
		switch (api.JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {
				if (api.JxlDecoderGetBasicInfo(dec, &info) != .JXL_DEC_SUCCESS) return error.BackendError;
				if (info.exponent_bits_per_sample != 0 or info.bits_per_sample == 0 or info.bits_per_sample > 16)
					return error.UnsupportedPrecision;
				if (info.num_color_channels != 1 and info.num_color_channels != 3) return error.NotImplemented;
				const has_alpha = info.alpha_bits != 0;
				if (has_alpha and (info.alpha_bits != info.bits_per_sample or info.alpha_exponent_bits != 0))
					return error.NotImplemented;
				const color: u8 = @intCast(info.num_color_channels);
				const channels: u8 = color + @intFromBool(has_alpha);
				format = .{
					.num_channels = channels,
					.data_type = if (info.bits_per_sample > 8) .JXL_TYPE_UINT16 else .JXL_TYPE_UINT8,
					.endianness = .JXL_NATIVE_ENDIAN,
					.@"align" = 0,
				};
				result = .{
					.image = .{
						.pixels = &.{},
						.width = info.xsize,
						.height = info.ysize,
						.channels = channels,
						.bits_per_sample = @intCast(info.bits_per_sample),
						.source_color_space = if (color == 1) .grayscale else .rgb,
						.layout = if (has_alpha) .components else if (color == 1) .grayscale else .rgb,
					},
					.color_channels = color,
					.has_alpha = has_alpha,
					.extra_channels_dropped = info.num_extra_channels - @intFromBool(has_alpha),
				};
			},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				if (pixels != null) return error.BackendError;
				var size: usize = 0;
				if (api.JxlDecoderImageOutBufferSize(dec, &format, &size) != .JXL_DEC_SUCCESS) return error.BackendError;
				const expected = std.math.mul(usize, result.image.rowStride(), result.image.height) catch return error.OutOfMemory;
				if (size != expected) return error.BackendError;
				const buffer = try allocator.alloc(u8, size);
				pixels = buffer;
				if (api.JxlDecoderSetImageOutBuffer(dec, &format, buffer.ptr, buffer.len) != .JXL_DEC_SUCCESS)
					return error.BackendError;
			},
			// The first full image is the first coalesced frame.
			.JXL_DEC_FULL_IMAGE => break,
			.JXL_DEC_NEED_MORE_INPUT => return error.TruncatedStream,
			.JXL_DEC_SUCCESS, .JXL_DEC_ERROR => return error.BackendError,
			else => return error.BackendError,
		}
	}
	const buffer = pixels orelse return error.BackendError;
	result.image.pixels = buffer;
	pixels = null;
	scaleToDepth(&result.image);
	return result;
}

/// Undo the API's scaling to the output type's full range. For an integer
/// sample v at depth b, the API writes round(v * full / max); since
/// full / max >= 1, round(out * max / full) recovers v.
fn scaleToDepth(image: *types.Image) void {
	const bits = image.bits_per_sample;
	if (bits == 8 or bits == 16) return;
	const max: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
	if (bits > 8) {
		const full: u32 = 0xffff;
		for (image.pixelsU16()) |*s| s.* = @intCast((@as(u32, s.*) * max + full / 2) / full);
	} else {
		const full: u32 = 0xff;
		for (image.pixels) |*s| s.* = @intCast((@as(u32, s.*) * max + full / 2) / full);
	}
}
