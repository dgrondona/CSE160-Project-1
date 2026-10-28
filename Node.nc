/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;

   uses interface NeighborDiscovery;
   uses interface Flooding;
   uses interface DistanceVector;
   uses interface IP;

   uses interface CommandHandler;
}

implementation{

   event void Boot.booted(){
      call AMControl.start();

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
         call NeighborDiscovery.startDiscovery();
         call DistanceVector.start();
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   // Ping sits on top of IP. Each module receives its own AM type, so Node doesn't receive packets itself.
   event void IP.receive(pack msg){
      if (msg.protocol == PROTOCOL_PING) {
         dbg(GENERAL_CHANNEL, "ping received! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);

         // Reply with a routed packet, echoing the original message.
         call IP.send(msg.src, PROTOCOL_PINGREPLY, MAX_TTL, (uint8_t*) msg.payload);
      } else if (msg.protocol == PROTOCOL_PINGREPLY) {
         dbg(GENERAL_CHANNEL, "ping reply received! src: %d, dest: %d, seq: %d, TTL: %d\n", msg.src, msg.dest, msg.seq, msg.TTL);
      }
   }

   // DV is the one that needs these.
   event void NeighborDiscovery.neighborAdded(uint16_t id){}

   event void NeighborDiscovery.neighborRemoved(uint16_t id){}

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT \n");
      call IP.send(destination, PROTOCOL_PING, MAX_TTL, payload);
   }

   event void CommandHandler.pingTTL(uint16_t destination, uint8_t TTL, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT TTL: %d\n", TTL);
      call IP.send(destination, PROTOCOL_PING, TTL, payload);
   }

   event void CommandHandler.printNeighbors(){
      call NeighborDiscovery.printNeighbors();
   }

   event void CommandHandler.printRouteTable(){
      call DistanceVector.printRouteTable();
   }

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

}
