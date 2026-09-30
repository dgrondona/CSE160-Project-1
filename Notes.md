# Notes
This is where I'll put my notes for design decisions and such.

## Flooding

### Duplicate detection key
- **Decision:** Track seen packets as (src, seq) pairs.
- **Why:** src says where the packet came from, seq says which packet
  from that node it is.

### Seen-table structure
- **Decision:** Fixed array of 50 entries, circular — overwrites the
  oldest after reaching the end.
- **Why:** Seemed reasonable; adjustable.

### Overflow behavior
- **Decision:** Overwrite the oldest entry.
- **Risk:** If >50 packets pass through within one packet's lifetime,
  an entry could be evicted while still live.
- **Why it's safe:** The worst that can happen is packet loops. In that case, we won't get infinite loops due to TTL.

### Sequence numbers start at 1
- **Decision:** mySeq initialized to 1, not 0.
- **Why:** When we initialize the array to 0, we would think we had already seen things of 0 seq.