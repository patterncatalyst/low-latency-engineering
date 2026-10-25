package io.patterncatalyst.lowlat.ch11;

import io.patterncatalyst.lowlat.line.v1.DivertCommand;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;

/**
 * Adapted from example 10.
 *
 * The command path: divert commands leave the tracker on their own UDP socket, to the diverter's own
 * address. It shares nothing with the data path (the scan socket and the hand-off to the lookup tasks), so a
 * flood of scans cannot queue ahead of a command and a slow command listener cannot back up the scans.
 */
final class CommandChannel implements AutoCloseable {

    private final DatagramChannel channel;

    CommandChannel(InetSocketAddress diverter) throws IOException {
        this.channel = DatagramChannel.open(StandardProtocolFamily.INET);
        try {
            channel.connect(diverter);
        } catch (IOException | RuntimeException e) {
            channel.close();
            throw e;
        }
    }

    /** Sends one command as one datagram. Safe to call from many lookup tasks at once: each call has its own buffer. */
    void send(DivertCommand command) throws IOException {
        channel.write(ByteBuffer.wrap(command.toByteArray()));
    }

    @Override
    public void close() throws IOException {
        channel.close();
    }
}
