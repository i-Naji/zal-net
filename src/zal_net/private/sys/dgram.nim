## Platform ancillary-data and multicast boundary.
import zal_net/private/sys/types

{.compile: "nn_dgram.c".}

proc nnEnableInfo*(fd: cint): cint {.importc: "nn_dgram_enable_info".}
proc nnRecvInfo*(fd: cint; buf: pointer; len: csize_t; src: pointer; srclen: ptr cuint;
                info: ptr NnDinfo): clong {.importc: "nn_dgram_recv_info".}
proc nnSendFrom*(fd: cint; buf: pointer; len: csize_t; dst: pointer; dstlen: cuint;
                src: pointer; srcFamily: cint; ifindex: cuint): clong {.importc: "nn_dgram_send_from".}
proc nnMembership*(fd, join: cint; group: pointer; glen: cuint; ifindex: cuint): cint {.importc: "nn_mcast_membership".}
proc nnMcastIf*(fd, v6: cint; ifindex: cuint): cint {.importc: "nn_mcast_interface".}
proc nnMcastTtl*(fd, v6, ttl: cint): cint {.importc: "nn_mcast_ttl".}
proc nnMcastLoop*(fd, v6, on: cint): cint {.importc: "nn_mcast_loop".}

