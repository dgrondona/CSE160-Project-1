#ifndef __SOCKET_H__
#define __SOCKET_H__

enum{
    MAX_NUM_OF_SOCKETS = 10,
    ROOT_SOCKET_ADDR = 255,
    ROOT_SOCKET_PORT = 255,
    SOCKET_BUFFER_SIZE = 128,
    NULL_SOCKET = 255
};

enum socket_state{
    CLOSED,
    LISTEN,
    ESTABLISHED,
    SYN_SENT,
    SYN_RCVD,
    FIN_WAIT_1,
    FIN_WAIT_2,
    CLOSING,
    TIME_WAIT,
    CLOSE_WAIT,
    LAST_ACK
};


typedef nx_uint8_t nx_socket_port_t;
typedef uint8_t socket_port_t;

// socket_addr_t is a simplified version of an IP connection.
typedef nx_struct socket_addr_t{
    nx_socket_port_t port;
    nx_uint16_t addr;
}socket_addr_t;


// File descripter id. Each id is associated with a socket_store_t
typedef uint8_t socket_t;

// One connection record. The positions below are sequence numbers, not buffer indexes.
// A byte with sequence number s lives at buff[s % SOCKET_BUFFER_SIZE]. 128 divides 65536, so that stays right across wraparound.
typedef struct socket_store_t{
    enum socket_state state;
    bool inUse;
    bool appOwned; // The app has this fd, from socket() or accept().
    socket_t parent; // Listener that spawned this record, NULL_SOCKET if none.
    socket_port_t src;
    socket_addr_t dest;

    // This is the sender portion.
    uint8_t sendBuff[SOCKET_BUFFER_SIZE];
    uint16_t lastWritten; // One past the last byte the app wrote.
    uint16_t lastAck; // Oldest unacked byte.
    uint16_t lastSent; // Next byte to send.
    uint8_t peerWindow; // Last window the peer advertised.
    bool finPending; // close() was called, send FIN once the data is all acked.
    bool finSent;
    uint16_t finSeq;

    // This is the receiver portion
    uint8_t rcvdBuff[SOCKET_BUFFER_SIZE];
    uint16_t lastRead; // Next byte the app will read.
    uint16_t nextExpected;
    bool finRcvd;
    bool notifyClosed; // FIN came before accept(), signal remoteClosed once the app has it.

    // One timer per record: retransmit, zero window probe, or TIME_WAIT linger depending on state.
    bool timerOn;
    uint32_t deadline;
    uint8_t retries;

    uint16_t bytesAcked;
}socket_store_t;

#endif
