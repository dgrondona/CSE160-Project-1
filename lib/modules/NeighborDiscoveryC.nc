#include "../../includes/packet.h"
#include "../../includes/am_types.h"

configuration NeighborDiscoveryC{
   provides interface NeighborDiscovery;
}

implementation{
   components NeighborDiscoveryP;
   NeighborDiscovery = NeighborDiscoveryP.NeighborDiscovery;

   components new SimpleSendC(AM_ND);
   NeighborDiscoveryP.Sender -> SimpleSendC;

   components new AMReceiverC(AM_ND);
   NeighborDiscoveryP.Receive -> AMReceiverC;

   components new TimerMilliC() as discoveryTimer;
   NeighborDiscoveryP.discoveryTimer -> discoveryTimer;

   components RandomC as Random;
   NeighborDiscoveryP.Random -> Random;
}