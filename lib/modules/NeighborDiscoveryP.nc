#include "../../includes/packet.h"

module NeighborDiscoveryP{
   provides interface NeighborDiscovery;

   uses interface Timer<TMilli> as discoveryTimer;
   uses interface Random;
   uses interface SimpleSend as Sender;
}

implementation{
    command void NeighborDiscovery.startDiscovery(){
        dbg(NEIGHBOR_CHANNEL, "startDiscovery called!\n");

        // send flood with TTL of 2 (come back to this, should make it 1, then decrement TTL after check)
        // record responses and take note of src of the packet
        // if after some time we recieve no responses, there may be a collision, use exponential binary backoff until we get responses
    }

    command void NeighborDiscovery.printNeighbors(){
        dbg(NEIGHBOR_CHANNEL, "printNeighbors called!\n");
    }

    event void discoveryTimer.fired(){
        dbg(NEIGHBOR_CHANNEL, "timer fired!\n");
    }
}