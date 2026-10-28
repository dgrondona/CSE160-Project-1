#include "../../includes/packet.h"
#include "../../includes/am_types.h"

configuration FloodingC{
   provides interface Flooding;
}

implementation{
   components FloodingP;
   Flooding = FloodingP.Flooding;

   components new SimpleSendC(AM_FLOODING);
   FloodingP.Sender -> SimpleSendC;

   components new AMReceiverC(AM_FLOODING);
   FloodingP.Receive -> AMReceiverC;
}