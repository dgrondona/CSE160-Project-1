import sys
from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Only the basic scenario exists for now.
    scenario = "basic";
    if len(sys.argv) > 1:
        scenario = sys.argv[1];

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);
    s.addChannel(s.TGEN_CHANNEL);

    # Let the routes converge first, same as lineTest.
    s.runSeconds(60);

    s.mark("route tables");
    s.routeDMP(1); s.runSeconds(1);
    s.routeDMP(4); s.runSeconds(1);

    # Expected: ping reply comes back to 1, so routing works before we blame transport.
    s.mark("ping 1 -> 4");
    s.ping(1, 4, "Transport test");
    s.runSeconds(5);

    if scenario == "basic":
        basic(s);
    else:
        print 'Unknown scenario:', scenario;

# One client on node 1 sends 300 bytes to a server on node 4, then closes.
def basic(s):
    # Expected: node 4 logs "server listening! port: 20".
    s.mark("server on 4, port 20");
    s.testServer(4, 20);
    s.runSeconds(2);

    # Expected: node 1 connects, node 4 accepts. No data is written before the connect finishes.
    s.mark("client on 1, port 10 -> 4:20, 300 bytes");
    s.testClient(1, 4, 10, 20, 300);

    # Stop and wait sends 12 bytes per segment and a round trip over 3 hops takes 1-2 s, so give it a long time.
    # Expected: client accepted reaches 300 and the server reads 300 bytes with no mismatches.
    s.runSeconds(150);

    # Expected: client closes once everything is accepted. Server result is total: 300, mismatches: 0.
    # Both sides log close done after the TIME_WAIT linger (~30 s).
    s.mark("close client");
    s.clientClose(1, 4, 10, 20);
    s.runSeconds(80);

if __name__ == '__main__':
    main()
