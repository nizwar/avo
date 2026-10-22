package com.avodroid.bridge;

/** Host <-> guest protocol constants (proto/avo/v1/control.proto, docs/protocol.md). */
public final class Protocol {
    /** Matches PROTOCOL_VERSION_CURRENT and AvoProtocol.version on the host. */
    public static final int VERSION = 1;
    /** Oldest host protocol version this image accepts. */
    public static final int MIN_VERSION = 1;

    public static final int PORT_CONTROL = 6000;
    public static final int PORT_INPUT = 6001;

    /** Largest Control frame either side may send. */
    public static final int MAX_FRAME = 8 * 1024 * 1024;

    public static final int INPUT_VERSION = 1;
    public static final int INPUT_MAX_RECORD = 1024;

    private Protocol() {}
}
