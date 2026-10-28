#include "../../includes/packet.h"

module DistanceVectorP{
   provides interface DistanceVector;

   uses interface Timer<TMilli> as periodicTimer;
   uses interface Timer<TMilli> as triggerTimer;
   uses interface Timer<TMilli> as paceTimer;
   uses interface Random;
   uses interface SimpleSend as Sender;
   uses interface Receive;
   uses interface AMPacket;
   uses interface NeighborDiscovery;
}

implementation{
    pack sendPackage;

    enum {
        // The handout's INFINITY. math.h already defines INFINITY as a float, so we can't use that name.
        DV_INFINITY = 16,
        MAX_NODES = 256, // Node IDs are at most 255, so the table is indexed directly by ID.
        MAX_NEIGHBORS = 32, // Same as NeighborDiscoveryP.
        DV_MAX_ENTRIES = (PACKET_MAX_PAYLOAD_SIZE - 1) / 2, // 1 byte count, then 2 bytes per entry. 9 entries.
        DV_PERIOD = 5000,
        PERIOD_JITTER = 1000,
        TRIGGER_DELAY = 500,
        TRIGGER_JITTER = 1000,
        PACE_PERIOD = 100,
        PACE_JITTER = 100,
        ROUTE_TIMEOUT_ROUNDS = 6,
        WITHDRAW_ROUNDS = 4
    };

    enum {
        RT_INVALID = 0, // 0 so a freshly zeroed table starts out empty.
        RT_VALID = 1,
        RT_WITHDRAWN = 2
    };

    typedef struct routeEntry {
        uint8_t nextHop;
        uint8_t cost;
        uint8_t state;
        uint8_t age; // Rounds since the next hop last advertised this route.
        uint8_t hold; // Rounds left to advertise a withdrawn route as DV_INFINITY.
    }routeEntry;

    routeEntry table[MAX_NODES];

    // Where we are in the current advertisement round. We send one packet per paceTimer tick.
    uint16_t roundNeighbors[MAX_NEIGHBORS];
    uint8_t roundNeighborCount = 0;
    uint8_t roundNeighborIndex = 0;
    uint16_t roundDest = 1;
    bool roundActive = FALSE;
    bool rerunRound = FALSE;

    void install(uint16_t dest, uint16_t nextHop, uint8_t cost) {
        table[dest].nextHop = nextHop;
        table[dest].cost = cost;
        table[dest].state = RT_VALID;
        table[dest].age = 0;
        table[dest].hold = 0;

        dbg(ROUTING_CHANNEL, "route installed! dest: %d, next hop: %d, cost: %d\n", dest, nextHop, cost);
    }

    // Only start the withdrawal interval when leaving VALID, so repeated DV_INFINITY adverts can't keep restarting it.
    void withdraw(uint16_t dest) {
        if (table[dest].state == RT_VALID) {
            table[dest].state = RT_WITHDRAWN;
            table[dest].cost = DV_INFINITY;
            table[dest].hold = WITHDRAW_ROUNDS;

            dbg(ROUTING_CHANNEL, "route withdrawn! dest: %d\n", dest);
        }
    }

    // If a trigger is already waiting, it will pick up this change too.
    void scheduleTrigger() {
        if (!call triggerTimer.isRunning()) {
            call triggerTimer.startOneShot(TRIGGER_DELAY + (call Random.rand16() % TRIGGER_JITTER));
        }
    }

    // Apply one advertised (dest, cost) from neighbor. Return true if the table changed.
    bool updateRoute(uint16_t dest, uint16_t neighbor, uint8_t cost) {
        routeEntry* route = &table[dest];
        uint8_t candidate;

        // Never replace the self-route.
        if (dest == TOS_NODE_ID) {
            return FALSE;
        }

        // cost was validated to be <= DV_INFINITY, so cost + 1 can't overflow and is at most DV_INFINITY.
        if (cost == DV_INFINITY) {
            candidate = DV_INFINITY;
        } else {
            candidate = cost + 1;
        }

        // An update from our current next hop is taken whether it's better or worse.
        if (route->state == RT_VALID && route->nextHop == neighbor) {
            if (candidate < DV_INFINITY) {
                route->age = 0;

                if (candidate != route->cost) {
                    dbg(ROUTING_CHANNEL, "route cost changed! dest: %d, next hop: %d, cost: %d -> %d\n", dest, neighbor, route->cost, candidate);
                    route->cost = candidate;
                    return TRUE;
                }
                return FALSE;
            }

            withdraw(dest);
            return TRUE;
        }

        // From anyone else, only take a finite route if we have none or it's strictly better.
        // Equal cost keeps the current next hop, and installing over a withdrawn route cancels the withdrawal.
        if (candidate < DV_INFINITY && (route->state != RT_VALID || candidate < route->cost)) {
            install(dest, neighbor, candidate);
            return TRUE;
        }

        return FALSE;
    }

    uint8_t advertisedCost(uint16_t dest, uint16_t neighbor) {
        if (dest == TOS_NODE_ID) {
            return 0;
        }

        if (table[dest].state == RT_WITHDRAWN) {
            return DV_INFINITY;
        }

        // Poison reverse: tell our next hop we can't reach dest, so it never routes dest back through us.
        if (table[dest].nextHop == neighbor) {
            return DV_INFINITY;
        }

        return table[dest].cost;
    }

    void startRound() {
        // If a round is already going, let it finish and run another one right after.
        if (roundActive) {
            rerunRound = TRUE;
            return;
        }

        // Snapshot the neighbor list so it can't change under us mid round.
        roundNeighborCount = call NeighborDiscovery.getNeighbors(roundNeighbors, MAX_NEIGHBORS);
        if (roundNeighborCount == 0) {
            return;
        }

        roundNeighborIndex = 0;
        roundDest = 1;
        roundActive = TRUE;

        call paceTimer.startOneShot(PACE_PERIOD + (call Random.rand16() % PACE_JITTER));
    }

    void endRound() {
        roundActive = FALSE;

        if (rerunRound) {
            rerunRound = FALSE;
            startRound();
        }
    }

    void handleAdvertisement(uint16_t neighbor, pack msg) {
        int i;
        uint8_t count = msg.payload[0];
        bool changed = FALSE;

        // Only take routes from neighbors we can reach both ways.
        if (!call NeighborDiscovery.isNeighbor(neighbor)) {
            dbg(ROUTING_CHANNEL, "dv dropped! not a neighbor: %d\n", neighbor);
            return;
        }

        // Validate the whole packet before using any of it.
        if (count > DV_MAX_ENTRIES) {
            dbg(ROUTING_CHANNEL, "dv dropped! from: %d, bad count: %d\n", neighbor, count);
            return;
        }

        for (i = 0; i < count; i++) {
            if (msg.payload[2 + 2 * i] > DV_INFINITY) {
                dbg(ROUTING_CHANNEL, "dv dropped! from: %d, bad cost: %d\n", neighbor, msg.payload[2 + 2 * i]);
                return;
            }
        }

        for (i = 0; i < count; i++) {
            if (updateRoute(msg.payload[1 + 2 * i], neighbor, msg.payload[2 + 2 * i])) {
                changed = TRUE;
            }
        }

        if (changed) {
            scheduleTrigger();
        }
    }

    command void DistanceVector.start(){
        uint16_t jitter = call Random.rand16() % PERIOD_JITTER;

        // The self-route is always valid with cost 0.
        table[TOS_NODE_ID].nextHop = TOS_NODE_ID;
        table[TOS_NODE_ID].cost = 0;
        table[TOS_NODE_ID].state = RT_VALID;

        call periodicTimer.startOneShot(DV_PERIOD + jitter);
        dbg(ROUTING_CHANNEL, "dv started! first round in: %d\n", DV_PERIOD + jitter);
    }

    command bool DistanceVector.lookup(uint16_t dest, uint16_t* nextHop, uint8_t* cost){
        if (dest >= MAX_NODES || table[dest].state != RT_VALID) {
            return FALSE;
        }

        *nextHop = table[dest].nextHop;
        *cost = table[dest].cost;
        return TRUE;
    }

    command void DistanceVector.printRouteTable(){
        int i;
        dbg(ROUTING_CHANNEL, "Routing table for node %d\n", TOS_NODE_ID);
        dbg(ROUTING_CHANNEL, "Dest  NextHop  Cost  State\n");

        for (i = 1; i < MAX_NODES; i++) {
            if (i == TOS_NODE_ID) {
                dbg(ROUTING_CHANNEL, "%-5d -        0     SELF\n", i);
            } else if (table[i].state == RT_VALID) {
                dbg(ROUTING_CHANNEL, "%-5d %-8d %-5d VALID\n", i, table[i].nextHop, table[i].cost);
            } else if (table[i].state == RT_WITHDRAWN) {
                dbg(ROUTING_CHANNEL, "%-5d -        INF   WITHDRAWN\n", i);
            }
        }
    }

    // A new neighbor is a direct route with cost 1.
    event void NeighborDiscovery.neighborAdded(uint16_t id){
        if (id >= MAX_NODES || id == TOS_NODE_ID) {
            return;
        }

        install(id, id, 1);
        scheduleTrigger();
    }

    // Stop using a dead neighbor as a next hop. Other neighbors' next adverts give us any alternative.
    event void NeighborDiscovery.neighborRemoved(uint16_t id){
        int i;
        bool changed = FALSE;

        for (i = 1; i < MAX_NODES; i++) {
            if (i != TOS_NODE_ID && table[i].state == RT_VALID && table[i].nextHop == id) {
                withdraw(i);
                changed = TRUE;
            }
        }

        if (changed) {
            scheduleTrigger();
        }
    }

    event void periodicTimer.fired(){
        int i;

        for (i = 1; i < MAX_NODES; i++) {
            if (i == TOS_NODE_ID) {
                continue;
            }

            // Only the next hop's adverts reset age, so each route expires on its own.
            if (table[i].state == RT_VALID) {
                table[i].age++;

                if (table[i].age > ROUTE_TIMEOUT_ROUNDS) {
                    dbg(ROUTING_CHANNEL, "route expired! dest: %d, next hop: %d\n", i, table[i].nextHop);
                    withdraw(i);
                }
            } else if (table[i].state == RT_WITHDRAWN) {
                table[i].hold--;

                if (table[i].hold == 0) {
                    table[i].state = RT_INVALID;
                    dbg(ROUTING_CHANNEL, "route reclaimed! dest: %d\n", i);
                }
            }
        }

        startRound();

        // Pick a new random period every round.
        call periodicTimer.startOneShot(DV_PERIOD + (call Random.rand16() % PERIOD_JITTER));
    }

    event void triggerTimer.fired(){
        startRound();
    }

    // Build and send one advertisement packet to the current neighbor, then move the cursor forward.
    event void paceTimer.fired(){
        uint16_t neighbor = roundNeighbors[roundNeighborIndex];
        uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
        uint8_t count = 0;
        memset(payload, 0, PACKET_MAX_PAYLOAD_SIZE);

        while (roundDest < MAX_NODES && count < DV_MAX_ENTRIES) {
            if (table[roundDest].state != RT_INVALID) {
                payload[1 + 2 * count] = roundDest;
                payload[2 + 2 * count] = advertisedCost(roundDest, neighbor);

                dbg(DV_CHANNEL, "advertising to: %d, dest: %d, cost: %d\n", neighbor, roundDest, payload[2 + 2 * count]);
                count++;
            }
            roundDest++;
        }
        payload[0] = count;

        // The last packet for a neighbor can come up empty if the table filled the one before it exactly.
        if (count > 0) {
            makePack(&sendPackage, TOS_NODE_ID, neighbor, 1, PROTOCOL_DV, 0, payload, PACKET_MAX_PAYLOAD_SIZE);

            // A failed send means SimpleSend's queue is full. Stop here, the next round covers it.
            if (call Sender.send(sendPackage, neighbor) != SUCCESS) {
                dbg(ROUTING_CHANNEL, "dv send failed! round stopped at neighbor: %d\n", neighbor);
                endRound();
                return;
            }

            dbg(DV_CHANNEL, "advertisement sent! to: %d, entries: %d\n", neighbor, count);
        }

        // Done with this neighbor, move on to the next one.
        if (roundDest >= MAX_NODES) {
            roundNeighborIndex++;
            roundDest = 1;
        }

        if (roundNeighborIndex >= roundNeighborCount) {
            endRound();
            return;
        }

        call paceTimer.startOneShot(PACE_PERIOD + (call Random.rand16() % PACE_JITTER));
    }

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
        if (len == sizeof(pack)) {
            pack* myMsg = (pack*) payload;

            // The advertising neighbor comes from the link layer source, not the pack's src.
            handleAdvertisement(call AMPacket.source(msg), *myMsg);
            return msg;
        }
        dbg(ROUTING_CHANNEL, "Unknown Packet Type %d\n", len);
        return msg;
    }
}