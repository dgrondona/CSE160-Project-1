# Introduction
This skeleton code is the basis for the CSE160 network project. Additional documentation
on what is expected will be provided as the school year continues.

# General Information
## Data Structures
There are two data structures included into the project design to help with the
assignment. See dataStructures/interfaces/ for the header information of these
structures.

* **Hashmap** - This is for anything that needs to retrieve a value based on a key.

* **List** - The list is design to have pushfront, pushback capabilities. For the most part,
you can stick with an array or even a QueueC (FIFO) which are more robust.

## General Libraries
/lib/interfaces

* **CommandHandler** - CommandHandler is what interfaces with TOSSIM. Commands are
sent to this function, and based on the parameters passed, an event is fired.
* **SimpleSend** - This is a wrapper of the lower level sender in TinyOS. The features
included is a basic queuing mechanism and some small delays to prevent collisions. Do
not change the delays. You can duplicate SimpleSendC to use a different AM type or
possibly rewire it.
* **Transport** - There is only the interface of Transport included. The actual
implementation of the Transport layer is left to the student as an exercise. For
CSE160 this will be Project 3 so don't worry about it now.

## Noise
/noise/

This is the "noise" of the network. A heavy noised network will cause issues with
packet loss.

* **no_noise.txt** - There should be no packet loss using this model.

## Topography
/topo/

This folder contains a few example topographies of the network and how they are
connected to each other. Be sure to try additional networks when testing your code
since additional ones will be added when grading.

* **long_line.topo** - this topography is a line of 19 motes that have bidirectional
links.
* **example.topo** - A slightly more complex connection

Each line has three values, the source node, the destination node, and the gain.
For now you can keep the gain constant for all of your topographies. A line written
as ```1 2 -53``` denotes a one-way connection from 1 to 2. To make it bidirectional
include also ```2 1 -53```.

# Running Simulations
The following is an example of a simulation script.
```
from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("long_line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);

    # After sending a ping, simulate a little to prevent collision.
    s.runTime(1);
    s.ping(1, 2, "Hello, World");
    s.runTime(1);

    s.ping(1, 10, "Hi!");
    s.runTime(1);

if __name__ == '__main__':
    main()
```

# Project 3: Reliable Transport

Design notes, the state table and the timer policy are in `Project3Notes.md`. The one-page design and the
discussion answers are in `Project3Report.pdf`.

## Build and run
```
docker run --rm -v "$PWD":/home/cse160 -w /home/cse160 ucmercedandeslab/tinyos_debian bash -lc 'make micaz sim && python transportTest.py basic'
```
Run any scenario with `python transportTest.py <scenario> [seed]`. The seed defaults to 160, and a scenario
gives the same log every run with the same seed.

## Header sizes
28 byte payload = 8 byte IP header + 8 byte transport header + **12 data bytes** per segment.

## Constants
| Name | Value | Where |
|---|---|---|
| `TCP_MAX_DATA` | 12 | `includes/tcp.h` |
| `SOCKET_BUFFER_SIZE` | 128 send, 128 receive per record | `includes/socket.h` |
| `MAX_NUM_OF_SOCKETS` | 10 | `includes/socket.h` |
| `SEND_WINDOW` | 48 (4 segments) | `TransportP.nc` |
| `RTO` | 3000 ms, fixed | `TransportP.nc` |
| `MAX_RETRIES` | 6 | `TransportP.nc` |
| `TIME_WAIT_PERIOD` | 21000 ms | `TransportP.nc` |
| `TICK_PERIOD` | 250 ms | `TransportP.nc` |
| `MAX_SESSIONS` / `MAX_LISTENERS` | 4 / 2 | `TransportTestP.nc` |

Sequence numbers are 16 bits with wraparound-safe compares, so any transfer size up to 65535 bytes works.

## Test commands (TestSim.py)
| Method | Sent to | Payload |
|---|---|---|
| `testServer(serverAddress, listenPort)` | serverAddress | port |
| `testClient(clientAddress, serverAddress, srcPort, destPort, transferBytes)` | clientAddress | server, srcPort, destPort, bytes (2, big endian) |
| `clientClose(clientAddress, serverAddress, srcPort, destPort)` | clientAddress | server, srcPort, destPort |
| `pauseServer(serverAddress, listenPort)` | serverAddress | port, 1 |
| `resumeServer(serverAddress, listenPort)` | serverAddress | port, 0 |
| `dropRule(address, kind, nth)` | a forwarding node | kind, nth |

`cmdTestServer`, `cmdTestClient` and `cmdClientClose` are aliases with the handout's names.

- Test byte k is `k % 256`. The server checks every byte it reads and prints `server result! total, mismatches`.
  The client prints `client result! accepted, total`, and transport's `RELEASE` line prints how many bytes were acked.
- Pausing applies to every connection the listener on that port accepted, and to ones it accepts later.
- `dropRule` kinds (`DROP_*` in `tcp.h` and TestSim): 1 DATA, 2 ACK, 3 SYN, 4 SYNACK, 5 HANDSHAKE_ACK,
  6 WINDOW_UPDATE, 7 FIN, 8 FINAL_ACK. The node drops the nth forwarded segment of that kind once and logs `TEST_DROP`.
  It only runs on forwarded packets and is off unless a rule is set.
- TestSim reuses one command message, so leave at least a second of sim time between commands.

Channels: `transport` for engine events, `Project3TGen` for app progress (accepted, consumed, results).

## Tests
All scenarios use `line.topo` (1-2-3-4) with the client on 1:10, the server on 4:20 and drop rules on node 2.
Each one checks route tables and pings 1 to 4 before starting transport. `noisy` uses `meyer-heavy.txt`, everything
else uses `no_noise.txt`. Results below are with seed 160.

| Scenario | What it does | Observed |
|---|---|---|
| `basic` | 300 bytes, close | total 300, 0 mismatches, both sides close SUCCESS |
| `baseline` | 1030 bytes, so the last segment is 10 bytes | total 1030, 0 mismatches, `outstanding` up to 48, closes SUCCESS |
| `dataloss` | drop the 3rd DATA segment | 1 timeout, Go-Back-N resend from the gap, 0 mismatches |
| `ackloss` | drop the 2nd ACK | the next cumulative ACK covers it, no retransmission, 0 mismatches |
| `acklast` | drop the ACK of the last data segment | timeout, resend, node 4 drops the repeat (`expected`) and ACKs again, 0 mismatches |
| `flow` | pause the server, resume, drop the first WINDOW_UPDATE | window goes to 0, sender probes with 1 byte, a probe's ACK reopens it, total 400, 0 mismatches |
| `synloss` | drop the SYN | 1 `SYN_RETX`, one record on each side |
| `synackloss` | drop the SYN-ACK | `SYNACK_RETX` and `SYN_RETX`, node 4 logs `SYN_RX duplicate`, one record |
| `hsackloss` | drop the final handshake ACK | the first data segment carries the same ACK, so node 4 logs `ACK_RX handshake` and goes ESTABLISHED |
| `finalackloss` | drop the final close ACK | node 4 logs `FIN_RETX`, node 1 in TIME_WAIT logs `FIN_RX duplicate` and ACKs again, both release |
| `nolistener` | connect to 4:21 where nobody listens | 6 `SYN_RETX`, `FAILED in SYN_SENT`, released, `client connect failed` |
| `unreachable` | 1030 bytes, cut link 2-3 after 15 s | 7 timeouts, `FAILED in ESTABLISHED`, `RELEASE acked: 144`, close done FAIL, `accepted: 272` (the other 128 were still in the send buffer) |
| `noisy` | 1030 bytes over `meyer-heavy.txt` | 19 timeouts, 66 resent segments, total 1030, 0 mismatches |
| `twoconn` | clients on 1:10 and 2:11 both to 4:20, 600 bytes each | node 4 runs two records from one listener, both total 600, 0 mismatches, all close SUCCESS |

Even `no_noise.txt` loses a few packets to collisions, since nodes 1 and 3 both transmit into node 2. `basic` has 4
timeouts with no drop rule, and every one recovers.
