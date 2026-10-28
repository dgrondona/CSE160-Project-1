#include "../../includes/packet.h"
#include "../../includes/am_types.h"

configuration IPC{
   provides interface IP;
}

implementation{
   components IPP;
   IP = IPP.IP;

   components new SimpleSendC(AM_IP);
   IPP.Sender -> SimpleSendC;

   components new AMReceiverC(AM_IP);
   IPP.Receive -> AMReceiverC;

   components DistanceVectorC;
   IPP.DistanceVector -> DistanceVectorC;
}