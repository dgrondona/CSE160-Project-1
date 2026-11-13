#include "../../includes/socket.h"

configuration TransportTestC{
   provides interface TransportTest;
}

implementation{
   components TransportTestP;
   TransportTest = TransportTestP.TransportTest;

   components TransportC;
   TransportTestP.Transport -> TransportC;

   components new TimerMilliC() as appTimer;
   TransportTestP.appTimer -> appTimer;
}
