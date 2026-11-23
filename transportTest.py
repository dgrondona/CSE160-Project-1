import sys
from TestSim import TestSim

# Every scenario runs on line.topo (1-2-3-4). The client is 1:10, the server is 4:20,
# and drop rules go on node 2, which forwards both directions.
CLIENT = 1
SERVER = 4
DROPPER = 2
CLIENT_PORT = 10
SERVER_PORT = 20

# Fixed so every run of a scenario gives the same log. Pass a second argument to try another seed.
SEED = 160

def main():
    scenario = "basic";
    if len(sys.argv) > 1:
        scenario = sys.argv[1];

    if scenario not in SCENARIOS:
        print 'Unknown scenario:', scenario;
        print 'Scenarios:', ' '.join(sorted(SCENARIOS.keys()));
        return;

    seed = SEED;
    if len(sys.argv) > 2:
        seed = int(sys.argv[2]);

    noise = "no_noise.txt";
    if scenario == "noisy":
        noise = "meyer-heavy.txt";

    s = setup(noise, seed);
    SCENARIOS[scenario](s);

def setup(noise, seed):
    # Get simulation ready to run.
    s = TestSim();
    s.t.randomSeed(seed);

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    s.loadTopo("line.topo");
    s.loadNoise(noise);
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);
    s.addChannel(s.TGEN_CHANNEL);

    # Let the routes converge first, same as lineTest.
    s.runSeconds(60);

    s.mark("route tables");
    s.routeDMP(CLIENT); s.runSeconds(1);
    s.routeDMP(SERVER); s.runSeconds(1);

    # Expected: ping reply comes back to 1, so routing works before we blame transport.
    s.mark("ping 1 -> 4");
    s.ping(CLIENT, SERVER, "Transport test");
    s.runSeconds(5);
    return s;

# TestSim reuses one message, so let each command go out before the next one.
def setDrop(s, kind, nth):
    s.mark("drop rule on 2, kind %d, occurrence %d" % (kind, nth));
    s.dropRule(DROPPER, kind, nth);
    s.runSeconds(1);

def startServer(s):
    s.mark("server on 4, port 20");
    s.testServer(SERVER, SERVER_PORT);
    s.runSeconds(2);

def startClient(s, transferBytes):
    s.mark("client on 1, port 10 -> 4:20, %d bytes" % transferBytes);
    s.testClient(CLIENT, SERVER, CLIENT_PORT, SERVER_PORT, transferBytes);

# Expected: client closes once everything is accepted. Server result is total: bytes, mismatches: 0.
# Both sides log close done. The client's comes when it enters TIME_WAIT, and it releases ~21 s later.
def closeClient(s):
    s.mark("close client");
    s.clientClose(CLIENT, SERVER, CLIENT_PORT, SERVER_PORT);
    s.runSeconds(80);

def transfer(s, transferBytes, seconds):
    startServer(s);
    startClient(s, transferBytes);
    s.runSeconds(seconds);
    closeClient(s);

# 300 bytes, then close.
def basic(s):
    transfer(s, 300, 150);

# 1030 bytes isn't a multiple of 12, so the last segment is 10 bytes.
# Expected: DATA_TX lines with outstanding above 12, server result total: 1030, mismatches: 0.
def baseline(s):
    transfer(s, 1030, 150);

# Expected: node 2 logs TEST_DROP for the 3rd data segment. Node 4 drops what comes after the gap
# and keeps ACKing the same number, then node 1 times out and resends from the gap.
def dataloss(s):
    setDrop(s, s.DROP_DATA, 3);
    transfer(s, 300, 150);

# Expected: one ACK from 4 is dropped. The next cumulative ACK covers it, or node 1 times out and
# resends, and node 4 drops the repeat as already received. No mismatches either way.
def ackloss(s):
    setDrop(s, s.DROP_ACK, 2);
    transfer(s, 300, 150);

# Drops the ACK for the last data segment, so no later ACK covers it. 31 is where it falls in the
# seeded run. Expected: node 1 times out and resends, node 4 logs "dropped! ... expected" for the
# repeat and ACKs again. Server result total: 300, mismatches: 0, so the repeat never reached the app.
def acklast(s):
    setDrop(s, s.DROP_ACK, 31);
    transfer(s, 300, 150);

# Expected: with the server paused, the buffer fills to 128, wnd goes to 0, and node 1 logs ZERO_WINDOW
# and WINDOW_PROBE instead of sending data. Later probes log as TIMEOUT and DATA_RETX with len: 1. After resume the WINDOW_UPDATE is dropped, and a probe's ACK
# reopens the window. The transfer finishes with no mismatches and nothing dropped for lack of room after resume.
def flow(s):
    startServer(s);
    s.mark("pause server");
    s.pauseServer(SERVER, SERVER_PORT);
    s.runSeconds(1);

    startClient(s, 400);
    s.runSeconds(60);

    setDrop(s, s.DROP_WINDOW_UPDATE, 1);
    s.mark("resume server");
    s.resumeServer(SERVER, SERVER_PORT);
    s.runSeconds(120);
    closeClient(s);

# Expected: node 1 logs SYN_RETX after the RTO, then the handshake finishes. One ALLOC on node 4.
def synloss(s):
    setDrop(s, s.DROP_SYN, 1);
    transfer(s, 300, 150);

# Expected: node 4 logs SYNACK_RETX, node 1 still in SYN_SENT resends its SYN, and node 4 sees it as a
# duplicate instead of allocating a second record.
def synackloss(s):
    setDrop(s, s.DROP_SYNACK, 1);
    transfer(s, 300, 150);

# Expected: node 4 stays in SYN_RCVD until the first data segment, which carries the same ACK,
# so it logs "ACK_RX handshake" from the data and goes to ESTABLISHED. One ALLOC on node 4.
def hsackloss(s):
    setDrop(s, s.DROP_HANDSHAKE_ACK, 1);
    transfer(s, 300, 150);

# Expected: node 4 in LAST_ACK times out and logs FIN_RETX. Node 1 in TIME_WAIT logs FIN_RX duplicate,
# ACKs again and restarts its linger. Both sides end with close done SUCCESS and release.
def finalackloss(s):
    setDrop(s, s.DROP_FINAL_ACK, 1);
    transfer(s, 300, 150);

# Expected: node 4 logs "no listener on port: 21" for every SYN. Node 1 logs SYN_RETX up to 6 times,
# then FAILED, RELEASE and "client connect failed".
def nolistener(s):
    startServer(s);
    s.mark("client on 1, port 10 -> 4:21, nobody listens there");
    s.testClient(CLIENT, SERVER, CLIENT_PORT, SERVER_PORT + 1, 300);
    s.runSeconds(60);

# Expected: the 2-3 link is cut partway through, so there's no path. Node 1 retries 6 times, then logs
# FAILED in ESTABLISHED, RELEASE with the acked count, and close done FAIL. accepted is still reported.
def unreachable(s):
    startServer(s);
    startClient(s, 1030);
    s.runSeconds(15);

    s.mark("cut link 2-3");
    s.removeLink(2, 3);
    s.runSeconds(60);
    s.clientClose(CLIENT, SERVER, CLIENT_PORT, SERVER_PORT);
    s.runSeconds(10);

# Same as baseline with meyer-heavy noise. Expected: random retransmissions, still total: 1030, mismatches: 0.
def noisy(s):
    transfer(s, 1030, 400);

# Clients on 1:10 and 2:11 both connect to 4:20. Expected: node 4 ALLOCs two records from the same
# listener, both finish with mismatches: 0, and the listener is still listening afterwards.
def twoconn(s):
    startServer(s);
    startClient(s, 600);
    s.mark("client on 2, port 11 -> 4:20, 600 bytes");
    s.runSeconds(1);
    s.testClient(2, SERVER, 11, SERVER_PORT, 600);
    s.runSeconds(150);

    s.mark("close both clients");
    s.clientClose(CLIENT, SERVER, CLIENT_PORT, SERVER_PORT);
    s.runSeconds(1);
    s.clientClose(2, SERVER, 11, SERVER_PORT);
    s.runSeconds(80);

# Starts the client at the time that makes its ISN 65049, so with 485 bytes the FIN's sequence number is 65535.
# Expected: node 1's ACK_RX ack: 0 moves it to FIN_WAIT_2, and both sides close SUCCESS.
def finwrap(s):
    startServer(s);
    s.runSeconds(185);
    startClient(s, 485);
    s.runSeconds(1);
    closeClient(s);
    s.runSeconds(60);

# Nothing to send and the handshake ACK is dropped, so the client's FIN is what moves node 4 to ESTABLISHED,
# and node 4 is already in CLOSE_WAIT before the app accepts. Expected: "server saw remote close!" right
# after "server accepted!", then server result total: 0 and both sides close SUCCESS.
def finearly(s):
    setDrop(s, s.DROP_HANDSHAKE_ACK, 1);
    startServer(s);
    startClient(s, 0);
    s.runSeconds(1);
    closeClient(s);

# The paused server never reads the end of the stream, so it never closes. Expected: node 1 sits in
# FIN_WAIT_2, then logs "FIN_WAIT_2 timeout" ~21 s later, releases, and logs close done FAIL.
def finwait2(s):
    startServer(s);
    s.pauseServer(SERVER, SERVER_PORT);
    s.runSeconds(1);
    startClient(s, 100);
    s.runSeconds(30);
    closeClient(s);

SCENARIOS = {
    "basic": basic,
    "baseline": baseline,
    "dataloss": dataloss,
    "ackloss": ackloss,
    "acklast": acklast,
    "flow": flow,
    "synloss": synloss,
    "synackloss": synackloss,
    "hsackloss": hsackloss,
    "finalackloss": finalackloss,
    "nolistener": nolistener,
    "unreachable": unreachable,
    "noisy": noisy,
    "twoconn": twoconn,
    "finwrap": finwrap,
    "finearly": finearly,
    "finwait2": finwait2
}

if __name__ == '__main__':
    main()
