package io.patterncatalyst.lowlat.offheap;

import com.google.protobuf.CodedOutputStream;
import io.patterncatalyst.lowlat.line.v1.DivertCommand;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.StandardProtocolFamily;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;

/**
 * The command path: divert commands leave the decide thread on their own UDP socket, to the
 * diverter's own address. It shares nothing with the data path (the UDP socket the parcels
 * arrive on, and the hand-off structure behind it), so a flood of scans cannot queue ahead of a
 * command and a slow command listener cannot back up the scans.
 */
final class CommandChannel implements AutoCloseable {

    private final DatagramChannel channel;
    private final ByteBuffer buffer = ByteBuffer.allocateDirect(128);

    CommandChannel(InetSocketAddress diverter) throws IOException {
        this.channel = DatagramChannel.open(StandardProtocolFamily.INET);
        try {
            channel.connect(diverter);
        } catch (IOException | RuntimeException e) {
            channel.close();
            throw e;
        }
    }

    /** Sends one command as one datagram. */
    void send(DivertCommand command) throws IOException {
        buffer.clear();
        CodedOutputStream out = CodedOutputStream.newInstance(buffer);
        command.writeTo(out);
        out.flush();
        buffer.flip();
        channel.write(buffer);
    }

    @Override
    public void close() throws IOException {
        channel.close();
    }
}
