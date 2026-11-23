#include "../../includes/packet.h"
#include "../../includes/tcp.h"

module IPP{
   provides interface IP;

   uses interface SimpleSend as Sender;
   uses interface Receive;
   uses interface DistanceVector;
}

implementation{
    pack sendPackage;
    uint16_t mySeq = 0;

    // Test only. Drops the nth forwarded segment of dropKind, then turns itself off.
    uint8_t dropKind = DROP_NONE;
    uint8_t dropNth = 0;
    uint8_t dropSeen = 0;
    bool synAckSeen = FALSE;
    uint16_t zeroWndFrom = 0;
    uint16_t firstFinFrom = 0;
    bool bothFinsSeen = FALSE;

    uint8_t segmentKind(pack* msg){
        tcpSegment* seg = (tcpSegment*) msg->payload;
        uint8_t flags = tcpFlags(seg);
        uint8_t kind = DROP_ACK;

        if (flags == TCP_SYN) {
            firstFinFrom = 0;
            bothFinsSeen = FALSE;
            return DROP_SYN;
        }
        if (flags == (TCP_SYN | TCP_ACK)) {
            synAckSeen = TRUE;
            return DROP_SYNACK;
        }
        if (flags & TCP_FIN) {
            if (firstFinFrom == 0) {
                firstFinFrom = msg->src;
            } else if (msg->src != firstFinFrom) {
                bothFinsSeen = TRUE;
            }
            return DROP_FIN;
        }
        if (tcpLen(seg) > 0) {
            return DROP_DATA;
        }

        if (synAckSeen) {
            synAckSeen = FALSE;
            kind = DROP_HANDSHAKE_ACK;
        } else if (bothFinsSeen && msg->src == firstFinFrom) {
            kind = DROP_FINAL_ACK;
        } else if (zeroWndFrom == msg->src && seg->window > 0) {
            kind = DROP_WINDOW_UPDATE;
        }

        if (seg->window == 0) {
            zeroWndFrom = msg->src;
        } else if (zeroWndFrom == msg->src) {
            zeroWndFrom = 0;
        }
        return kind;
    }

    // Every forwarded segment goes through segmentKind, rule or not, so it knows where the connection is when a rule is set.
    bool shouldDropForTest(pack* msg){
        if (msg->protocol != PROTOCOL_TCP || tcpLen((tcpSegment*) msg->payload) > TCP_MAX_DATA) {
            return FALSE;
        }
        if (segmentKind(msg) != dropKind || dropKind == DROP_NONE) {
            return FALSE;
        }

        dropSeen++;
        if (dropSeen < dropNth) {
            return FALSE;
        }
        dbg(TRANSPORT_CHANNEL, "TEST_DROP kind: %d, occurrence: %d, src: %d, dest: %d\n", dropKind, dropSeen, msg->src, msg->dest);
        dropKind = DROP_NONE;
        return TRUE;
    }

    command void IP.setDropRule(uint8_t kind, uint8_t nth){
        dbg(TRANSPORT_CHANNEL, "drop rule set! kind: %d, occurrence: %d\n", kind, nth);
        dropKind = kind;
        dropNth = nth;
        dropSeen = 0;
    }

    // Send msg to the next hop for its destination. If there's no route, drop it. Never fall back to flooding.
    error_t forward(pack msg) {
        uint16_t nextHop;
        uint8_t cost;

        if (!call DistanceVector.lookup(msg.dest, &nextHop, &cost)) {
            dbg(ROUTING_CHANNEL, "no route! packet dropped. src: %d, dest: %d, seq: %d\n", msg.src, msg.dest, msg.seq);
            return FAIL;
        }

        if (call Sender.send(msg, nextHop) != SUCCESS) {
            dbg(ROUTING_CHANNEL, "send failed! packet dropped. src: %d, dest: %d, seq: %d\n", msg.src, msg.dest, msg.seq);
            return FAIL;
        }

        dbg(ROUTING_CHANNEL, "Routing Packet - src: %d, dest: %d, seq: %d, next hop: %d, cost: %d\n", msg.src, msg.dest, msg.seq, nextHop, cost);
        return SUCCESS;
    }

    // The source sends with the TTL it was given. Only forwarders decrement it.
    command error_t IP.send(uint16_t dest, uint8_t protocol, uint8_t TTL, uint8_t *payload){
        if (TTL == 0) {
            dbg(ROUTING_CHANNEL, "TTL must be positive! packet dropped. dest: %d\n", dest);
            return FAIL;
        }

        makePack(&sendPackage, TOS_NODE_ID, dest, TTL, protocol, mySeq, payload, PACKET_MAX_PAYLOAD_SIZE);
        mySeq++;

        // The radio won't deliver to ourselves, so hand it straight up.
        if (dest == TOS_NODE_ID) {
            signal IP.receive(sendPackage);
            return SUCCESS;
        }

        return forward(sendPackage);
    }

    void handlePacket(pack msg){
        // If the packet is for us, hand it up to Ping.
        if (msg.dest == TOS_NODE_ID) {
            if (msg.TTL > 0) {
                signal IP.receive(msg);
            }
            return;
        }

        // A TTL of 1 means this was the packet's last allowed hop.
        if (msg.TTL <= 1) {
            dbg(ROUTING_CHANNEL, "TTL expired! packet dropped. src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
            return;
        }

        // Forwarders only change the TTL. src, dest, seq, protocol and payload stay as the source sent them.
        if (shouldDropForTest(&msg)) {
            return;
        }

        msg.TTL -= 1;
        forward(msg);
    }

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
        if (len == sizeof(pack)) {
            pack* myMsg = (pack*) payload;
            handlePacket(*myMsg);
            return msg;
        }
        dbg(ROUTING_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }
}