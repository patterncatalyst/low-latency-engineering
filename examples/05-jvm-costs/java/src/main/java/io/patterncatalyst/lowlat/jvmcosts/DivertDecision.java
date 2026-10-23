package io.patterncatalyst.lowlat.jvmcosts;

/**
 * What the tracker decides for one parcel: the lane and the belt position (encoder ticks) by which the
 * diverter must have acted. An {@code int} and a {@code long} behind a 12-byte header make a 24-byte
 * object: it costs 24 bytes of TLAB when it escapes and nothing when escape analysis removes it.
 */
public record DivertDecision(int lane, long deadlineTick) {
}
