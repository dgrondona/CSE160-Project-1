# Notes
This is where I'll put my notes for design decisions and such.

## Flooding

### Duplicate detection
- **Decision:** Track seen packets as (src, seq) pairs.
- **Why:** src says where the packet came from, seq says which packet from that node it is. This protects against packets being recieved out of order and packets from different nodes having the same seq.

### Seen-table + Overflow
- **Decision:** Fixed array of 50 entries, overwrites the beginning once reaching the end
- **Why:** 50 seemed like a reasonable number. It isn't too big, and we most likely won't be overwriting entries that still have TTL. If > 50 packets are sent within the time it takes for a packet to expire, the packet may be sent a few extra times since a node thinks it's new. Since we track TTL, we won't have infinite loops.

### Sequence numbers
- **Decision:** mySeq initialized to 1, not 0.
- **Why:** We initialize the array with all 0s. Initializing mySeq at 1 makes sure we aren't automatically rejecting packets with the empty, initialized array.

### Forwarders modify only TTL
- **Decision:** src and seq are never changed in transit.
- **Why:** We keep an accurate log of what packets we've seen. Editing src and/or seq would cause problems with duplicate packets.

### Check ordering in handlePacket
- **Decision:**
- **Why:** 