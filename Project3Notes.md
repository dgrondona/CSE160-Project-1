# Project 3 Notes

Design decisions for reliable transport. Build, commands and test results are in the README.

---

## Layering

### Transport sits on IP only
- **Decision:** TransportP uses the `IP` interface with `PROTOCOL_TCP`. Node and TransportTest never touch the radio.
- **Why:** Every segment, including a retransmission, gets routed fresh with a full TTL, so a DV route change just changes the next hop. Nothing in transport knows the topology.

### Test app is its own module
- **Decision:** TransportTestP is the producer and consumer. It only calls the `Transport` commands (`socket`, `bind`, `listen`, `accept`, `connect`, `write`, `read`, `close`).
- **Why:** The app can pause, check bytes and count results without reaching into socket memory, and Project 4 can reuse the same calls.

---

## Segment header

| Field | Bytes | Notes |
|---|---|---|
| srcPort, destPort | 1 + 1 | Addresses come from the IP header. |
| seq | 2 | First byte of the segment, or the SYN/FIN's sequence number. |
| ack | 2 | Next byte expected. Only valid when the ACK flag is set. |
| window | 1 | 0 to 128, free space in the receive buffer. |
| flagsLen | 1 | SYN/ACK/FIN in the high 4 bits, data length (0 to 12) in the low 4. |

- 28 byte payload (`TOSH_DATA_LENGTH`) = 8 IP header + 8 TCP header + **12 data bytes**. `tcpSizeCheck` in `tcp.h` fails the build if the struct doesn't fill the IP payload exactly.
- nx types are big endian with no padding.
- seq and ack are separate fields, so a SYN-ACK carries both with no special cases.

---

## Connection record (`socket_store_t`)

- **Decision:** One static table of 10 records. Positions (`lastAck`, `lastSent`, `lastWritten`, `lastRead`, `nextExpected`) are 16 bit sequence numbers, not buffer indexes. A byte with sequence number s lives at `buff[s % 128]`.
- **Why:** 128 divides 65536, so the index stays right across wraparound, and `seqLT`/`seqLEQ` compare by signed distance. No transfer size limit below 65535.
- Lookups match local port, remote address and remote port. The local address is always this node, so that's the full tuple. Listeners only take new SYNs, so a listener never matches an existing connection.
- Each accepted connection gets its own record with `parent` set to the listener. The listener stays in LISTEN.
- If a connection's FIN arrives before the app accepts it, `accept()` posts a task that signals `remoteClosed`, so the app still learns about it.
- `bind` refuses a port that any record still holds, TIME_WAIT included, so a tuple can't be reused while old segments might still be around.

### Sequence numbers
- ISN is `getNow() / 4`, so a new instance of a tuple starts somewhere else in sequence space.
- SYN and FIN each take one sequence number. A pure ACK takes none.

---

## State table

| State | Event | Action | Next |
|---|---|---|---|
| CLOSED | `connect()` | send SYN, start RTO | SYN_SENT |
| SYN_SENT | SYN-ACK with ack = ISN+1 | send ACK, signal `connectDone(SUCCESS)` | ESTABLISHED |
| SYN_SENT | timeout | resend SYN; after 6 retries signal `connectDone(FAIL)` | SYN_SENT / released |
| LISTEN | SYN for a new tuple | allocate record, send SYN-ACK, start RTO | new record in SYN_RCVD |
| SYN_RCVD | same SYN again | resend SYN-ACK, no new record | SYN_RCVD |
| SYN_RCVD | ACK of our SYN (pure ACK or data) | stop timer | ESTABLISHED |
| SYN_RCVD | timeout | resend SYN-ACK; after 6 retries release | SYN_RCVD / released |
| ESTABLISHED | SYN-ACK again (our ACK was lost) | send ACK | ESTABLISHED |
| ESTABLISHED | `close()` | FIN after every byte is acked | FIN_WAIT_1 |
| ESTABLISHED | in-order FIN | ACK, signal `remoteClosed` | CLOSE_WAIT |
| FIN_WAIT_1 | ACK of FIN | | FIN_WAIT_2 |
| FIN_WAIT_1 | FIN | ACK | CLOSING |
| FIN_WAIT_2 | FIN | ACK, signal `closeDone(SUCCESS)` | TIME_WAIT |
| FIN_WAIT_2 | no FIN for 21 s (data restarts it) | release, signal `closeDone(FAIL)` | CLOSED |
| CLOSING | ACK of FIN | signal `closeDone(SUCCESS)` | TIME_WAIT |
| CLOSE_WAIT | `close()` | FIN after every byte is acked | LAST_ACK |
| LAST_ACK | ACK of FIN | release, signal `closeDone(SUCCESS)` | CLOSED |
| TIME_WAIT | FIN again | ACK again, restart linger | TIME_WAIT |
| TIME_WAIT | linger over | release | CLOSED |
| any connected | 6 retries with no valid ACK | release, signal FAIL | CLOSED |

Course simplifications: no RST, no simultaneous open, no piggybacked or delayed ACKs, and the app finds accepted connections by polling `accept()` instead of an event.

---

## Timers

- **Decision:** One 250 ms periodic tick in TransportP. Each record has a `deadline`, so a record has one logical timer for retransmit, window probe or TIME_WAIT depending on its state.
- **Why:** Ten records can't each take a TimerMilliC, and a deadline per record means an old timer can't fire on data that's already acked. A valid ACK restarts the deadline, or clears it when nothing is outstanding.

| Constant | Value | Why |
|---|---|---|
| `RTO` | 3000 ms, fixed | 3 hops each way with up to 300 ms of SimpleSend delay per hop keeps the RTT under about 2 s. |
| `MAX_RETRIES` | 6 | A dead peer fails in about 21 s. Any valid ACK resets the count. |
| `TIME_WAIT_PERIOD` | 21000 ms | `RTO * (MAX_RETRIES + 1)`, longer than every FIN retry the peer could still send. |

- A refused `IP.send` (no route, full queue) leaves `lastSent` alone and the next tick tries again. Only a valid ACK frees bytes.

---

## Reliability

- **Sender:** `SEND_WINDOW` is 48 bytes (4 segments). It sends while `outstanding < min(SEND_WINDOW, peerWindow)`, using a shorter segment when only part of the window is open.
- **Receiver:** in order only. Anything else is dropped but still gets the current cumulative ACK.
- **Timeout:** Go-Back-N. Everything from `lastAck` is resent in order, at most 4 segments.
- **ACKs:** every data segment and FIN gets an ACK, even one that was dropped. A pure ACK never does, so there are no ACK loops.
- ACKs below `lastAck` or above `lastSent` are ignored, so an old ACK can't move anything backward or free data twice.
- A FIN only counts once every byte before it has arrived. An early FIN is dropped and retransmitted later.

---

## Flow control

- Window = 128 minus bytes received but not read yet.
- `write()` only takes what fits in 128 minus unacked and queued bytes. The app keeps its own offset and offers the rest later.
- **Zero window:** with nothing outstanding and a 0 window, the sender sends a 1 byte probe every RTO. The first logs `WINDOW_PROBE`. After that the probe byte is outstanding, so resends go through the normal timeout and log `TIMEOUT` and `DATA_RETX len: 1`. The receiver drops it if there's still no room and ACKs it with the current window, so a lost window update is covered. A probe's ACK resets the retry count, so a paused receiver never counts as a dead one.
- **Window update:** when a `read()` takes the window from under 12 to 12 or more, the receiver sends an ACK on its own.
- The test consumer reads 24 bytes per 250 ms tick, separately from packet arrival. Pausing it just skips the read.

---

## Test hooks

### Drop rule
- **Decision:** `shouldDropForTest` in IPP runs on forwarded packets only, so the rule goes on an intermediate node. It matches the nth segment of a kind, drops it once, logs `TEST_DROP` and turns itself off.
- **Why kinds instead of sequence numbers:** ISNs come from the clock, so a test script can't know them ahead of time.
- It checks the protocol and length before reading the header. It tracks every forwarded segment, so it knows a WINDOW_UPDATE (first ACK above 0 after a 0) or a FINAL_ACK (the pure ACK after both FINs) even when the rule is set mid-connection.

### Pause
- Set per listen port and inherited by every connection the listener accepts, including later ones. The script never learns the server's fd, so it can't target one that way.

### Repeatable runs
- `transportTest.py` seeds TOSSIM's RNG (default 160). Without a seed, collision timing changes every run.
- TestSim reuses one command message, so scripts wait a second between commands. Two commands sent at the same moment overwrite each other.
- `moteOff` drains the event queue early in these runs, so the failure test cuts a link with `removeLink` instead.

---

## What the logs showed

- Even with `no_noise.txt` there are natural losses: on the line, nodes 1 and 3 both transmit into node 2, so data and ACKs collide there. `basic` has 4 timeouts with no drop rule and recovers each time.
- With the window open, `outstanding` sits at 48 for most of a transfer.

---

## Demo cheat sheet

Run a scenario into a log, then trace it with grep.
```
python transportTest.py <scenario> > run.log
grep STATE run.log                                   # every state transition, both sides
grep -E "TEST_DROP|TIMEOUT|RETX|dropped" run.log     # a loss and its recovery (dataloss, acklast)
grep -E "buffered|wnd" run.log                       # receive buffer occupancy and the window (flow)
grep -E "ZERO_WINDOW|WINDOW_PROBE|WINDOW_UPDATE|TEST_DROP|len: 1," run.log   # zero window recovery (flow)
grep "(4)" run.log                                   # one node's view only
```
