#include "../../includes/packet.h"
#include "../../includes/socket.h"

configuration TransportC{
   provides interface Transport;
}

implementation{
   components TransportP;
   Transport = TransportP.Transport;

   // Transport only talks to IP. Every segment, including retransmissions, gets routed fresh.
   components IPC;
   TransportP.IP -> IPC;

   components new TimerMilliC() as tickTimer;
   TransportP.tickTimer -> tickTimer;
}
