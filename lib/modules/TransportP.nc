#include "../../includes/packet.h"
#include "../../includes/tcp.h"
#include "../../includes/socket.h"

// Every transport log line starts with the connection as local:port->remote:port.
#define CONN(s) TOS_NODE_ID, (s)->src, (s)->dest.addr, (s)->dest.port

module TransportP{
   provides interface Transport;

   uses interface IP;
   uses interface Timer<TMilli> as tickTimer;
}

implementation{
    enum{
        // 4 segments in flight. Small enough that a Go-Back-N burst fits SimpleSend's queue next to DV traffic.
        SEND_WINDOW = 4 * TCP_MAX_DATA,
        TICK_PERIOD = 250,
        // 3 hops each way with up to 300 ms of SimpleSend delay per hop keeps the RTT under about 2 s.
        RTO = 3000,
        MAX_RETRIES = 6,
        // Longer than every FIN retry the peer could still send, so a lost final ACK always gets answered.
        TIME_WAIT_PERIOD = RTO * (MAX_RETRIES + 1)
    };

    socket_store_t sockets[MAX_NUM_OF_SOCKETS];
    tcpSegment outSeg;
    bool pumpPosted = FALSE;

    task void pumpTask();
    task void notifyClosedTask();

    char* stateName(enum socket_state state){
        switch(state){
            case CLOSED: return "CLOSED";
            case LISTEN: return "LISTEN";
            case ESTABLISHED: return "ESTABLISHED";
            case SYN_SENT: return "SYN_SENT";
            case SYN_RCVD: return "SYN_RCVD";
            case FIN_WAIT_1: return "FIN_WAIT_1";
            case FIN_WAIT_2: return "FIN_WAIT_2";
            case CLOSING: return "CLOSING";
            case TIME_WAIT: return "TIME_WAIT";
            case CLOSE_WAIT: return "CLOSE_WAIT";
            case LAST_ACK: return "LAST_ACK";
        }
        return "?";
    }

    socket_t fdOf(socket_store_t* s){
        return s - sockets;
    }

    void postPump(){
        if (!pumpPosted) {
            pumpPosted = TRUE;
            post pumpTask();
        }
    }

    void setState(socket_store_t* s, enum socket_state state){
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d STATE %s -> %s\n", CONN(s), stateName(s->state), stateName(state));
        s->state = state;
    }

    void startTimer(socket_store_t* s, uint32_t period){
        s->timerOn = TRUE;
        s->deadline = call tickTimer.getNow() + period;
    }

    // Clock based, like real TCP, so a new instance of the same tuple starts somewhere else in sequence space.
    uint16_t newIsn(){
        return (uint16_t)(call tickTimer.getNow() / 4);
    }

    // The FIN takes a sequence number but isn't a byte in the buffer.
    uint16_t rcvdBytes(socket_store_t* s){
        uint16_t end = s->finRcvd ? s->nextExpected - 1 : s->nextExpected;
        return end - s->lastRead;
    }

    uint8_t rcvWindow(socket_store_t* s){
        return SOCKET_BUFFER_SIZE - rcvdBytes(s);
    }

    uint16_t outstanding(socket_store_t* s){
        return s->lastSent - s->lastAck;
    }

    void releaseSocket(socket_store_t* s){
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d RELEASE fd: %d, acked: %d\n", CONN(s), fdOf(s), s->bytesAcked);
        memset(s, 0, sizeof(socket_store_t));
    }

    socket_store_t* allocSocket(){
        uint8_t i;
        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (!sockets[i].inUse) {
                memset(&sockets[i], 0, sizeof(socket_store_t));
                sockets[i].inUse = TRUE;
                sockets[i].state = CLOSED;
                sockets[i].parent = NULL_SOCKET;

                if (!call tickTimer.isRunning()) {
                    call tickTimer.startPeriodic(TICK_PERIOD);
                }
                return &sockets[i];
            }
        }
        return NULL;
    }

    socket_store_t* getSocket(socket_t fd){
        if (fd >= MAX_NUM_OF_SOCKETS || !sockets[fd].inUse) {
            return NULL;
        }
        return &sockets[fd];
    }

    // Match on all four values. Listeners never match here, they only take new SYNs.
    socket_store_t* findSocket(uint16_t remoteAddr, uint8_t remotePort, uint8_t localPort){
        uint8_t i;
        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            socket_store_t* s = &sockets[i];
            if (s->inUse && s->state != CLOSED && s->state != LISTEN && s->src == localPort && s->dest.addr == remoteAddr && s->dest.port == remotePort) {
                return s;
            }
        }
        return NULL;
    }

    socket_store_t* findListener(uint8_t localPort){
        uint8_t i;
        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (sockets[i].inUse && sockets[i].state == LISTEN && sockets[i].src == localPort) {
                return &sockets[i];
            }
        }
        return NULL;
    }

    // IP.send copies the payload before returning, so outSeg can be reused right away.
    error_t sendSegment(socket_store_t* s, uint8_t flags, uint16_t seq, uint8_t* data, uint8_t len){
        memset(&outSeg, 0, sizeof(tcpSegment));
        outSeg.srcPort = s->src;
        outSeg.destPort = s->dest.port;
        outSeg.seq = seq;
        outSeg.ack = (flags & TCP_ACK) ? s->nextExpected : 0;
        outSeg.window = rcvWindow(s);
        outSeg.flagsLen = (flags << 4) | len;
        if (len > 0) {
            memcpy(outSeg.data, data, len);
        }
        return call IP.send(s->dest.addr, PROTOCOL_TCP, MAX_TTL, (uint8_t*) &outSeg);
    }

    void sendAck(socket_store_t* s){
        sendSegment(s, TCP_ACK, s->lastSent, NULL, 0);
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ACK_TX ack: %d, wnd: %d\n", CONN(s), s->nextExpected, rcvWindow(s));
    }

    error_t sendData(socket_store_t* s, uint16_t seq, uint8_t len, bool retx){
        uint8_t data[TCP_MAX_DATA];
        uint8_t i;
        uint16_t inFlight;
        error_t result;

        for (i = 0; i < len; i++) {
            data[i] = s->sendBuff[(uint16_t)(seq + i) % SOCKET_BUFFER_SIZE];
        }

        // Outstanding counts this segment too. New data hasn't moved lastSent yet.
        inFlight = retx ? outstanding(s) : (uint16_t)(seq + len - s->lastAck);

        result = sendSegment(s, TCP_ACK, seq, data, len);
        if (result == SUCCESS) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d %s seq: %d, len: %d, outstanding: %d, peerWnd: %d\n", CONN(s), retx ? "DATA_RETX" : "DATA_TX", seq, len, inFlight, s->peerWindow);
        } else {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d DATA_TX failed! seq: %d, will retry\n", CONN(s), seq);
        }
        return result;
    }

    void enterTimeWait(socket_store_t* s){
        setState(s, TIME_WAIT);
        s->retries = 0;
        startTimer(s, TIME_WAIT_PERIOD);

        // The close exchange is done here. The record just lingers to answer duplicate FINs.
        if (s->appOwned) {
            s->appOwned = FALSE;
            signal Transport.closeDone(fdOf(s), SUCCESS);
        }
    }

    void failSocket(socket_store_t* s){
        socket_t fd = fdOf(s);
        bool owned = s->appOwned;
        bool connecting = s->state == SYN_SENT;

        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FAILED in %s after %d retries\n", CONN(s), stateName(s->state), MAX_RETRIES);
        releaseSocket(s);

        if (owned && connecting) {
            signal Transport.connectDone(fd, FAIL);
        } else if (owned) {
            signal Transport.closeDone(fd, FAIL);
        }
    }

    // Go-Back-N: resend everything unacked, in order, from lastAck. With stop-and-wait that's one segment.
    void retransmit(socket_store_t* s){
        uint16_t seq;
        uint16_t dataEnd;

        if (s->state == SYN_SENT) {
            sendSegment(s, TCP_SYN, s->lastAck, NULL, 0);
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYN_RETX seq: %d, retry: %d\n", CONN(s), s->lastAck, s->retries);
            return;
        }

        if (s->state == SYN_RCVD) {
            sendSegment(s, TCP_SYN | TCP_ACK, s->lastAck, NULL, 0);
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYNACK_RETX seq: %d, ack: %d, retry: %d\n", CONN(s), s->lastAck, s->nextExpected, s->retries);
            return;
        }

        dataEnd = s->finSent ? s->finSeq : s->lastSent;
        seq = s->lastAck;
        while (seqLT(seq, dataEnd)) {
            uint16_t len = dataEnd - seq;
            if (len > TCP_MAX_DATA) {
                len = TCP_MAX_DATA;
            }
            sendData(s, seq, len, TRUE);
            seq += len;
        }

        if (s->finSent && seqLEQ(s->lastAck, s->finSeq)) {
            sendSegment(s, TCP_FIN | TCP_ACK, s->finSeq, NULL, 0);
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FIN_RETX seq: %d, retry: %d\n", CONN(s), s->finSeq, s->retries);
        }
    }

    void onTimeout(socket_store_t* s){
        if (s->state == TIME_WAIT) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d TIME_WAIT over\n", CONN(s));
            setState(s, CLOSED);
            releaseSocket(s);
            return;
        }

        // The peer ACKed our FIN but never sent its own.
        if (s->state == FIN_WAIT_2) {
            socket_t fd = fdOf(s);
            bool owned = s->appOwned;
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FIN_WAIT_2 timeout, no FIN from peer\n", CONN(s));
            releaseSocket(s);
            if (owned) {
                signal Transport.closeDone(fd, FAIL);
            }
            return;
        }

        if (outstanding(s) > 0) {
            s->retries++;
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d TIMEOUT state: %s, lastAck: %d, outstanding: %d, retry: %d\n", CONN(s), stateName(s->state), s->lastAck, outstanding(s), s->retries);
            if (s->retries > MAX_RETRIES) {
                failSocket(s);
                return;
            }
            retransmit(s);
            startTimer(s, RTO);
            return;
        }

        // Zero window probe. One byte past the window, the receiver drops it if there's still no room
        // but has to ACK it, and that ACK carries the current window. Covers a lost window update.
        if (s->peerWindow == 0 && s->lastWritten != s->lastSent) {
            if (sendData(s, s->lastSent, 1, FALSE) == SUCCESS) {
                dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d WINDOW_PROBE seq: %d\n", CONN(s), s->lastSent);
                s->lastSent++;
            }
            startTimer(s, RTO);
        }
    }

    // Send at most one new segment for this connection. Returns TRUE if it might have more to send.
    bool pumpSocket(socket_store_t* s){
        uint16_t queued;
        uint16_t inFlight;
        uint16_t limit;
        uint16_t len;

        if (s->state != ESTABLISHED && s->state != CLOSE_WAIT && s->state != FIN_WAIT_1 && s->state != LAST_ACK) {
            return FALSE;
        }
        if (s->finSent) {
            return FALSE;
        }

        queued = s->lastWritten - s->lastSent;
        inFlight = outstanding(s);
        limit = SEND_WINDOW < s->peerWindow ? SEND_WINDOW : s->peerWindow;

        if (queued > 0 && inFlight < limit) {
            len = limit - inFlight;
            if (len > queued) {
                len = queued;
            }
            if (len > TCP_MAX_DATA) {
                len = TCP_MAX_DATA;
            }

            // A refused send (no route or full queue) leaves lastSent alone, the next tick tries again.
            if (sendData(s, s->lastSent, len, FALSE) != SUCCESS) {
                return FALSE;
            }
            s->lastSent += len;
            if (inFlight == 0) {
                startTimer(s, RTO);
            }
            return TRUE;
        }

        if (queued > 0 && s->peerWindow == 0 && inFlight == 0 && !s->timerOn) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ZERO_WINDOW queued: %d, probing in %d ms\n", CONN(s), queued, RTO);
            startTimer(s, RTO);
            return FALSE;
        }

        // FIN only goes out once every byte before it is acked.
        if (s->finPending && queued == 0 && inFlight == 0) {
            if (sendSegment(s, TCP_FIN | TCP_ACK, s->lastSent, NULL, 0) != SUCCESS) {
                return FALSE;
            }
            s->finSeq = s->lastSent;
            s->finSent = TRUE;
            s->lastSent++;
            s->retries = 0;
            startTimer(s, RTO);
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FIN_TX seq: %d, acked: %d\n", CONN(s), s->finSeq, s->bytesAcked);
        }
        return FALSE;
    }

    task void pumpTask(){
        uint8_t i;
        bool more = FALSE;
        pumpPosted = FALSE;

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (sockets[i].inUse && pumpSocket(&sockets[i])) {
                more = TRUE;
            }
        }

        if (more) {
            postPump();
        }
    }

    // Posted so the app has the fd from accept() before it hears about the close.
    task void notifyClosedTask(){
        uint8_t i;
        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (sockets[i].inUse && sockets[i].notifyClosed) {
                sockets[i].notifyClosed = FALSE;
                signal Transport.remoteClosed(i);
            }
        }
    }

    event void tickTimer.fired(){
        uint8_t i;
        uint32_t now = call tickTimer.getNow();

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            socket_store_t* s = &sockets[i];
            if (s->inUse && s->timerOn && (int32_t)(now - s->deadline) >= 0) {
                s->timerOn = FALSE;
                onTimeout(s);
            }
        }
        postPump();
    }

    // A new SYN for a tuple we don't have yet. Repeats of the same SYN match the record in findSocket instead.
    void handleSyn(uint16_t src, tcpSegment* seg){
        socket_store_t* listener = findListener(seg->destPort);
        socket_store_t* s;

        if (listener == NULL) {
            dbg(TRANSPORT_CHANNEL, "SYN dropped! no listener on port: %d, from: %d:%d\n", seg->destPort, src, seg->srcPort);
            return;
        }

        s = allocSocket();
        if (s == NULL) {
            dbg(TRANSPORT_CHANNEL, "SYN dropped! connection table full, from: %d:%d\n", src, seg->srcPort);
            return;
        }

        s->parent = fdOf(listener);
        s->src = seg->destPort;
        s->dest.addr = src;
        s->dest.port = seg->srcPort;
        s->nextExpected = seg->seq + 1;
        s->lastRead = seg->seq + 1;
        s->lastAck = newIsn();
        s->lastSent = s->lastAck + 1;
        s->lastWritten = s->lastSent;
        s->peerWindow = seg->window;

        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ALLOC fd: %d, from listener fd: %d\n", CONN(s), fdOf(s), s->parent);
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYN_RX seq: %d, wnd: %d\n", CONN(s), seg->seq, seg->window);
        setState(s, SYN_RCVD);

        sendSegment(s, TCP_SYN | TCP_ACK, s->lastAck, NULL, 0);
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYNACK_TX seq: %d, ack: %d\n", CONN(s), s->lastAck, s->nextExpected);
        startTimer(s, RTO);
    }

    void handleAck(socket_store_t* s, uint16_t ack, uint8_t window){
        uint16_t dataAck;

        // Anything outside what we've actually sent is old or bogus.
        if (seqLT(ack, s->lastAck) || seqLT(s->lastSent, ack)) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ACK_RX ignored! ack: %d, lastAck: %d, lastSent: %d\n", CONN(s), ack, s->lastAck, s->lastSent);
            return;
        }

        // Any valid ACK means the peer is alive, so zero window probing never counts as a failure.
        s->retries = 0;
        s->peerWindow = window;

        if (ack == s->lastAck) {
            return;
        }

        dataAck = ack;
        if (s->finSent && seqLT(s->finSeq, ack)) {
            dataAck = s->finSeq;
        }
        if (seqLT(s->lastAck, dataAck)) {
            s->bytesAcked += dataAck - s->lastAck;
        }
        s->lastAck = ack;

        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ACK_RX ack: %d, wnd: %d, acked: %d, outstanding: %d\n", CONN(s), ack, window, s->bytesAcked, outstanding(s));

        if (outstanding(s) > 0) {
            startTimer(s, RTO);
        } else {
            s->timerOn = FALSE;
        }

        if (s->finSent && ack == (uint16_t)(s->finSeq + 1)) {
            if (s->state == FIN_WAIT_1) {
                setState(s, FIN_WAIT_2);
                startTimer(s, TIME_WAIT_PERIOD);
            } else if (s->state == CLOSING) {
                enterTimeWait(s);
            } else if (s->state == LAST_ACK) {
                socket_t fd = fdOf(s);
                bool owned = s->appOwned;
                setState(s, CLOSED);
                releaseSocket(s);
                if (owned) {
                    signal Transport.closeDone(fd, SUCCESS);
                }
                return;
            }
        }

        postPump();
    }

    // In order only. Anything else is dropped, but still gets the current cumulative ACK.
    void handleData(socket_store_t* s, tcpSegment* seg, uint8_t len){
        uint8_t i;

        if (s->state != ESTABLISHED && s->state != FIN_WAIT_1 && s->state != FIN_WAIT_2) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d DATA_RX dropped! seq: %d, after FIN in %s\n", CONN(s), seg->seq, stateName(s->state));
        } else if (seg->seq != s->nextExpected) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d DATA_RX dropped! seq: %d, len: %d, expected: %d\n", CONN(s), seg->seq, len, s->nextExpected);
        } else if (len > rcvWindow(s)) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d DATA_RX dropped! seq: %d, len: %d, no room, wnd: %d\n", CONN(s), seg->seq, len, rcvWindow(s));
        } else {
            for (i = 0; i < len; i++) {
                s->rcvdBuff[(uint16_t)(s->nextExpected + i) % SOCKET_BUFFER_SIZE] = seg->data[i];
            }
            s->nextExpected += len;
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d DATA_RX seq: %d, len: %d, buffered: %d\n", CONN(s), seg->seq, len, rcvdBytes(s));
            if (s->state == FIN_WAIT_2) {
                startTimer(s, TIME_WAIT_PERIOD);
            }
        }
    }

    void handleFin(socket_store_t* s, tcpSegment* seg){
        if (s->finRcvd) {
            // Our ACK of their FIN was lost. ACK it again and keep lingering.
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FIN_RX duplicate seq: %d\n", CONN(s), seg->seq);
            if (s->state == TIME_WAIT) {
                startTimer(s, TIME_WAIT_PERIOD);
            }
            return;
        }

        // A FIN ahead of a gap can't end the stream yet.
        if (seg->seq != s->nextExpected) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FIN_RX early! seq: %d, expected: %d\n", CONN(s), seg->seq, s->nextExpected);
            return;
        }

        s->nextExpected++;
        s->finRcvd = TRUE;
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d FIN_RX seq: %d\n", CONN(s), seg->seq);

        if (s->state == ESTABLISHED) {
            setState(s, CLOSE_WAIT);
            if (s->appOwned) {
                signal Transport.remoteClosed(fdOf(s));
            }
        } else if (s->state == FIN_WAIT_1) {
            setState(s, CLOSING);
        } else if (s->state == FIN_WAIT_2) {
            enterTimeWait(s);
        }
    }

    void handleSegment(uint16_t src, tcpSegment* seg){
        uint8_t flags = tcpFlags(seg);
        uint8_t len = tcpLen(seg);
        socket_store_t* s;

        if (len > TCP_MAX_DATA) {
            dbg(TRANSPORT_CHANNEL, "segment dropped! bad length: %d, from: %d\n", len, src);
            return;
        }

        s = findSocket(src, seg->srcPort, seg->destPort);
        if (s == NULL) {
            if (flags == TCP_SYN) {
                handleSyn(src, seg);
            } else {
                dbg(TRANSPORT_CHANNEL, "segment dropped! no connection %d:%d->%d:%d, flags: %d\n", TOS_NODE_ID, seg->destPort, src, seg->srcPort, flags);
            }
            return;
        }

        if (s->state == SYN_SENT) {
            if (flags == (TCP_SYN | TCP_ACK) && seg->ack == s->lastSent) {
                dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYNACK_RX seq: %d, ack: %d, wnd: %d\n", CONN(s), seg->seq, seg->ack, seg->window);
                s->nextExpected = seg->seq + 1;
                s->lastRead = seg->seq + 1;
                s->lastAck = seg->ack;
                s->peerWindow = seg->window;
                s->retries = 0;
                s->timerOn = FALSE;
                setState(s, ESTABLISHED);
                sendAck(s);
                signal Transport.connectDone(fdOf(s), SUCCESS);
            } else {
                dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d dropped! flags: %d in SYN_SENT\n", CONN(s), flags);
            }
            return;
        }

        if (s->state == SYN_RCVD) {
            if (flags == TCP_SYN && (uint16_t)(seg->seq + 1) == s->nextExpected) {
                dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYN_RX duplicate, resending SYNACK\n", CONN(s));
                sendSegment(s, TCP_SYN | TCP_ACK, s->lastAck, NULL, 0);
                return;
            }
            if (!(flags & TCP_ACK) || seg->ack != s->lastSent) {
                dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d dropped! flags: %d, ack: %d in SYN_RCVD\n", CONN(s), flags, seg->ack);
                return;
            }

            // Usually the final handshake ACK, but data carries the same ACK, so a lost final ACK costs nothing.
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ACK_RX handshake ack: %d\n", CONN(s), seg->ack);
            s->lastAck = seg->ack;
            s->retries = 0;
            s->timerOn = FALSE;
            setState(s, ESTABLISHED);
        }

        // Our final handshake ACK was lost and the server resent SYN-ACK. Just ACK again.
        if (flags & TCP_SYN) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYNACK_RX duplicate, resending ACK\n", CONN(s));
            sendAck(s);
            return;
        }

        if (flags & TCP_ACK) {
            handleAck(s, seg->ack, seg->window);
            if (!s->inUse) {
                return;
            }
        }

        if (len > 0) {
            handleData(s, seg, len);
        }

        if (flags & TCP_FIN) {
            handleFin(s, seg);
        }

        // Data and FIN get ACKed, even when dropped. A pure ACK never does, or we'd loop.
        if (len > 0 || (flags & TCP_FIN)) {
            sendAck(s);
        }
    }

    event void IP.receive(pack msg){
        if (msg.protocol == PROTOCOL_TCP) {
            handleSegment(msg.src, (tcpSegment*) msg.payload);
        }
    }

    command error_t Transport.receive(pack* package){
        if (package->protocol != PROTOCOL_TCP) {
            return FAIL;
        }
        handleSegment(package->src, (tcpSegment*) package->payload);
        return SUCCESS;
    }

    command socket_t Transport.socket(){
        socket_store_t* s = allocSocket();
        if (s == NULL) {
            dbg(TRANSPORT_CHANNEL, "socket failed! table full\n");
            return NULL_SOCKET;
        }
        s->appOwned = TRUE;
        return fdOf(s);
    }

    // Port 0 means unbound. A port can't be reused while any record has it, including one in TIME_WAIT.
    command error_t Transport.bind(socket_t fd, socket_addr_t *addr){
        socket_store_t* s = getSocket(fd);
        uint8_t i;

        if (s == NULL || s->state != CLOSED || addr->port == 0) {
            return FAIL;
        }

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if (i != fd && sockets[i].inUse && sockets[i].src == addr->port) {
                dbg(TRANSPORT_CHANNEL, "bind failed! port %d in use\n", addr->port);
                return FAIL;
            }
        }

        s->src = addr->port;
        return SUCCESS;
    }

    command error_t Transport.listen(socket_t fd){
        socket_store_t* s = getSocket(fd);

        if (s == NULL || s->state != CLOSED || s->src == 0) {
            return FAIL;
        }

        dbg(TRANSPORT_CHANNEL, "listening! fd: %d, port: %d\n", fd, s->src);
        s->state = LISTEN;
        return SUCCESS;
    }

    // Hands out the next established connection this listener spawned that the app hasn't taken yet.
    command socket_t Transport.accept(socket_t fd){
        socket_store_t* listener = getSocket(fd);
        uint8_t i;

        if (listener == NULL || listener->state != LISTEN) {
            return NULL_SOCKET;
        }

        for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            socket_store_t* s = &sockets[i];
            if (s->inUse && s->parent == fd && !s->appOwned && s->state != SYN_RCVD && s->state != TIME_WAIT) {
                s->appOwned = TRUE;
                dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ACCEPT fd: %d\n", CONN(s), i);
                // Its FIN came before the app owned it, so remoteClosed was never signaled.
                if (s->finRcvd) {
                    s->notifyClosed = TRUE;
                    post notifyClosedTask();
                }
                return i;
            }
        }
        return NULL_SOCKET;
    }

    command error_t Transport.connect(socket_t fd, socket_addr_t * addr){
        socket_store_t* s = getSocket(fd);

        if (s == NULL || s->state != CLOSED || s->src == 0) {
            return FAIL;
        }

        s->dest.addr = addr->addr;
        s->dest.port = addr->port;
        s->lastAck = newIsn();
        s->lastSent = s->lastAck + 1;
        s->lastWritten = s->lastSent;

        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d ALLOC fd: %d\n", CONN(s), fd);
        setState(s, SYN_SENT);

        // Even if this first send is refused, the timer retries it.
        sendSegment(s, TCP_SYN, s->lastAck, NULL, 0);
        dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d SYN_TX seq: %d, wnd: %d\n", CONN(s), s->lastAck, rcvWindow(s));
        startTimer(s, RTO);
        return SUCCESS;
    }

    // Takes as much as fits in the send buffer. Unacked bytes still count against the 128.
    command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen){
        socket_store_t* s = getSocket(fd);
        uint16_t space;
        uint16_t i;

        if (s == NULL || (s->state != ESTABLISHED && s->state != CLOSE_WAIT)) {
            return 0;
        }

        space = SOCKET_BUFFER_SIZE - (uint16_t)(s->lastWritten - s->lastAck);
        if (bufflen > space) {
            bufflen = space;
        }

        for (i = 0; i < bufflen; i++) {
            s->sendBuff[(uint16_t)(s->lastWritten + i) % SOCKET_BUFFER_SIZE] = buff[i];
        }
        s->lastWritten += bufflen;

        if (bufflen > 0) {
            postPump();
        }
        return bufflen;
    }

    command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen){
        socket_store_t* s = getSocket(fd);
        uint8_t oldWindow;
        uint16_t avail;
        uint16_t i;

        if (s == NULL || s->state == LISTEN || s->state == CLOSED) {
            return 0;
        }

        oldWindow = rcvWindow(s);
        avail = rcvdBytes(s);
        if (bufflen > avail) {
            bufflen = avail;
        }

        for (i = 0; i < bufflen; i++) {
            buff[i] = s->rcvdBuff[(uint16_t)(s->lastRead + i) % SOCKET_BUFFER_SIZE];
        }
        s->lastRead += bufflen;

        // Under a full segment the sender only sends short segments or probes, so tell it once a full one fits.
        if (bufflen > 0 && oldWindow < TCP_MAX_DATA && rcvWindow(s) >= TCP_MAX_DATA && !s->finRcvd) {
            dbg(TRANSPORT_CHANNEL, "conn %d:%d->%d:%d WINDOW_UPDATE wnd: %d -> %d\n", CONN(s), oldWindow, rcvWindow(s));
            sendAck(s);
        }
        return bufflen;
    }

    // Graceful close. FIN goes out from the pump once queued data is sent and acked.
    command error_t Transport.close(socket_t fd){
        socket_store_t* s = getSocket(fd);
        uint8_t i;

        if (s == NULL) {
            return FAIL;
        }

        switch(s->state){
            case LISTEN:
                // Connections it already spawned keep going on their own.
                for (i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
                    if (sockets[i].parent == fd) {
                        sockets[i].parent = NULL_SOCKET;
                    }
                }
                releaseSocket(s);
                return SUCCESS;

            case CLOSED:
            case SYN_SENT:
                releaseSocket(s);
                return SUCCESS;

            case ESTABLISHED:
                s->finPending = TRUE;
                setState(s, FIN_WAIT_1);
                postPump();
                return SUCCESS;

            case CLOSE_WAIT:
                s->finPending = TRUE;
                setState(s, LAST_ACK);
                postPump();
                return SUCCESS;

            default:
                return FAIL;
        }
    }

    command error_t Transport.release(socket_t fd){
        socket_store_t* s = getSocket(fd);
        if (s == NULL) {
            return FAIL;
        }
        releaseSocket(s);
        return SUCCESS;
    }
}
