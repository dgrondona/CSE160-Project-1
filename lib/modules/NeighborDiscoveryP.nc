#include "../../includes/packet.h"

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as discoveryTimer;
   uses interface Random;
   uses interface SimpleSend as Sender;
   uses interface Receive;
}

implementation{
    pack sendPackage;

    enum {
        MAX_NEIGHBORS = 32,
        MAX_MISSED = 3,
        DISCOVERY_PERIOD = 3457,
        PERIOD_JITTER = 607
    };

    typedef struct Neighbor {
        uint16_t addr;
        uint16_t missedCount;
    }Neighbor;

    Neighbor neighborList[MAX_NEIGHBORS];
    uint16_t neighborCount = 0;

    void handlePacket(pack msg){

        if (msg.protocol == PROTOCOL_PINGREPLY) {

            int i;

            // Replies are unicast back to the prober, so only the node that sent the probe counts this reply.
            if (msg.dest != TOS_NODE_ID) {
                return;
            }

            for (i = 0; i < neighborCount; i++) {
                if (neighborList[i].addr == msg.src) {
                    neighborList[i].missedCount = 0;
                    return;
                }
            }

            if (neighborCount < MAX_NEIGHBORS) {
                neighborList[neighborCount].addr = msg.src;
                neighborList[neighborCount].missedCount = 0;
                neighborCount++;

                dbg(NEIGHBOR_CHANNEL, "new neighbor: %d\n", msg.src);
                signal NeighborDiscovery.neighborAdded(msg.src);
            } else {
                dbg(NEIGHBOR_CHANNEL, "neighbor list full! dropped: %d\n", msg.src);
            }
        } else {
            uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
            memset(payload, 0, PACKET_MAX_PAYLOAD_SIZE);

            // Reply straight to the prober. It only hears this if the link works both ways.
            makePack(&sendPackage, TOS_NODE_ID, msg.src, 1, PROTOCOL_PINGREPLY, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
            call Sender.send(sendPackage, msg.src);
        }
    }

    command void NeighborDiscovery.startDiscovery(){
        uint16_t jitter = call Random.rand16() % PERIOD_JITTER;

        call discoveryTimer.startPeriodic(DISCOVERY_PERIOD + jitter);
        dbg(NEIGHBOR_CHANNEL, "startDiscovery called! Jitter: %d, Period: %d\n", jitter, DISCOVERY_PERIOD + jitter);
    }

    command void NeighborDiscovery.printNeighbors(){
        int i;
        dbg(NEIGHBOR_CHANNEL, "printNeighbors for %d\n", TOS_NODE_ID);

        for (i = 0; i < neighborCount; i++) {
            dbg(NEIGHBOR_CHANNEL, "%d\n", neighborList[i].addr);
        }
    }

    command bool NeighborDiscovery.isNeighbor(uint16_t id){
        int i;
        for (i = 0; i < neighborCount; i++) {
            if (neighborList[i].addr == id) {
                return TRUE;
            }
        }
        return FALSE;
    }

    // Copy up to max neighbor addresses into buf and return how many were copied.
    command uint8_t NeighborDiscovery.getNeighbors(uint16_t* buf, uint8_t max){
        int i;
        for (i = 0; i < neighborCount && i < max; i++) {
            buf[i] = neighborList[i].addr;
        }
        return i;
    }

    event void discoveryTimer.fired(){
        int i;
        uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
        memset(payload, 0, PACKET_MAX_PAYLOAD_SIZE);

        for (i = neighborCount - 1; i >= 0; i--) {
            neighborList[i].missedCount++;

            if (neighborList[i].missedCount > MAX_MISSED) {
                uint16_t dropped = neighborList[i].addr;
                dbg(NEIGHBOR_CHANNEL, "neighbor %d dropped\n", dropped);

                neighborList[i] = neighborList[neighborCount - 1];
                neighborCount--;

                // Signal after the list is compacted so listeners never see a half updated list.
                signal NeighborDiscovery.neighborRemoved(dropped);
            }
        }

        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);

        dbg(NEIGHBOR_CHANNEL, "sending neighbor probe!\n");
    }

    // Neighbor discovery packets come in on their own AM type.
    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
        if (len == sizeof(pack)) {
            pack* myMsg = (pack*) payload;
            handlePacket(*myMsg);
            return msg;
        }
        dbg(NEIGHBOR_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }
}