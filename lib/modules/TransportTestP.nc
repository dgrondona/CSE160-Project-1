#include "../../includes/socket.h"
#include "../../includes/channels.h"

module TransportTestP{
   provides interface TransportTest;

   uses interface Transport;
   uses interface Timer<TMilli> as appTimer;
}

implementation{
    enum {
        MAX_SESSIONS = 4,
        MAX_LISTENERS = 2,
        APP_PERIOD = 250,
        PRODUCE_CHUNK = 32,
        CONSUME_CHUNK = 24,
        NUMBERS_PER_LINE = 12
    };

    typedef struct session {
        bool inUse;
        bool isServer;
        socket_t fd;
        uint16_t dest;
        uint8_t srcPort;
        uint8_t destPort;

        // Client side. accepted is how much of the stream Transport has taken, so it is also the next byte to produce.
        uint16_t total;
        uint16_t accepted;
        bool connected;
        bool closeRequested;
        bool closeCalled;

        // Server side. consumed is how much we have read, so it is also the next byte we expect.
        uint16_t consumed;
        uint16_t mismatches;
        bool eof;
    }session;

    session sessions[MAX_SESSIONS];
    socket_t listeners[MAX_LISTENERS];
    uint8_t listenerCount = 0;

    session* findByFd(socket_t fd) {
        uint8_t i;
        for (i = 0; i < MAX_SESSIONS; i++) {
            if (sessions[i].inUse && sessions[i].fd == fd) {
                return &sessions[i];
            }
        }
        return NULL;
    }

    session* allocate() {
        uint8_t i;
        for (i = 0; i < MAX_SESSIONS; i++) {
            if (!sessions[i].inUse) {
                memset(&sessions[i], 0, sizeof(session));
                sessions[i].inUse = TRUE;
                return &sessions[i];
            }
        }
        return NULL;
    }

    void startTimer() {
        if (!call appTimer.isRunning()) {
            call appTimer.startPeriodic(APP_PERIOD);
        }
    }

    command void TransportTest.startServer(uint8_t port){
        socket_t fd;
        socket_addr_t addr;

        if (listenerCount >= MAX_LISTENERS) {
            dbg(TGEN_CHANNEL, "server failed! too many listeners. port: %d\n", port);
            return;
        }

        fd = call Transport.socket();
        addr.port = port;
        addr.addr = TOS_NODE_ID;

        if (fd == NULL_SOCKET || call Transport.bind(fd, &addr) != SUCCESS || call Transport.listen(fd) != SUCCESS) {
            dbg(TGEN_CHANNEL, "server failed! port: %d\n", port);
            return;
        }

        listeners[listenerCount] = fd;
        listenerCount++;
        dbg(TGEN_CHANNEL, "server listening! port: %d, fd: %d\n", port, fd);
        startTimer();
    }

    command void TransportTest.startClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transferBytes){
        session* s = allocate();
        socket_addr_t addr;

        if (s == NULL) {
            dbg(TGEN_CHANNEL, "client failed! no free session. dest: %d:%d\n", dest, destPort);
            return;
        }

        s->fd = call Transport.socket();
        addr.port = srcPort;
        addr.addr = TOS_NODE_ID;

        if (s->fd == NULL_SOCKET || call Transport.bind(s->fd, &addr) != SUCCESS) {
            dbg(TGEN_CHANNEL, "client failed! couldn't get a bound socket. src port: %d\n", srcPort);
            s->inUse = FALSE;
            return;
        }

        s->dest = dest;
        s->srcPort = srcPort;
        s->destPort = destPort;
        s->total = transferBytes;

        addr.port = destPort;
        addr.addr = dest;
        if (call Transport.connect(s->fd, &addr) != SUCCESS) {
            dbg(TGEN_CHANNEL, "client failed! connect refused. conn: %d:%d->%d:%d\n", TOS_NODE_ID, srcPort, dest, destPort);
            s->inUse = FALSE;
            return;
        }

        dbg(TGEN_CHANNEL, "client connecting! conn: %d:%d->%d:%d, fd: %d, bytes: %d\n", TOS_NODE_ID, srcPort, dest, destPort, s->fd, transferBytes);
        startTimer();
    }

    command void TransportTest.closeClient(uint16_t dest, uint8_t srcPort, uint8_t destPort){
        uint8_t i;
        for (i = 0; i < MAX_SESSIONS; i++) {
            if (sessions[i].inUse && !sessions[i].isServer && sessions[i].dest == dest && sessions[i].srcPort == srcPort && sessions[i].destPort == destPort) {
                // The close itself waits in appTimer until every byte is accepted.
                sessions[i].closeRequested = TRUE;
                dbg(TGEN_CHANNEL, "client close requested! conn: %d:%d->%d:%d\n", TOS_NODE_ID, srcPort, dest, destPort);
                return;
            }
        }
        dbg(TGEN_CHANNEL, "client close failed! no such client. conn: %d:%d->%d:%d\n", TOS_NODE_ID, srcPort, dest, destPort);
    }

    // Byte k of the stream is k % 256, so the server can check what it reads without any shared state.
    void produce(session* s) {
        uint8_t buf[PRODUCE_CHUNK];
        uint16_t len = s->total - s->accepted;
        uint16_t n;
        uint16_t i;

        if (len > PRODUCE_CHUNK) {
            len = PRODUCE_CHUNK;
        }
        for (i = 0; i < len; i++) {
            buf[i] = (s->accepted + i) % 256;
        }

        n = call Transport.write(s->fd, buf, len);
        if (n > 0) {
            s->accepted += n;
            dbg(TGEN_CHANNEL, "client accepted! conn: %d:%d->%d:%d, accepted: %d, total: %d\n", TOS_NODE_ID, s->srcPort, s->dest, s->destPort, s->accepted, s->total);
            if (s->accepted == s->total) {
                dbg(TGEN_CHANNEL, "client done writing! conn: %d:%d->%d:%d\n", TOS_NODE_ID, s->srcPort, s->dest, s->destPort);
            }
        }
    }

    void consume(session* s) {
        uint8_t buf[CONSUME_CHUNK];
        char line[128];
        uint16_t n = call Transport.read(s->fd, buf, CONSUME_CHUNK);
        uint16_t i;
        uint8_t used = 0;

        for (i = 0; i < n; i++) {
            if (buf[i] != (s->consumed + i) % 256) {
                s->mismatches++;
            }
        }
        s->consumed += n;

        // Print the chunk like the course tips do, a few numbers per line.
        for (i = 0; i < n; i++) {
            used += sprintf(line + used, "%d,", buf[i]);
            if ((i + 1) % NUMBERS_PER_LINE == 0 || i + 1 == n) {
                dbg(TGEN_CHANNEL, "Reading Data (fd %d): %s\n", s->fd, line);
                used = 0;
            }
        }

        // Only close once the peer's FIN came and every byte was read.
        if (s->eof && n == 0 && !s->closeCalled) {
            dbg(TGEN_CHANNEL, "server result! fd: %d, total: %d, mismatches: %d\n", s->fd, s->consumed, s->mismatches);
            s->closeCalled = TRUE;
            call Transport.close(s->fd);
        }
    }

    event void appTimer.fired(){
        uint8_t i;
        socket_t newFd;
        session* s;

        for (i = 0; i < listenerCount; i++) {
            newFd = call Transport.accept(listeners[i]);
            while (newFd != NULL_SOCKET) {
                s = allocate();
                if (s == NULL) {
                    dbg(TGEN_CHANNEL, "server accept failed! no free session. fd: %d\n", newFd);
                    call Transport.release(newFd);
                } else {
                    s->isServer = TRUE;
                    s->fd = newFd;
                    dbg(TGEN_CHANNEL, "server accepted! fd: %d\n", newFd);
                }
                newFd = call Transport.accept(listeners[i]);
            }
        }

        for (i = 0; i < MAX_SESSIONS; i++) {
            s = &sessions[i];
            if (!s->inUse) {
                continue;
            }

            if (s->isServer) {
                consume(s);
            } else if (s->connected) {
                if (s->accepted < s->total) {
                    produce(s);
                }
                if (s->closeRequested && s->accepted == s->total && !s->closeCalled) {
                    s->closeCalled = TRUE;
                    dbg(TGEN_CHANNEL, "client closing! conn: %d:%d->%d:%d\n", TOS_NODE_ID, s->srcPort, s->dest, s->destPort);
                    call Transport.close(s->fd);
                }
            }
        }
    }

    event void Transport.connectDone(socket_t fd, error_t result){
        session* s = findByFd(fd);

        if (s == NULL) {
            return;
        }
        if (result == SUCCESS) {
            s->connected = TRUE;
            dbg(TGEN_CHANNEL, "client connected! conn: %d:%d->%d:%d, fd: %d\n", TOS_NODE_ID, s->srcPort, s->dest, s->destPort, fd);
        } else {
            dbg(TGEN_CHANNEL, "client connect failed! conn: %d:%d->%d:%d, fd: %d\n", TOS_NODE_ID, s->srcPort, s->dest, s->destPort, fd);
            s->inUse = FALSE;
        }
    }

    event void Transport.remoteClosed(socket_t fd){
        session* s = findByFd(fd);

        if (s != NULL && s->isServer) {
            s->eof = TRUE;
            dbg(TGEN_CHANNEL, "server saw remote close! fd: %d\n", fd);
        }
    }

    event void Transport.closeDone(socket_t fd, error_t result){
        session* s = findByFd(fd);

        if (s == NULL) {
            return;
        }
        dbg(TGEN_CHANNEL, "close done! fd: %d, result: %s\n", fd, result == SUCCESS ? "SUCCESS" : "FAIL");
        if (!s->isServer) {
            dbg(TGEN_CHANNEL, "client result! fd: %d, accepted: %d, total: %d\n", fd, s->accepted, s->total);
        }
        s->inUse = FALSE;
    }
}
