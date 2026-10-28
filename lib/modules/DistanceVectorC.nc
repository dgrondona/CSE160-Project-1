#include "../../includes/packet.h"
#include "../../includes/am_types.h"

configuration DistanceVectorC{
   provides interface DistanceVector;
}

implementation{
   components DistanceVectorP;
   DistanceVector = DistanceVectorP.DistanceVector;

   components new SimpleSendC(AM_DV);
   DistanceVectorP.Sender -> SimpleSendC;

   components new AMReceiverC(AM_DV);
   DistanceVectorP.Receive -> AMReceiverC;
   DistanceVectorP.AMPacket -> AMReceiverC;

   components NeighborDiscoveryC;
   DistanceVectorP.NeighborDiscovery -> NeighborDiscoveryC;

   components new TimerMilliC() as periodicTimer;
   DistanceVectorP.periodicTimer -> periodicTimer;

   components new TimerMilliC() as triggerTimer;
   DistanceVectorP.triggerTimer -> triggerTimer;

   components new TimerMilliC() as paceTimer;
   DistanceVectorP.paceTimer -> paceTimer;

   components RandomC as Random;
   DistanceVectorP.Random -> Random;
}