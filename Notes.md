# Project 1 Notes

Design decisions for flooding and neighbor discovery.

---

## Architecture

### Module structure
- **Decision:** Two modules, Flooding and NeighborDiscovery, each split into interface / module (P) / configuration (C), wired into Node through NodeC.
- **Why:** We can break up larger problems like this into smaller components. We write the logic for Flooding and Neighbor Discovery as seperate modules to break things up and wire them into Node.c which manages them all.

### Routing packets to the right module
- **Decision:** When we recieve a packet, we check it's destination address. If the destination is AM_BROADCAST_ADDR, we route it to NeighborDiscover, if it's not, we route it to Flooding.
- **Why:** We know that AM_BROADCAST_ADDR is not a valid neighbor address, so it's safe from collisions. That means we can broadcast neighbor discovery with that as the destination and not have to make a whole new protocol.

### Node no longer sends anything itself
- **Decision:** We could remove a lot of things from Node.nc since it no longer needs to send packets itself. We moved all packet sending to the modules we built, so sending packets was unused and unnecissary to have.

---

## Flooding

### Duplicate detection key
- **Decision:** Track seen packets as (src, seq) pairs.
- **Why:** src says where the packet came from, seq says which packet from
  that node it is.
- **Alternative rejected:** seq alone would make things confusing since many nodes could send out packets of the same sequence, thus most of them would be ignored. We could also use src alone, but then we couldn't keep track of multiple packets coming from the same src.

### Seen-table structure
- **Decision:** Fixed array of 50 entries used as a circular buffer.
- **Why 50:** Seemed reasonable. It's a tunable. The array should be bigger than the number of packets we expect to be sent within the lifetime of 1 packet.
- **Alternative rejected:** Track only the highest seq seen per source. Packets arriving out of order would make it so the earlier packets are dropped.

### Overflow behavior
- **Decision:** Overwrite the oldest entry (the one `seenIndex` points at).
- **Risk:** More than 50 packets within one packet's lifetime could evict an entry that's still circulating.
- **Why it's safe anyway:** Worst case, a packet loops a few extra times, but due to the TTL, the packet cannot loop indefinitly.

### Sequence numbers start at 1
- **Decision:** `mySeq` initialized to 1.
- **Why:** A freshly initialized seenList contains all 0s. This could mess with our packets if we started them at 0. For that reason, we initialize mySeq at 1.

### Forwarders modify only TTL
- **Decision:** src and seq are never changed in transit.
- **Why:** If they were modified, then we wouldn't really know where the packet originated from.

### Order of checks in handlePacket
- **Decision:** seen -> record -> destination -> TTL -> forward.
- **Why seen before destination:** If we check if we are the destination first, we could accept multiple packets at once if, say, 2 packets come from 2 different nodes. We first need to check if it's a duplicate before we can check what the destination is.
- **Why destination before TTL:** If we check TTL first, we may drop the packet at the destination, so we check if we are the destination before we check and decrement the TTL.

### TTL decrement
- **Decision:** Decrement first, then drop if zero.
- **Why:** If we send a packet with, let's say, a TTL of 1, it should do 1 hop, then drop. The node recieves it, decrements it, then drops it. That means it did 1 hop. If we decremented second, it would've done a second hop.

### Ping replies
- **Decision:** When the destination recieves the packet, it sends a reply to confirm that it got the packet.
- **Why no reply to replies:** We don't want replies to replies, or we would just be sending packets back and forth forever, so PINGREPLY doesn't get a reply to it.

---

## Neighbor Discovery

### No new packet type
- **Decision:** Reuse PROTOCOL_PING / PROTOCOL_PINGREPLY, no new protocol
  constants.
- **Why:** The instructions say to not use a new packet type.

### Probe design
- **Decision:** PING with dest = AM_BROADCAST_ADDR and TTL = 1, sent every
  timer period.
- **Why TTL 1:** This makes it so a packet only ever reaches its neighbors and doesn't go beyond.

### Broadcast replies
- **Decision:** Replies are PINGREPLY, dest = AM_BROADCAST_ADDR, TTL 1.
- **Why:** Putting a real destination would cause all of the nodes the packet is not addressed to to drop it. Regular addresses are routed through Flooding. AM_BROADCAST_ADDR isn't a valid address, so we can route packets with that address through neighbor discovery.

### Neighbor table
- **Decision:** Array of {addr, missedCount}, MAX_NEIGHBORS = 32, plus `neighborCount`. List kept packed with no gaps.
- **Why 32:** 32 is as safe upper bound. From the topologies we have, there are none with more than 32 nodes. There can't be more neighbors than there are other nodes in the network.
- **Why a count instead of scanning all slots:** We could confuse an empty slot, or a non zeroed slot with a real neighbor, so we need to keep track with a counter.

### Aging / dropout
- **Decision:** Every timer fire increments each neighbor's missedCount, a reply resets it to 0. Drop when missedCount > MAX_MISSED (3).
- **Why:** We want to know when a neighbor has dropped out so we can keep a list that reflects the network as it is now.

### Removing from the table
- **Decision:** Iterate backward, copy the last entry into slot i, decrement
  the count.
- **Why backward:** We move backwards so that if the slot from the end of the array that we move to i is also dead, we don't accidentally miss it. Going backwards ensures we don't miss anything and only have to loop through once.

### Timer period
- **Decision:** DISCOVERY_PERIOD = 3457 ms (prime) + random jitter in [0, 607).
- **Why:** We add a random jitter so that packets are offset. We also make the discovery period prime so it doesn't line up every n cycles.
- **Alternative rejected:** Exponential backoff when no replies arrive.

---