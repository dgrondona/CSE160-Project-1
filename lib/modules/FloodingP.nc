#include "../../includes/packet.h"

module FloodingP{
   provides interface Flooding;

   uses interface SimpleSend as Sender;
}

implementation{
    command error_t Flooding.flood(uint16_t destination, uint8_t *payload){
        dbg(FLOODING_CHANNEL, "flood called: %d\n", destination);
        return SUCCESS;
    }

    command error_t Flooding.handlePacket(pack msg){
        dbg(FLOODING_CHANNEL, "handlePacket called!\n");
        return SUCCESS;
    }
}