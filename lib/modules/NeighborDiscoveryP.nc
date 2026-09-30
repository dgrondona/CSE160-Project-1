#include "../../includes/packet.h"

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as discoveryTimer;
   uses interface Random;
   uses interface SimpleSend as Sender;
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

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
    }

    command void NeighborDiscovery.startDiscovery(){
        uint16_t jitter = call Random.rand16() % PERIOD_JITTER;

        call discoveryTimer.startPeriodic(DISCOVERY_PERIOD + jitter);
        dbg(NEIGHBOR_CHANNEL, "startDiscovery called! Jitter: %d\n", jitter);
    }

    command void NeighborDiscovery.printNeighbors(){
        int i;
        dbg(NEIGHBOR_CHANNEL, "printNeighbors for %d\n", TOS_NODE_ID);

        for (i = 0; i < neighborCount; i++) {
            dbg(NEIGHBOR_CHANNEL, "%d\n", neighborList[i].addr);
        }
    }

    command void NeighborDiscovery.handlePacket(pack msg){

        if (msg.protocol == PROTOCOL_PINGREPLY) {

            int i;
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
            }
        } else {
            uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
            memset(payload, 0, PACKET_MAX_PAYLOAD_SIZE);

            makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PINGREPLY, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
            call Sender.send(sendPackage, AM_BROADCAST_ADDR);            
        }
    }

    event void discoveryTimer.fired(){
        int i;
        uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
        memset(payload, 0, PACKET_MAX_PAYLOAD_SIZE);

        for (i = neighborCount - 1; i >= 0; i--) {
            neighborList[i].missedCount++;

            if (neighborList[i].missedCount > MAX_MISSED) {
                dbg(NEIGHBOR_CHANNEL, "neighbor %d dropped\n", neighborList[i].addr);

                neighborList[i] = neighborList[neighborCount - 1];
                neighborCount--;
            }
        }

        makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);

        dbg(NEIGHBOR_CHANNEL, "timer fired!\n");
    }
}