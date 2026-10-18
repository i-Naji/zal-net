## splice(2) through a pipe, for the stream copy and the relay (Linux).

when defined(linux):
  {.compile: "nn_stream.c".}
  proc nnPipe*(fds: ptr cint; size: cint): cint {.importc: "nn_pipe".}
  proc nnSplice*(fdIn, fdOut: cint; len: clong): clong {.importc: "nn_splice".}
  proc nnSpliceOutput*(fdIn, fdOut: cint; len: clong): clong {.importc: "nn_splice_output".}
  when defined(nnStreamFaultTest):
    {.passC: "-DNN_STREAM_FAULT_TEST".}
